package PVE::API2::Cluster::DCPowerSave;
use strict;
use warnings;
use PVE::RESTHandler;
use PVE::Cluster;
use PVE::DC::PowerSave::Config;
use base qw(PVE::RESTHandler);

my $properties = {
    enabled => { type => 'boolean' },
    active_governor => { type => 'string', pattern => '[a-zA-Z0-9_.-]+' },
    idle_governor => { type => 'string', pattern => '[a-zA-Z0-9_.-]+' },
    migration_governor => { type => 'string', pattern => '[a-zA-Z0-9_.-]+' },
    failsafe_governor => { type => 'string', pattern => '[a-zA-Z0-9_.-]+' },
    reconciliation_interval => { type => 'integer', minimum => 5, maximum => 3600 },
    event_poll_interval => { type => 'integer', minimum => 1, maximum => 60 },
    idle_candidate_delay => { type => 'integer', minimum => 0, maximum => 3600 },
    boot_protection_period => { type => 'integer', minimum => 0, maximum => 86400 },
};

__PACKAGE__->register_method({
    name => 'index', path => '', method => 'GET',
    description => 'Datacenter CPU power management configuration',
    permissions => { check => ['perm', '/', ['Sys.Audit']] },
    parameters => { additionalProperties => 0, properties => {} },
    returns => { type => 'object', additionalProperties => 1 },
    code => sub {
        my $cfg = eval { PVE::DC::PowerSave::Config->load() };
        my $error = $@;
        $cfg ||= PVE::DC::PowerSave::Config->defaults;
        $cfg->{configuration_error} = "$error" if $error;
        $cfg->{digest} = PVE::DC::PowerSave::Config->digest();
        return $cfg;
    },
});

__PACKAGE__->register_method({
    name => 'update', path => '', method => 'PUT', protected => 1,
    description => 'Update datacenter CPU power management configuration',
    permissions => { check => ['perm', '/', ['Sys.Modify']] },
    parameters => { additionalProperties => 0, properties => {
        %$properties,
        digest => { type => 'string', pattern => '[a-f0-9]{64}' },
    } },
    returns => { type => 'object', additionalProperties => 1 },
    code => sub {
        my ($param) = @_;
        PVE::Cluster::check_cfs_quorum();
        my $digest = delete $param->{digest};
        my $cfg;
        PVE::Cluster::cfs_lock_file('datacenter.cfg', undef, sub {
            $cfg = eval { PVE::DC::PowerSave::Config->load() }
                || PVE::DC::PowerSave::Config->defaults;
            $cfg->{$_} = $param->{$_} for keys %$properties;
            PVE::DC::PowerSave::Config->save($cfg, undef, $digest);
        });
        die $@ if $@;
        $cfg->{digest} = PVE::DC::PowerSave::Config->digest();
        return $cfg;
    },
});
1;
