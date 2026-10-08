use strict;
use warnings;
use Test::More;
use Time::HiRes qw(time);
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
done_testing;
