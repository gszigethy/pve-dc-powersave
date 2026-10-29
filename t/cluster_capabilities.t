use strict;
use warnings;
use Test::More;
use Time::HiRes qw(time);
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


# ---- a node whose plugin registration was removed --------------------------

$fixtures->{'/cluster/status'} = [
    { type => 'cluster', quorate => 1 },
    { type => 'node', name => 'pve01', online => 1 },
    { type => 'node', name => 'pve02', online => 1 },
];
$fixtures->{'/nodes/pve02/power-management'} = { prerequisites => { cpupower_installed => 1,
    cpu_policies => [ { governors => { performance => 1, powersave => 1 } } ] } };
for my $stderr ("501 Not Implemented", "No 'get' handler defined for 'nodes/pve02/power-management'",
    "Method 'GET /nodes/pve02/power-management' not implemented") {
    my $missing = PVE::DC::PowerSave::ClusterCapabilities->new(runner => sub {
        my ($path) = @_;
        return (0, undef, $stderr) if $path eq '/nodes/pve02/power-management';
        return (0, undef, 'not found') if !exists $fixtures->{$path};
        return (1, $fixtures->{$path}, undef);
    });
    my $report = $missing->collect;
    is($report->{nodes}[1]{reason}, 'plugin_not_installed', "a 501 answer is plugin_not_installed ($stderr)");
    like($report->{errors}[0]{message}, qr/rerun the installer on this node/i, 'the message tells the admin to rerun the installer');
    ok(!$report->{complete}, 'a node without the plugin makes the report incomplete');
}
my $broken = PVE::DC::PowerSave::ClusterCapabilities->new(runner => sub {
    my ($path) = @_;
    return (0, undef, 'ssh: connect to host pve02 port 22: Connection timed out') if $path eq '/nodes/pve02/power-management';
    return (1, $fixtures->{$path}, undef);
});
is($broken->collect->{nodes}[1]{reason}, 'status_unavailable', 'any other failure stays status_unavailable');

# ---- when a capability check is needed -------------------------------------

my $on = { enabled => 1, active_governor => 'performance', idle_governor => 'powersave',
    migration_governor => 'performance', failsafe_governor => 'performance', reconciliation_interval => 30 };
my $off = { %$on, enabled => 0 };
ok(PVE::DC::PowerSave::ClusterCapabilities::validation_required($off, $on), 'turning the policy on needs a check');
ok(PVE::DC::PowerSave::ClusterCapabilities::validation_required(undef, $on), 'enabling over an unusable file needs a check');
ok(!PVE::DC::PowerSave::ClusterCapabilities::validation_required($on, { %$on, enabled => 0 }), 'disabling needs no check');
ok(!PVE::DC::PowerSave::ClusterCapabilities::validation_required($off, { %$off, idle_governor => 'schedutil' }),
    'a governor change while disabled needs no check');
ok(!PVE::DC::PowerSave::ClusterCapabilities::validation_required($on, { %$on, reconciliation_interval => 60 }),
    'an interval change on an enabled policy needs no check');
ok(!PVE::DC::PowerSave::ClusterCapabilities::validation_required($on, { %$on }), 'an unchanged policy needs no check');
for my $key (qw(active_governor idle_governor migration_governor failsafe_governor)) {
    ok(PVE::DC::PowerSave::ClusterCapabilities::validation_required($on, { %$on, $key => 'schedutil' }),
        "changing $key on an enabled policy needs a check");
}

# ---- cached, single-flight collection --------------------------------------

use File::Temp qw(tempdir);
use Fcntl qw(:flock);
use JSON::PP qw(encode_json decode_json);

my $cache_root = tempdir(CLEANUP => 1);
my $cache_dir = "$cache_root/run";
mkdir($cache_dir, 0755) or die $!;
my $calls = 0;
my $counting = sub {
    my %args = @_;
    return PVE::DC::PowerSave::ClusterCapabilities->new(
        cache_dir => $cache_dir,
        runner => sub {
            my ($path) = @_;
            $calls++ if $path eq '/cluster/status';
            return (0, undef, 'not found') if !exists $fixtures->{$path};
            return (1, $fixtures->{$path}, undef);
        },
        %args,
    );
};
$fixtures->{'/cluster/status'} = [ { type => 'cluster', quorate => 1 }, { type => 'node', name => 'pve01', online => 1 } ];

my $first = $counting->()->collect_cached;
is($calls, 1, 'the first request runs discovery');
ok(!$first->{cached}, 'the first report is not from the cache');
is($first->{age}, 0, 'a new report has age 0');
ok(-f "$cache_dir/capabilities.json", 'the report is written to the cache directory');
is(sprintf('%04o', (stat("$cache_dir/capabilities.json"))[2] & 07777), '0600', 'the cache file is root-only');
is_deeply([sort grep { !/^\.\.?$/ } do { opendir(my $d, $cache_dir); readdir($d) }], [qw(capabilities.json capabilities.lock)],
    'no temporary files are left behind');

my $second = $counting->()->collect_cached;
is($calls, 1, 'a request inside the cache window does not run discovery again');
ok($second->{cached}, 'the second report is marked as cached');
cmp_ok($second->{age}, '<=', 2, 'the cached report states its age');
is($second->{generated_at}, $first->{generated_at}, 'the cached report keeps its generation time');
is_deeply($second->{common_governors}, $first->{common_governors}, 'the cached report has the same content');

