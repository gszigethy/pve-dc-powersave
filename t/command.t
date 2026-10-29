use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use Time::HiRes qw(time sleep);
use lib 'lib';
use PVE::DC::PowerSave::Command;

my ($ok, $stdout, $stderr) = PVE::DC::PowerSave::Command::run(['/bin/sh', '-c', 'echo out; echo err >&2'], 5);
ok($ok, 'successful command reports success');
is($stdout, "out\n", 'stdout is captured');
is($stderr, "err\n", 'stderr is captured separately');

($ok, $stdout, $stderr) = PVE::DC::PowerSave::Command::run(['/bin/sh', '-c', 'echo partial; echo broken >&2; exit 3'], 5);
ok(!$ok, 'non-zero exit is a failure');
is($stdout, "partial\n", 'stdout of a failed command is kept');
is($stderr, "broken\n", 'stderr explains the failure');

my $started = time;
($ok, $stdout, $stderr) = PVE::DC::PowerSave::Command::run(
    ['/bin/sh', '-c', 'head -c 200000 /dev/zero | tr "\\0" e >&2; echo "[]"'], 5);
ok($ok, 'command writing more than a pipe buffer to stderr completes');
is($stdout, "[]\n", 'stdout after a large stderr is complete');
is(length($stderr), 200000, 'large stderr is captured in full');
ok(time - $started < 4, 'large stderr does not deadlock until the timeout');

($ok, $stdout) = PVE::DC::PowerSave::Command::run(['/bin/sh', '-c', 'head -c 300000 /dev/zero | tr "\\0" o'], 5);
is(length($stdout), 300000, 'large stdout is captured in full');

$started = time;
($ok, $stdout, $stderr) = PVE::DC::PowerSave::Command::run(['/bin/sh', '-c', 'sleep 30'], 1, 'pvesh');
ok(!$ok, 'hung command fails');
is($stderr, "pvesh timed out\n", 'timeout is reported with the label');
ok(time - $started < 5, 'hung command is stopped at the timeout');

($ok, $stdout, $stderr) = PVE::DC::PowerSave::Command::run(['/nonexistent/pvesh'], 5);
ok(!$ok, 'missing executable fails');
like($stderr, qr/\S/, 'missing executable is explained');

# A command that ignores SIGTERM must still be stopped: the group gets SIGTERM,
# then SIGKILL, and run() returns within timeout + ~4 s. The shell and the
# sleep it starts both inherit the ignored SIGTERM.
my $scratch = tempdir(CLEANUP => 1);
my $alive = sub { my ($file) = @_; open(my $fh, '<', $file) or return 0; my $pid = <$fh>; chomp($pid); return kill(0, $pid) ? 1 : 0; };
$started = time;
($ok, $stdout, $stderr) = PVE::DC::PowerSave::Command::run(
    ['/bin/sh', '-c', qq{echo \$\$ > $scratch/trap.pid; trap "" TERM; while :; do sleep 1; done}], 1, 'stubborn');
my $elapsed = time - $started;
ok(!$ok, 'child ignoring SIGTERM fails');
is($stderr, "stubborn timed out\n", 'child ignoring SIGTERM is reported as a timeout');
cmp_ok($elapsed, '<', 6, "child ignoring SIGTERM is killed (returned after ${elapsed}s)");
ok(!$alive->("$scratch/trap.pid"), 'child ignoring SIGTERM is dead afterwards');

# A grandchild that keeps stdout and stderr open must not leave the pipes
# blocked or survive the command, even when it ignores SIGTERM too.
$started = time;
($ok, $stdout, $stderr) = PVE::DC::PowerSave::Command::run(
    ['/bin/sh', '-c', qq{(trap "" TERM; exec sleep 30) & echo \$! > $scratch/grandchild.pid; echo started; exit 0}], 1, 'spawner');
$elapsed = time - $started;
ok(!$ok, 'command whose grandchild holds the pipes times out');
cmp_ok($elapsed, '<', 6, "run returns although a grandchild holds the pipes (${elapsed}s)");
ok(-s "$scratch/grandchild.pid", 'grandchild was started');
ok(!$alive->("$scratch/grandchild.pid"), 'grandchild is killed with the command');

# The command runs in its own process group, apart from the caller.
($ok, $stdout) = PVE::DC::PowerSave::Command::run(['/bin/sh', '-c', 'ps -o pgid= -p $$'], 5);
$stdout =~ s/\s+//g;
ok($ok && $stdout ne getpgrp(0), 'command runs in its own process group');

# A start failure is reported and a later call is unaffected.
($ok, $stdout, $stderr) = PVE::DC::PowerSave::Command::run(['/nonexistent/pvesh'], 5);
like($stderr, qr{cannot execute /nonexistent/pvesh}, 'exec failure names the command');
($ok, $stdout) = PVE::DC::PowerSave::Command::run(['/bin/sh', '-c', 'echo again'], 5);
is($stdout, "again\n", 'runner still works after a failed start');

# A process that survives SIGKILL (uninterruptible sleep) must not block the
# caller; a later call reaps it once it has exited.
{
    no warnings qw(redefine once);
    local *PVE::DC::PowerSave::Command::_signal = sub { return 1; };
    local $PVE::DC::PowerSave::Command::TERM_GRACE = 0.2;
    local $PVE::DC::PowerSave::Command::KILL_GRACE = 0.2;
    $started = time;
    ($ok, undef, $stderr) = PVE::DC::PowerSave::Command::run(['/bin/sh', '-c', 'sleep 2'], 1, 'stuck');
    $elapsed = time - $started;
    is($stderr, "stuck timed out\n", 'unkillable child is reported as a timeout');
    cmp_ok($elapsed, '<', 2, 'unkillable child does not block the caller');
    is(scalar(@PVE::DC::PowerSave::Command::UNREAPED), 1, 'unkillable child is kept for later reaping');
}
sleep(1.5);
PVE::DC::PowerSave::Command::run(['/bin/true'], 5);
is(scalar(@PVE::DC::PowerSave::Command::UNREAPED), 0, 'a later call reaps the child once it has exited');
done_testing;
