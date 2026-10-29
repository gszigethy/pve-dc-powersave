package PVE::API2::Cluster::DCPowerSave;
use strict;
use warnings;
use PVE::RESTHandler;
use PVE::Cluster;
use PVE::DC::PowerSave::Config;
use PVE::DC::PowerSave::ClusterCapabilities;
use base qw(PVE::RESTHandler);

# Tests point this at a temporary file; undef means the shared pmxcfs file.
our $CONFIG_PATH;

# A capability report used to validate a policy may be at most this old.
my $VALIDATION_MAX_AGE = 10;

my $properties = {
    enabled => { type => 'boolean', optional => 1 },
    active_governor => { type => 'string', pattern => '[a-zA-Z0-9_.-]+', optional => 1 },
    idle_governor => { type => 'string', pattern => '[a-zA-Z0-9_.-]+', optional => 1 },
    migration_governor => { type => 'string', pattern => '[a-zA-Z0-9_.-]+', optional => 1 },
    failsafe_governor => { type => 'string', pattern => '[a-zA-Z0-9_.-]+', optional => 1 },
    reconciliation_interval => { type => 'integer', minimum => 5, maximum => 3600, optional => 1 },
    event_poll_interval => { type => 'integer', minimum => 1, maximum => 60, optional => 1 },
    idle_candidate_delay => { type => 'integer', minimum => 0, maximum => 3600, optional => 1 },
    boot_protection_period => { type => 'integer', minimum => 0, maximum => 86400, optional => 1 },
};

# Capability discovery is cached for a few seconds and computed by one request
# at a time, so Sys.Audit users cannot tie up pvedaemon's workers.
sub cluster_capabilities {
    my (%options) = @_;
    return PVE::DC::PowerSave::ClusterCapabilities->new->collect_cached(%options);
}

# The stored policy, or undef plus the reason when it cannot be loaded. A
# missing file is the defaults. Any exception from loading or parsing is
# handled generically, whatever the parser considers invalid.
sub _current_config {
    my $cfg = eval { PVE::DC::PowerSave::Config->load($CONFIG_PATH) };
    my $error = $@;
    $error ||= "configuration could not be loaded\n" if !$cfg;
    return $cfg ? ($cfg, undef) : (undef, $error);
}

