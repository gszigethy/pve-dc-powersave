package PVE::DC::PowerSave::ClusterCapabilities;
use strict;
use warnings;
use JSON::PP qw(decode_json);
use PVE::DC::PowerSave::Command;
use Time::HiRes qw(time);

sub new {
    my ($class, %args) = @_;
    return bless {
        pvesh => $args{pvesh} || '/usr/bin/pvesh',
        runner => $args{runner},
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
        if (!$status_ok || ref($status) ne 'HASH') {
            $entry->{reason} = 'status_unavailable';
            push @{$result->{errors}}, { node => $node, reason => $entry->{reason}, message => $status_error || 'Invalid node status' };
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

sub validate_config {
    my ($self, $cfg, $capabilities) = @_;
    return 1 if !$cfg->{enabled};
    die "Cannot enable power management until every node reports fresh CPU governor capabilities\n"
        if !$capabilities->{complete};
    my %common = map { $_ => 1 } @{$capabilities->{common_governors} || []};
    die "No common CPU governor is available across all nodes; align the CPU frequency driver configuration first\n"
        if !keys %common;
    for my $key (qw(active_governor idle_governor migration_governor failsafe_governor)) {
        die "$key '$cfg->{$key}' is not available on every node\n" if !$common{$cfg->{$key}};
    }
    return 1;
}

1;
