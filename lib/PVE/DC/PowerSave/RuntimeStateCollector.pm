package PVE::DC::PowerSave::RuntimeStateCollector;
use strict;
use warnings;
use JSON::PP qw(decode_json);
use Sys::Hostname qw(hostname);
use PVE::DC::PowerSave::Command;

# Long-lived interactive sessions that do not represent host work.
my %CONSOLE_TASK = map { $_ => 1 } qw(vncproxy vncshell spiceproxy spiceshell termproxy);

# Task types that move a guest between nodes. Everything else, including
# storage removals (dirremove, zfsremove) and HA start/stop, is local work.
my %MIGRATION_TASK = map { $_ => 1 } qw(qmigrate vzmigrate migrateall hamigrate harelocate);

# Services that make a node useful to other nodes or clients even with no
# running guest. Userspace daemons are matched on the basename of argv[0];
# kernel threads (nfsd) have no command line and are matched on comm. Add a
# daemon name here to extend the list.
my @STORAGE_SERVICES = qw(
    ceph-osd ceph-mon ceph-mds nfsd glusterfsd tgtd proxmox-backup-proxy
);
my %STORAGE_SERVICE = map { $_ => 1 } @STORAGE_SERVICES;

# A member's active task list this long may have been cut off by --limit.
my $MEMBER_TASK_LIMIT = 500;

sub new {
    my ($class, %args) = @_;
    my $node = $args{node} || hostname();
    $node =~ s/\..*$//;
    return bless {
        node => $node, pvesh => $args{pvesh} || '/usr/bin/pvesh',
        proc_root => $args{proc_root} // '/proc',
        clock => $args{clock} || sub { return time },
        member_backoff => $args{member_backoff} // 60,
        backoff => {},    # member => { until => epoch, reason => text }
    }, $class;
}

# The one place that decides whether a task type relocates a guest between
# nodes. Also used by EventObserver.
sub is_migration_task {
    my ($type) = @_;
    $type //= '';
    return $MIGRATION_TASK{$type} || $type =~ /migrat/i ? 1 : 0;
}

