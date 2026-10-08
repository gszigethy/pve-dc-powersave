use strict;
use warnings;
use Test::More;
use lib 'lib';
use PVE::DC::PowerSave::ClusterCapabilities;

my $fixtures = {
    '/cluster/status' => [
        { type => 'cluster', quorate => 1 },
        { type => 'node', name => 'pve01', online => 1 },
        { type => 'node', name => 'pve02', online => 1 },
    ],
    '/nodes/pve01/power-management' => {
        prerequisites => { cpupower_installed => 1, cpu_policies => [
            { governors => { performance => 1, powersave => 1, schedutil => 1 } },
            { governors => { performance => 1, powersave => 1 } },
        ] },
    },
    '/nodes/pve02/power-management' => {
        prerequisites => { cpupower_installed => 1, cpu_policies => [
            { governors => { performance => 1, powersave => 1, ondemand => 1 } },
        ] },
    },
};
my $collector = PVE::DC::PowerSave::ClusterCapabilities->new(runner => sub {
    my ($path) = @_;
    return (0, undef, 'not found') if !exists $fixtures->{$path};
    return (1, $fixtures->{$path}, undef);
});

my $cap = $collector->collect;
ok($cap->{complete}, 'all node capabilities are complete');
is_deeply($cap->{nodes}[0]{governors}, [qw(performance powersave)], 'node intersection excludes a governor missing on one policy');
is_deeply($cap->{common_governors}, [qw(performance powersave)], 'cluster intersection includes only governors available everywhere');
is($cap->{reason}, 'common_governors_available', 'common capability state is explicit');
my $cfg = {
    enabled => 1,
    active_governor => 'performance',
    idle_governor => 'powersave',
    migration_governor => 'performance',
    failsafe_governor => 'performance',
};
ok($collector->validate_config($cfg, $cap), 'configuration using common governors is accepted');
eval { $collector->validate_config({ %$cfg, idle_governor => 'schedutil' }, $cap) };
like($@, qr/idle_governor.*not available on every node/, 'non-common configured governor is rejected');

$fixtures->{'/nodes/pve02/power-management'}{prerequisites}{cpu_policies}[0]{governors} = { schedutil => 1 };
$cap = $collector->collect;
ok($cap->{complete}, 'empty intersection can still have complete reports');
is_deeply($cap->{common_governors}, [], 'disjoint node sets produce no common governor');
is($cap->{reason}, 'no_common_governor', 'empty intersection has a distinct reason');
eval { $collector->validate_config($cfg, $cap) };
like($@, qr/No common CPU governor/, 'enabled configuration is rejected for an empty intersection');
ok($collector->validate_config({ %$cfg, enabled => 0 }, $cap), 'disabled policy remains saveable for recovery');

$fixtures->{'/cluster/status'}[2]{online} = 0;
$cap = $collector->collect;
ok(!$cap->{complete}, 'offline node makes cluster capabilities incomplete');
is($cap->{reason}, 'incomplete_node_capabilities', 'incomplete reports fail closed');
is($cap->{errors}[0]{node}, 'pve02', 'problem node is identified');
is_deeply($cap->{common_governors}, [], 'partial node data is not presented as a cluster-wide intersection');
eval { $collector->validate_config($cfg, $cap) };
like($@, qr/every node reports fresh/, 'enabled configuration is rejected for incomplete capabilities');

$fixtures->{'/cluster/status'}[2]{online} = 1;
$fixtures->{'/nodes/pve02/power-management'} = { node => 'pve02', state => 'ERROR', reason => 'service_not_reporting' };
$cap = $collector->collect;
is($cap->{nodes}[1]{reason}, 'service_not_reporting', 'stopped service is not reported as missing cpupower');
like($cap->{errors}[0]{message}, qr/service is not running/, 'stopped service message names the service');

$fixtures->{'/cluster/status'} = [ { type => 'node', name => 'pve01', online => 1 } ];
$cap = $collector->collect;
ok($cap->{complete}, 'standalone node does not require a cluster quorum row');
is_deeply($cap->{common_governors}, [qw(performance powersave)], 'standalone node uses its local policy intersection');

done_testing;