sub _same_config {
    my ($left, $right) = @_;
    for my $key (PVE::DC::PowerSave::Config->keys) {
        return 0 if ($left->{$key} // '') ne ($right->{$key} // '');
    }
    return 1;
}

# What the stored policy becomes after this request, or undef plus the reason
# for refusing. A usable file takes a partial update. For an unusable one only
# two requests are safe: a complete replacement, or a disable (enabled 0 with
# the defaults for everything the request does not say).
sub _proposed_config {
    my ($current, $load_error, $param) = @_;
    my %given = map { $_ => $param->{$_} } grep { defined $param->{$_} } PVE::DC::PowerSave::Config->keys;
    if ($current) {
        return { %$current, %given };
    }
    my @missing = grep { !exists $given{$_} } PVE::DC::PowerSave::Config->keys;
    return { %given } if !@missing;
    return { %{PVE::DC::PowerSave::Config->defaults}, %given }
        if exists $given{enabled} && !$given{enabled};
    chomp(my $why = $load_error);
    return (undef, "The stored configuration cannot be loaded ($why). "
        . "Send every property to replace it, or only enabled 0 to disable power management.\n");
}

sub _validate_capabilities {
    my ($current, $proposed) = @_;
    return 0 if !PVE::DC::PowerSave::ClusterCapabilities::validation_required($current, $proposed);
    my $collector = PVE::DC::PowerSave::ClusterCapabilities->new;
    $collector->validate_config($proposed, cluster_capabilities(max_age => $VALIDATION_MAX_AGE, stale_ok => $VALIDATION_MAX_AGE));
    return 1;
}

# Capability discovery runs pvesh, which only works as root. Unprotected
# methods execute inside pveproxy as www-data; protected => 1 makes pveproxy
# forward the call to pvedaemon, which runs as root.
__PACKAGE__->register_method({
    name => 'capabilities', path => 'capabilities', method => 'GET', protected => 1,
    description => 'Governors supported by every CPU policy on every cluster node (cached for a few seconds)',
    permissions => { check => ['perm', '/', ['Sys.Audit']] },
    parameters => { additionalProperties => 0, properties => {} },
    returns => { type => 'object', additionalProperties => 1 },
    code => sub { return cluster_capabilities(); },
});

__PACKAGE__->register_method({
    name => 'index', path => '', method => 'GET',
    description => 'Datacenter CPU power management configuration',
    permissions => { check => ['perm', '/', ['Sys.Audit']] },
    parameters => { additionalProperties => 0, properties => {} },
    returns => { type => 'object', additionalProperties => 1 },
    code => sub {
        my ($cfg, $error) = _current_config();
        $cfg ||= PVE::DC::PowerSave::Config->defaults;
        $cfg->{configuration_error} = "$error" if $error;
        $cfg->{digest} = PVE::DC::PowerSave::Config->digest($CONFIG_PATH);
        return $cfg;
    },
});

__PACKAGE__->register_method({
    name => 'update', path => '', method => 'PUT', protected => 1,
    description => 'Update datacenter CPU power management configuration. '
        . 'Properties that are not given keep their stored value, so '
        . '`pvesh set /cluster/power-management --enabled 0` stops automation.',
    permissions => { check => ['perm', '/', ['Sys.Modify']] },
    parameters => { additionalProperties => 0, properties => {
        %$properties,
        digest => { type => 'string', pattern => '[a-f0-9]{64}', optional => 1 },
    } },
    returns => { type => 'object', additionalProperties => 1 },
    code => sub {
        my ($param) = @_;
        PVE::Cluster::check_cfs_quorum();
        my $digest = delete $param->{digest};

        # Fail fast on a stale digest, before any slow capability work. A
        # retry of a request that already went through (the browser timed
        # out, the save completed) finds the stored policy equal to what it
        # would write and succeeds with the current digest.
        my ($current, $load_error) = _current_config();
        my ($proposed, $refusal) = _proposed_config($current, $load_error, $param);
        die $refusal if !$proposed;
        if (defined($digest) && $digest ne PVE::DC::PowerSave::Config->digest($CONFIG_PATH)) {
            return _unchanged_result($current) if $current && _same_config($current, $proposed);
            die "configuration changed; reload before saving\n";
        }
        my $validated = _validate_capabilities($current, $proposed) ? _policy_key($proposed) : '';

        my $result;
        PVE::Cluster::cfs_lock_file('datacenter.cfg', undef, sub {
            # Re-read inside the lock: another admin may have saved while
            # capabilities were being checked.
            my ($locked_current, $locked_error) = _current_config();
            my ($locked_proposed, $locked_refusal) = _proposed_config($locked_current, $locked_error, $param);
            die $locked_refusal if !$locked_proposed;
            my $expected = PVE::DC::PowerSave::Config->digest($CONFIG_PATH);
            if (defined($digest) && $digest ne $expected) {
                if ($locked_current && _same_config($locked_current, $locked_proposed)) {
                    $result = _unchanged_result($locked_current);
                    return;
                }
                die "configuration changed; reload before saving\n";
            }
            # Capabilities were checked for the policy computed before the
            # lock. If the merge now yields a different one (an update
            # without a digest merges into whatever is stored), refuse
            # rather than save something unchecked.
            die "configuration changed; reload before saving\n"
                if PVE::DC::PowerSave::ClusterCapabilities::validation_required($locked_current, $locked_proposed)
                    && $validated ne _policy_key($locked_proposed);
            # Return the digest save() computed under the lock: reading the
            # file again after unlocking could return another admin's save.
            my $new_digest = PVE::DC::PowerSave::Config->save($locked_proposed, $CONFIG_PATH, $expected);
            $result = { %$locked_proposed, digest => $new_digest };
            return;
        });
        die $@ if $@;
        return $result;
    },
});

sub _unchanged_result {
    my ($cfg) = @_;
    return { %$cfg, digest => PVE::DC::PowerSave::Config->digest($CONFIG_PATH) };
}

# The part of a policy that capability validation depends on.
sub _policy_key {
    my ($cfg) = @_;
    return join("\0", map { $cfg->{$_} // '' } qw(enabled active_governor idle_governor migration_governor failsafe_governor));
}
1;
