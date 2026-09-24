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
my $mixed = { %$cap, policies => [
    { governors => { performance => 1, powersave => 1 } },
    { governors => { performance => 1 } },
] };
is(PVE::DC::PowerSave::DesiredState->decide('n', $cfg, $base, $mixed)->{reason}, 'idle_governor_unavailable', 'all CPU policies must support idle');
done_testing;
