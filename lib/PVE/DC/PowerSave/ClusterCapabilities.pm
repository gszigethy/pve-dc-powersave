package PVE::DC::PowerSave::ClusterCapabilities;
use strict;
use warnings;
use Fcntl qw(:flock O_RDONLY O_WRONLY O_CREAT O_NOFOLLOW);
use JSON::PP qw(decode_json encode_json);
use PVE::DC::PowerSave::Command;
use Time::HiRes qw(time sleep);

# The controller's runtime directory. It exists only while the service has
# run; the cache lives there and is skipped when the directory is missing.
our $RUN_DIR = '/run/pve-dc-powersave';
# A report is reused for this many seconds.
our $CACHE_MAX_AGE = 10;
# While another request computes, a report up to this old may be returned.
our $CACHE_STALE_OK = 60;
# A request that needs a fresh report waits at most this long for the
# computing request.
our $CACHE_WAIT_TIMEOUT = 20;

my @GOVERNOR_KEYS = qw(active_governor idle_governor migration_governor failsafe_governor);

sub new {
    my ($class, %args) = @_;
    return bless {
        pvesh => $args{pvesh} || '/usr/bin/pvesh',
        runner => $args{runner},
        cache_dir => $args{cache_dir} // $RUN_DIR,
    }, $class;
}

sub _json {
    my ($self, $path) = @_;
    return $self->{runner}->($path) if $self->{runner};
    my ($ok, $stdout, $stderr) = PVE::DC::PowerSave::Command::run(
        [$self->{pvesh}, 'get', $path, '--output-format', 'json'], 15, 'pvesh');
    return (0, undef, $stderr || 'pvesh failed') if !$ok;
    my $decoded = eval { decode_json($stdout) };
    return (0, undef, $@ || 'invalid pvesh JSON') if $@;
    return (1, $decoded, undef);
}

# PVE answers an unknown API path with HTTP 501; pvesh reports it as
# "501 Not Implemented", "No 'get' handler defined for ..." or "... not
# implemented", depending on where the path was resolved.
sub _plugin_missing {
    my ($error) = @_;
    return 0 if !defined $error;
    return $error =~ /\b501\b|No '[a-z]+' handler defined|not implemented/i ? 1 : 0;
}

sub _local_common {
    my ($policies) = @_;
    return if ref($policies) ne 'ARRAY' || !@$policies;
    my $first = $policies->[0]->{governors};
    return if ref($first) ne 'HASH';
    my %common = map { $_ => 1 } grep { $first->{$_} } keys %$first;
    for (my $index = 1; $index < @$policies; $index++) {
        my $policy = $policies->[$index];
        my $supported = $policy->{governors};
        return if ref($supported) ne 'HASH';
        delete $common{$_} for grep { !$supported->{$_} } keys %common;
    }
    return [sort keys %common];
}

