use strict; use warnings; use Test::More;
use lib 'lib'; use PVE::DC::PowerSave::DesiredState;
my $cfg = { enabled => 1, active_governor => 'performance', idle_governor => 'powersave', migration_governor => 'performance' };
my $cap = { valid => 1, governors => { performance => 1, powersave => 1 }, policies => [ { governors => { performance => 1, powersave => 1 } } ] };
my $base = { known => 1, tasks_known => 1, node_available => 1, running_guests => 0, idle_confirmed => 1 };
is(PVE::DC::PowerSave::DesiredState->decide('n', $cfg, $base, $cap)->{state}, 'IDLE', 'empty node is idle after positive verification');
is(PVE::DC::PowerSave::DesiredState->decide('n', $cfg, {%$base, running_guests => 1}, $cap)->{state}, 'ACTIVE', 'running guest is active');
is(PVE::DC::PowerSave::DesiredState->decide('n', $cfg, {%$base, protected => 1, protection_reason => 'migration_in_progress'}, $cap)->{state}, 'PROTECTED', 'migration is protected');
is(PVE::DC::PowerSave::DesiredState->decide('n', $cfg, {%$base, known => 0}, $cap)->{reason}, 'runtime_state_unknown', 'unknown state fails safe');
is(PVE::DC::PowerSave::DesiredState->decide('n', $cfg, {%$base, idle_confirmed => 0}, $cap)->{state}, 'IDLE_CANDIDATE', 'idle requires delay');
is(PVE::DC::PowerSave::DesiredState->decide('n', $cfg, {%$base, tasks_known => 0}, $cap)->{state}, 'ACTIVE', 'unknown tasks fail active');
is(PVE::DC::PowerSave::DesiredState->decide('n', $cfg, {%$base, boot_protected => 1}, $cap)->{state}, 'ACTIVE', 'boot protection wins over empty node');
my $storage = PVE::DC::PowerSave::DesiredState->decide('n', $cfg, {%$base, storage_services => ['ceph-osd']}, $cap);
is($storage->{state}, 'ACTIVE', 'storage service keeps the node active');
is($storage->{reason}, 'storage_service', 'storage service has its own reason');
is(PVE::DC::PowerSave::DesiredState->decide('n', $cfg, {%$base, storage_services => ['nfsd'], running_guests => 1}, $cap)->{reason},
    'running_guest', 'running guest is reported before storage services');
is(PVE::DC::PowerSave::DesiredState->decide('n', $cfg, {%$base, storage_services => ['nfsd'], idle_confirmed => 0}, $cap)->{state},
    'ACTIVE', 'storage service wins over the idle candidate');
is(PVE::DC::PowerSave::DesiredState->decide('n', $cfg, {%$base, storage_services => ['nfsd'], protected => 1}, $cap)->{state},
    'PROTECTED', 'protection still takes precedence');
is(PVE::DC::PowerSave::DesiredState->decide('n', $cfg, {%$base, storage_unknown => 1}, $cap)->{state}, 'ACTIVE',
    'failed storage scan is no proof of idle');
is(PVE::DC::PowerSave::DesiredState->decide('n', $cfg, {%$base, storage_unknown => 1}, $cap)->{reason},
    'storage_state_unknown', 'failed storage scan has its own reason');
ok(PVE::DC::PowerSave::DesiredState->storage_blocks_idle({ storage_services => ['tgtd'] }), 'services block idle');
ok(PVE::DC::PowerSave::DesiredState->storage_blocks_idle({ storage_unknown => 1 }), 'unknown blocks idle');
ok(!PVE::DC::PowerSave::DesiredState->storage_blocks_idle({ storage_services => [] }), 'no services do not block');
my $mixed = { %$cap, policies => [
    { governors => { performance => 1, powersave => 1 } },
    { governors => { performance => 1 } },
] };
is(PVE::DC::PowerSave::DesiredState->decide('n', $cfg, $base, $mixed)->{reason}, 'idle_governor_unavailable', 'all CPU policies must support idle');
done_testing;