# age the cache
sub age_cache {
    my ($seconds) = @_;
    my $file = "$cache_dir/capabilities.json";
    open(my $in, '<', $file) or die $!;
    local $/ = undef;
    my $report = decode_json(scalar <$in>);
    close($in);
    $report->{generated_at} = int(time) - $seconds;
    open(my $out, '>', $file) or die $!;
    print {$out} encode_json($report);
    close($out);
    return;
}
age_cache(30);
my $stale = $counting->()->collect_cached;
is($calls, 2, 'a report older than the cache window is recomputed');
ok(!$stale->{cached}, 'and is marked as new');

age_cache(8);
$counting->()->collect_cached(max_age => 5);
is($calls, 3, 'the caller can demand a fresher report');
$counting->()->collect_cached(max_age => 5);
is($calls, 3, 'and gets the cache once it is fresh enough');

open(my $junk, '>', "$cache_dir/capabilities.json") or die $!;
print {$junk} "{not json";
close($junk);
$counting->()->collect_cached;
is($calls, 4, 'an unreadable cache file is ignored and replaced');
ok(decode_json(do { open(my $in, '<', "$cache_dir/capabilities.json"); local $/ = undef; scalar <$in> })->{generated_at}, 'the cache file is valid again');

# a future timestamp must not be trusted
age_cache(-3600);
$counting->()->collect_cached;
is($calls, 5, 'a report from the future is not trusted');

# single flight: a computing request holds the lock
age_cache(30);
sysopen(my $busy, "$cache_dir/capabilities.lock", Fcntl::O_WRONLY() | Fcntl::O_CREAT(), 0600) or die $!;
flock($busy, LOCK_EX | LOCK_NB) or die 'cannot lock';
my $calls_before = $calls;
my $recent = $counting->()->collect_cached(max_age => 10, stale_ok => 60, wait_timeout => 0.3);
is($calls, $calls_before, 'a request does not start discovery while another one computes');
ok($recent->{cached}, 'it returns the previous report');
cmp_ok($recent->{age}, '>=', 30, 'and states how old it is');

my $started = time;
eval { $counting->()->collect_cached(max_age => 10, stale_ok => 10, wait_timeout => 0.3) };
like($@, qr/still running/, 'a caller that needs a fresh report waits, then gives up with a message');
cmp_ok(time - $started, '>=', 0.25, 'it waited for the computing request');
cmp_ok(time - $started, '<', 5, 'the wait is bounded');
is($calls, $calls_before, 'waiting never starts a second discovery');
flock($busy, LOCK_UN);
close($busy);

# a waiter picks up the result of the computing request
age_cache(30);
pipe(my $ready_r, my $ready_w) or die $!;
my $pid = fork();
die "fork: $!" if !defined $pid;
if (!$pid) {
    close($ready_r);
    sysopen(my $lock, "$cache_dir/capabilities.lock", Fcntl::O_WRONLY() | Fcntl::O_CREAT(), 0600) or exit 1;
    flock($lock, LOCK_EX | LOCK_NB) or exit 2;
    print {$ready_w} "locked\n";
    close($ready_w);
    select(undef, undef, undef, 0.5);
    open(my $out, '>', "$cache_dir/capabilities.json") or exit 3;
    print {$out} encode_json({ complete => 1, common_governors => ['performance'], nodes => [], errors => [],
        reason => 'common_governors_available', generated_at => int(time) });
    close($out);
    exit 0;
}
close($ready_w);
my $line = <$ready_r>;
is($line, "locked\n", 'the helper process holds the discovery lock');
$calls_before = $calls;
my $waited = $counting->()->collect_cached(max_age => 10, stale_ok => 10, wait_timeout => 10);
waitpid($pid, 0);
is($calls, $calls_before, 'the waiter did not run discovery itself');
ok($waited->{cached}, 'the waiter returns the computing request result');
is_deeply($waited->{common_governors}, ['performance'], 'with the content the other request produced');

# no runtime directory: compute without caching and do not create it
my $absent = "$cache_root/absent";
$calls_before = $calls;
my $uncached = PVE::DC::PowerSave::ClusterCapabilities->new(cache_dir => $absent, runner => sub {
    my ($path) = @_;
    $calls++ if $path eq '/cluster/status';
    return (0, undef, 'not found') if !exists $fixtures->{$path};
    return (1, $fixtures->{$path}, undef);
});
my $direct = $uncached->collect_cached;
$uncached->collect_cached;
is($calls, $calls_before + 2, 'without a runtime directory every request computes');
ok(!$direct->{cached}, 'and nothing is reported as cached');
ok(!-e $absent, 'the runtime directory is not created');

# a directory others can write is not trusted
my $open_dir = "$cache_root/open";
mkdir($open_dir, 0777) or die $!;
chmod(0777, $open_dir);
$calls_before = $calls;
my $unsafe = $counting->(cache_dir => $open_dir);
$unsafe->collect_cached;
$unsafe->collect_cached;
is($calls, $calls_before + 2, 'a world-writable directory is not used for caching');
ok(!-e "$open_dir/capabilities.json", 'nothing is written there');

# a symlinked cache file is not followed
my $link_dir = "$cache_root/linked";
mkdir($link_dir, 0755) or die $!;
symlink("$cache_root/elsewhere", "$link_dir/capabilities.json") or die $!;
my $linked = $counting->(cache_dir => $link_dir);
eval { $linked->collect_cached };
ok(!-e "$cache_root/elsewhere", 'a symlink planted as the cache file is not written through');

done_testing;