sub is_console_task {
    my ($type) = @_;
    return $CONSOLE_TASK{$type // ''} ? 1 : 0;
}

sub collect {
    my ($self, $boot_protected) = @_;
    my $node = $self->{node};
    my %state = (known => 0, tasks_known => 0, node_available => 0,
                 running_vm_count => 0, running_ct_count => 0,
                 running_guests => 0, boot_protected => $boot_protected ? 1 : 0,
                 storage_services => [], task_state_detail => []);

    my ($ok, $cluster, $error) = $self->_json('get', '/cluster/status');
    return { %state, error => $error || 'cluster status unavailable' } if !$ok || ref($cluster) ne 'ARRAY';
    my ($cluster_row) = grep { ($_->{type} // '') eq 'cluster' } @$cluster;
    if ($cluster_row && !$cluster_row->{quorate}) {
        return { %state, error => 'cluster is not quorate' };
    }
    my ($node_row) = grep { ($_->{type} // '') eq 'node' && ($_->{name} // '') eq $node } @$cluster;
    return { %state, error => 'local node unavailable' } if !$node_row || !$node_row->{online};
    $state{node_available} = 1;
    my %cluster_nodes = map { ($_->{name} // '') => 1 } grep { ($_->{type} // '') eq 'node' } @$cluster;

    for my $guest_type (qw(qemu lxc)) {
        my ($guests_ok, $guests, $guest_error) = $self->_json('get', "/nodes/$node/$guest_type");
        return { %state, error => $guest_error || "$guest_type runtime unavailable" }
            if !$guests_ok || ref($guests) ne 'ARRAY';
        for my $guest (@$guests) {
            my $status = $guest->{status};
            return { %state, error => "unknown $guest_type guest status" }
                if !defined($status) || $status !~ /^(?:running|stopped)$/;
            if ($status eq 'running') {
                $state{$guest_type eq 'qemu' ? 'running_vm_count' : 'running_ct_count'}++;
                $state{running_guests}++;
            }
        }
    }
    $state{known} = 1;

    my ($storage_ok, $services, $storage_error) = $self->_scan_storage_services;
    $state{storage_services} = $services;
    @state{qw(storage_unknown storage_error)} = (1, $storage_error) if !$storage_ok;

    my ($tasks_ok, $tasks, $task_error) = $self->_json('get', '/cluster/tasks');
    return { %state, error => $task_error || 'task view unavailable' }
        if !$tasks_ok || ref($tasks) ne 'ARRAY';
    $self->_protect_from_tasks(\%state, $tasks, \%cluster_nodes);

    # The cluster broadcast is cheap but can lose an old, still running task.
    # Asking every member for its active tasks (one SSH-proxied pvesh each)
    # only matters when this node could otherwise become idle; in any other
    # case the node stays off the idle governor whatever those tasks say.
    if (!$state{running_guests} && !@{$state{storage_services}}
        && !$state{storage_unknown} && !$state{protected}) {
        my $members = [grep { ($_->{type} // '') eq 'node' && $_->{online} } @$cluster];
        return { %state, error => 'cluster node identity unknown' }
            if grep { !$_->{name} || $_->{name} !~ /^[a-zA-Z0-9_.-]+$/ } @$members;
        my ($active_tasks, $failures) = $self->_member_tasks([map { $_->{name} } @$members]);
        $self->_protect_from_tasks(\%state, $active_tasks, \%cluster_nodes);
        # An unreachable member is missing proof, not a collection error:
        # the node stays active and the status says which member and why.
        $state{task_state_detail} = $failures;
        $state{tasks_known} = @$failures ? 0 : 1;
    } else {
        $state{tasks_known} = 1;
    }
    return \%state;
}

# Return all active tasks of the given members plus a list of failures. A
# failing member is not queried again until its backoff expires.
sub _member_tasks {
    my ($self, $names) = @_;
    my (@tasks, @failures);
    for my $name (@$names) {
        my $backoff = $self->{backoff}{$name};
        if ($backoff && $self->{clock}->() < $backoff->{until}) {
            push @failures, { node => $name, error => $backoff->{reason}, retry_after => int($backoff->{until}) };
            next;
        }
        my ($ok, $member_tasks, $error) = $self->_json(
            'get', "/nodes/$name/tasks", '--source', 'active', '--limit', $MEMBER_TASK_LIMIT);
        my $failure = !$ok ? ($error || 'active task view unavailable')
            : ref($member_tasks) ne 'ARRAY' ? 'active task view is not a list'
            : @$member_tasks >= $MEMBER_TASK_LIMIT ? "active task list truncated at $MEMBER_TASK_LIMIT entries"
            : undef;
        if (defined $failure) {
            $failure =~ s/\s+/ /g;
            $failure = substr($failure, 0, 200);
            my $until = $self->{clock}->() + $self->{member_backoff};
            $self->{backoff}{$name} = { until => $until, reason => $failure };
            push @failures, { node => $name, error => $failure, retry_after => int($until) };
            next;
        }
        delete $self->{backoff}{$name};
        push @tasks, @$member_tasks;
    }
    return (\@tasks, \@failures);
}

# Record the first running task that protects this node. Returns true when
# the node is protected.
sub _protect_from_tasks {
    my ($self, $state, $tasks, $cluster_nodes) = @_;
    return 1 if $state->{protected};
    for my $task (@$tasks) {
        next if $task->{endtime} || ($task->{status} // '') =~ /^(?:OK|ERROR|WARNINGS)$/;
        my $reason = $self->_protection_reason($task, $cluster_nodes) or next;
        @{$state}{qw(protected protection_reason protection_task)} = (1, $reason, $task->{upid});
        return 1;
    }
    return 0;
}

# Why a running task protects this node, or nothing.
sub _protection_reason {
    my ($self, $task, $cluster_nodes) = @_;
    my $node = $self->{node};
    my $type = $task->{type} // '';
    my $source = $task->{node} // '';
    if (is_migration_task($type)) {
        # Some task summaries use 'target' for a guest or other object;
        # only a known cluster node is safe to treat as a destination.
        my $target = $task->{target} // $task->{targetnode} // '';
        $target = '' if !$cluster_nodes->{$target};
        # Task summaries often omit the destination. Protect every node
        # while the destination is unknown, including before arrival.
        return if $target ne '' && $source ne $node && $target ne $node;
        return $target eq '' ? 'migration_target_unknown' : ($source eq $node ? 'migration_source' : 'migration_target');
    }
    return if $source ne $node;
    return 'lifecycle_operation'
        if $type =~ /^(?:qmstart|qmstop|qmshutdown|qmreboot|vzstart|vzstop|vzshutdown|vzreboot)$/;
    # Backups, restores, clones, disk moves and similar tasks are host
    # work even when every guest is stopped. Unknown task types count as
    # work too; only interactive console sessions are ignored.
    return 'node_task' if !is_console_task($type);
    return;
}

# Find storage services in the process table. Returns (ok, \@names, error).
# Any process that cannot be inspected makes the scan incomplete, which the
# caller treats as "no proof" rather than "no services".
sub _scan_storage_services {
    my ($self) = @_;
    my $root = $self->{proc_root};
    return (0, [], "cannot read $root: $!") if !opendir(my $dh, $root);
    my (%found, $processes);
    for my $pid (grep { /^[0-9]+$/ } readdir($dh)) {
        my $cmdline = _slurp("$root/$pid/cmdline");
        if (!defined $cmdline) {
            next if !-d "$root/$pid";    # exited since readdir
            closedir($dh);
            return (0, [], "cannot read process $pid in $root");
        }
        $processes++;
        my $name;
        if (length $cmdline) {
            ($name) = split(/\0/, $cmdline, 2);
            $name =~ s/\s.*$//s if defined $name;    # rewritten process titles
            $name =~ s{^.*/}{} if defined $name;
        } else {
            # Kernel thread or zombie: no argv. Their comm is not truncated
            # for the names we look for.
            $name = _slurp("$root/$pid/comm");
            $name =~ s/\s+$// if defined $name;
        }
        $found{$name} = 1 if defined $name && $STORAGE_SERVICE{$name};
    }
    closedir($dh);
    return (0, [], "no processes found in $root") if !$processes;
    return (1, [sort keys %found], undef);
}

sub _slurp {
    my ($path) = @_;
    open(my $fh, '<:raw', $path) or return;
    my $data = do { local $/ = undef; <$fh> };
    close($fh);
    return $data // '';
}

sub _json {
    my ($self, @args) = @_;
    my ($ok, $stdout, $stderr) = PVE::DC::PowerSave::Command::run(
        [$self->{pvesh}, @args, '--output-format', 'json'], 10, 'pvesh');
    return (0, undef, $stderr || 'pvesh failed') if !$ok;
    my $data = eval { decode_json($stdout) };
    return (0, undef, "invalid pvesh JSON: $@") if $@;
    return (1, $data, undef);
}
1;
