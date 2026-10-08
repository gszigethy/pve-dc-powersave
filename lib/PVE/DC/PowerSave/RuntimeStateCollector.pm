package PVE::DC::PowerSave::RuntimeStateCollector;
use strict;
use warnings;
use JSON::PP qw(decode_json);
use Sys::Hostname qw(hostname);
use PVE::DC::PowerSave::Command;

sub new {
    my ($class, %args) = @_;
    my $node = $args{node} || hostname();
    $node =~ s/\..*$//;
    return bless { node => $node, pvesh => $args{pvesh} || '/usr/bin/pvesh' }, $class;
}

sub collect {
    my ($self, $boot_protected) = @_;
    my $node = $self->{node};
    my %state = (known => 0, tasks_known => 0, node_available => 0,
                 running_vm_count => 0, running_ct_count => 0,
                 running_guests => 0, boot_protected => $boot_protected ? 1 : 0);

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

    my ($tasks_ok, $tasks, $task_error) = $self->_json('get', '/cluster/tasks');
    return { %state, error => $task_error || 'task view unavailable' }
        if !$tasks_ok || ref($tasks) ne 'ARRAY';
    my @active_tasks;
    for my $member (grep { ($_->{type} // '') eq 'node' && $_->{online} } @$cluster) {
        my $member_name = $member->{name};
        return { %state, error => 'cluster node identity unknown' }
            if !$member_name || $member_name !~ /^[a-zA-Z0-9_.-]+$/;
        my ($active_ok, $member_tasks, $active_error) = $self->_json(
            'get', "/nodes/$member_name/tasks", '--source', 'active', '--limit', '500');
        return { %state, error => $active_error || "$member_name active task view unavailable" }
            if !$active_ok || ref($member_tasks) ne 'ARRAY' || @$member_tasks >= 500;
        push @active_tasks, @$member_tasks;
    }
    my %seen;
    $tasks = [grep { my $id = $_->{upid} // ''; !$id || !$seen{$id}++ } (@$tasks, @active_tasks)];
    $state{tasks_known} = 1;
    for my $task (@$tasks) {
        next if $task->{endtime} || ($task->{status} // '') =~ /^(?:OK|ERROR|WARNINGS)$/;
        my $type = $task->{type} // '';
        my $source = $task->{node} // '';
        my $target = $task->{target} // $task->{targetnode} // '';
        if ($type =~ /(?:migrate|move)/i || $type =~ /^ha/i) {
            # Some task summaries use 'target' for a guest or other object;
            # only a known cluster node is safe to treat as a destination.
            $target = '' if !$cluster_nodes{$target};
            # Task summaries often omit the destination. Protect every node
            # while the destination is unknown, including before arrival.
            next if $target ne '' && $source ne $node && $target ne $node;
            $state{protected} = 1;
            $state{protection_reason} = $target eq '' ? 'migration_target_unknown' :
                ($source eq $node ? 'migration_source' : 'migration_target');
            $state{protection_task} = $task->{upid};
            last;
        }
        if ($type =~ /^(?:qmstart|qmstop|qmshutdown|qmreboot|vzstart|vzstop|vzshutdown|vzreboot)$/ && $source eq $node) {
            $state{protected} = 1;
            $state{protection_reason} = 'lifecycle_operation';
            $state{protection_task} = $task->{upid};
            last;
        }
    }
    return \%state;
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