sub collect {
    my ($self) = @_;
    my $result = {
        complete => 0,
        common_governors => [],
        nodes => [],
        errors => [],
        generated_at => int(time),
    };
    my ($ok, $cluster, $error) = $self->_json('/cluster/status');
    if (!$ok || ref($cluster) ne 'ARRAY') {
        push @{$result->{errors}}, { reason => 'cluster_status_unavailable', message => $error || 'invalid cluster status' };
        $result->{reason} = 'incomplete_node_capabilities';
        return $result;
    }
    my ($cluster_row) = grep { ($_->{type} // '') eq 'cluster' } @$cluster;
    if ($cluster_row && !$cluster_row->{quorate}) {
        push @{$result->{errors}}, { reason => 'cluster_not_quorate', message => 'Cluster quorum is required' };
    }
    my @members = sort { ($a->{name} // '') cmp ($b->{name} // '') }
        grep { ($_->{type} // '') eq 'node' } @$cluster;
    if (!@members) {
        push @{$result->{errors}}, { reason => 'no_cluster_nodes', message => 'No cluster nodes were reported' };
    }
    my %cluster_common;
    my $have_common = 0;
    for my $member (@members) {
        my $node = $member->{name} // '';
        my $entry = { node => $node, online => $member->{online} ? 1 : 0, governors => [] };
        push @{$result->{nodes}}, $entry;
        if ($node !~ /^[A-Za-z0-9_.-]+$/) {
            $entry->{reason} = 'invalid_node_name';
            push @{$result->{errors}}, { node => $node, reason => $entry->{reason}, message => 'Cluster reported an invalid node name' };
            next;
        }
        if (!$member->{online}) {
            $entry->{reason} = 'node_offline';
            push @{$result->{errors}}, { node => $node, reason => $entry->{reason}, message => 'Node is offline' };
            next;
        }
        my ($status_ok, $status, $status_error) = $self->_json("/nodes/$node/power-management");
        if (!$status_ok && _plugin_missing($status_error)) {
            $entry->{reason} = 'plugin_not_installed';
            push @{$result->{errors}}, { node => $node, reason => $entry->{reason},
                message => 'The power management API is not registered on this node (a pve-manager upgrade removes it); rerun the installer on this node' };
            next;
        }
        if (!$status_ok || ref($status) ne 'HASH') {
            $entry->{reason} = 'status_unavailable';
            push @{$result->{errors}}, { node => $node, reason => $entry->{reason}, message => $status_error || 'Invalid node status' };
            next;
        }
        if (($status->{reason} // '') eq 'service_not_reporting') {
            $entry->{reason} = 'service_not_reporting';
            push @{$result->{errors}}, { node => $node, reason => $entry->{reason}, message => 'pve-dc-powersave.service is not running on this node' };
            next;
        }
        if (($status->{reason} // '') eq 'service_status_stale') {
            $entry->{reason} = 'service_status_stale';
            push @{$result->{errors}}, { node => $node, reason => $entry->{reason}, message => $status->{last_error} || 'Node status is stale' };
            next;
        }
        my $prerequisites = $status->{prerequisites};
        if (ref($prerequisites) ne 'HASH' || !$prerequisites->{cpupower_installed}) {
            $entry->{reason} = 'cpupower_unavailable';
            push @{$result->{errors}}, { node => $node, reason => $entry->{reason}, message => 'cpupower capability report is unavailable' };
            next;
        }
        my $local = _local_common($prerequisites->{cpu_policies});
        if (!defined($local)) {
            $entry->{reason} = 'cpu_policies_unavailable';
            push @{$result->{errors}}, { node => $node, reason => $entry->{reason}, message => 'CPU policy capabilities are unavailable' };
            next;
        }
        $entry->{governors} = $local;
        $entry->{valid} = 1;
        my %local = map { $_ => 1 } @$local;
        if (!$have_common) {
            %cluster_common = %local;
            $have_common = 1;
        } else {
            delete $cluster_common{$_} for grep { !$local{$_} } keys %cluster_common;
        }
    }
    $result->{complete} = @{$result->{errors}} ? 0 : 1;
    if (!$result->{complete}) {
        $result->{reason} = 'incomplete_node_capabilities';
    } else {
        $result->{common_governors} = [sort keys %cluster_common] if $have_common;
    }
    if ($result->{complete} && !@{$result->{common_governors}}) {
        $result->{reason} = 'no_common_governor';
    } elsif ($result->{complete}) {
        $result->{reason} = 'common_governors_available';
    }
    return $result;
}

# Capabilities only have to be proven when the update turns management on or
# changes a governor of a policy that is on. Interval changes and disabling
# never need every node, so a node that is down or mid-upgrade cannot block
# them. $current is undef when the stored policy cannot be loaded.
sub validation_required {
    my ($current, $proposed) = @_;
    return 0 if !$proposed->{enabled};
    return 1 if !$current || !$current->{enabled};
    for my $key (@GOVERNOR_KEYS) {
        return 1 if ($current->{$key} // '') ne ($proposed->{$key} // '');
    }
    return 0;
}

sub validate_config {
    my ($self, $cfg, $capabilities) = @_;
    return 1 if !$cfg->{enabled};
    die "Cannot enable power management until every node reports fresh CPU governor capabilities\n"
        if !$capabilities->{complete};
    my %common = map { $_ => 1 } @{$capabilities->{common_governors} || []};
    die "No common CPU governor is available across all nodes; align the CPU frequency driver configuration first\n"
        if !keys %common;
    for my $key (@GOVERNOR_KEYS) {
        die "$key '$cfg->{$key}' is not available on every node\n" if !$common{$cfg->{$key}};
    }
    return 1;
}

# ---- cached, single-flight collection ---------------------------------------
#
# The API runs in pvedaemon, which has three workers by default, and
# discovery makes one pvesh call per node. Reports are therefore cached in
# the runtime directory and computed by one request at a time (flock);
# concurrent requests reuse the cache or wait for the computing request.

# True when the cache directory is one we may trust: a real directory owned
# by us that others cannot write. A missing directory (the service never ran)
# disables caching; it is never created here because the controller refuses a
# runtime directory it did not create.
sub _cache_usable {
    my ($self) = @_;
    my @stat = lstat($self->{cache_dir}) or return 0;
    return 0 if !-d _ || $stat[4] != $> || ($stat[2] & oct('022'));
    return 1;
}

sub _cache_read {
    my ($self) = @_;
    my $path = "$self->{cache_dir}/capabilities.json";
    sysopen(my $fh, $path, O_RDONLY | O_NOFOLLOW) or return;
    my @stat = stat($fh);
    my $report;
    if ($stat[4] == $> && !($stat[2] & oct('022'))) {
        local $/ = undef;
        my $raw = <$fh>;
        $report = eval { decode_json($raw) };
    }
    close($fh);
    return if ref($report) ne 'HASH' || !$report->{generated_at} || $report->{generated_at} !~ /^\d+$/;
    my $age = int(time) - $report->{generated_at};
    return if $age < 0;    # clock moved back: do not trust it
    return ($report, $age);
}

sub _cache_write {
    my ($self, $report) = @_;
    my $path = "$self->{cache_dir}/capabilities.json";
    my $tmp = "$path.$$";
    my $written = eval {
        sysopen(my $fh, $tmp, O_WRONLY | O_CREAT | O_NOFOLLOW, oct('0600')) or die "cannot write $tmp: $!\n";
        print {$fh} encode_json($report) or die "cannot write $tmp: $!\n";
        close($fh) or die "cannot close $tmp: $!\n";
        rename($tmp, $path) or die "cannot replace $path: $!\n";
        1;
    };
    if (!$written) {
        unlink($tmp);
        return 0;
    }
    return 1;
}

sub _annotate {
    my ($report, $cached, $age) = @_;
    return { %$report, cached => $cached ? 1 : 0, age => $age };
}

# Return a capability report. Options:
#   max_age       freshest report the caller accepts (default 10 s)
#   stale_ok      while another request computes, accept a report this old
#                 (default 60 s); validation passes max_age here
#   wait_timeout  how long to wait for the computing request (default 20 s)
# The result carries `cached` and `age` (seconds since generated_at).
sub collect_cached {
    my ($self, %opt) = @_;
    my $max_age = $opt{max_age} // $CACHE_MAX_AGE;
    my $stale_ok = $opt{stale_ok} // $CACHE_STALE_OK;
    $stale_ok = $max_age if $stale_ok < $max_age;
    my $wait_timeout = $opt{wait_timeout} // $CACHE_WAIT_TIMEOUT;
    return _annotate($self->collect, 0, 0) if !$self->_cache_usable;

    my ($report, $age) = $self->_cache_read;
    return _annotate($report, 1, $age) if $report && $age <= $max_age;

    my $lock_path = "$self->{cache_dir}/capabilities.lock";
    sysopen(my $lock, $lock_path, O_WRONLY | O_CREAT | O_NOFOLLOW, oct('0600'))
        or return _annotate($self->collect, 0, 0);
    my $deadline = time + $wait_timeout;
    while (1) {
        if (flock($lock, LOCK_EX | LOCK_NB)) {
            # Another request may have finished while we were waiting.
            ($report, $age) = $self->_cache_read;
            return _annotate($report, 1, $age) if $report && $age <= $max_age;
            my $fresh = $self->collect;
            $self->_cache_write($fresh);
            flock($lock, LOCK_UN);
            close($lock);
            return _annotate($fresh, 0, 0);
        }
        # Somebody else is computing: a recent report is good enough for
        # callers that accept it, others wait for the result.
        return _annotate($report, 1, $age) if $report && $age <= $stale_ok;
        die "capability discovery is still running on another request; retry in a few seconds\n"
            if time >= $deadline;
        sleep(0.1);
        ($report, $age) = $self->_cache_read;
        return _annotate($report, 1, $age) if $report && $age <= $max_age;
    }
    return;    # not reached: the loop returns or dies
}

1;
