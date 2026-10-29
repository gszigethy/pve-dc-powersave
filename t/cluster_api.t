use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use File::Temp qw(tempdir);
use Test::More;
use lib 'lib', 't/lib';
use PVETestStubs;

require PVE::API2::Cluster::DCPowerSave;
require PVE::DC::PowerSave::Config;

my $class = 'PVE::API2::Cluster::DCPowerSave';
my $index = PVETestStubs::method($class, 'index');
my $update = PVETestStubs::method($class, 'update');
my $capabilities = PVETestStubs::method($class, 'capabilities');

ok($index, 'cluster configuration GET route is registered');
ok($update, 'cluster configuration PUT route is registered');
ok($capabilities, 'cluster capability route is registered');
is($capabilities->{path}, 'capabilities', 'capability route has the expected path');
is($capabilities->{method}, 'GET', 'capability route is read-only');
is_deeply(
    $capabilities->{permissions}{check},
    ['perm', '/', ['Sys.Audit']],
    'capability discovery requires datacenter audit permission',
);
ok($capabilities->{protected}, 'capability discovery runs in pvedaemon because pvesh requires root');
ok($update->{protected}, 'policy update runs in pvedaemon because it also runs capability discovery');

my @keys = PVE::DC::PowerSave::Config->keys;
my @required = grep { !$update->{parameters}{properties}{$_}{optional} } sort keys %{$update->{parameters}{properties}};
is_deeply(\@required, [], 'every update property, including the digest, is optional');
is_deeply([sort grep { $_ ne 'digest' } keys %{$update->{parameters}{properties}}], [sort @keys],
    'the update schema covers every configuration key');

# ---- fixtures --------------------------------------------------------------

my $dir = tempdir(CLEANUP => 1);
my $path = "$dir/dc-powersave.cfg";
{
    no warnings 'once';
    $PVE::API2::Cluster::DCPowerSave::CONFIG_PATH = $path;
}

my @capability_calls;
my $capability_result;
my $capability_in_lock;
sub good_caps {
    return {
        complete => 1, reason => 'common_governors_available', generated_at => time,
        common_governors => [qw(performance powersave schedutil)],
    };
}
{
    no warnings qw(redefine once);
    *PVE::API2::Cluster::DCPowerSave::cluster_capabilities = sub {
        push @capability_calls, [@_];
        $capability_in_lock = $PVETestStubs::locked;
        die $capability_result->{die} if $capability_result && $capability_result->{die};
        return $capability_result || good_caps();
    };
}

sub write_cfg {
    my (%override) = @_;
    my $cfg = PVE::DC::PowerSave::Config->defaults;
    $cfg->{$_} = $override{$_} for keys %override;
    my $raw = join('', map { "$_: $cfg->{$_}\n" } @keys);
    open(my $fh, '>', $path) or die $!;
    print {$fh} $raw;
    close($fh);
    return $cfg;
}

sub slurp {
    open(my $fh, '<', $path) or return;
    local $/ = undef;
    my $raw = <$fh>;
    close($fh);
    return $raw;
}

sub stored { return PVE::DC::PowerSave::Config->load($path); }

sub run_update {
    my (%param) = @_;
    @capability_calls = ();
    undef $capability_in_lock;
    PVETestStubs::reset_state();
    my $result = eval { $update->{code}->({ %param }) };
    return ($result, $@);
}

sub reset_files { unlink($path); return; }

# ---- GET -------------------------------------------------------------------

reset_files();
write_cfg(enabled => 1);
my $got = $index->{code}->({});
is($got->{enabled}, 1, 'GET returns the stored configuration');
is($got->{digest}, PVE::DC::PowerSave::Config->digest($path), 'GET returns the digest of the stored file');
{
    open(my $fh, '>', $path) or die $!;
    print {$fh} "this is not a configuration\n";
    close($fh);
}
$got = $index->{code}->({});
like($got->{configuration_error}, qr/invalid configuration line/, 'GET reports an unparsable file instead of failing');
is($got->{enabled}, 0, 'GET falls back to the defaults for an unparsable file');

# ---- emergency stop and partial updates -----------------------------------

write_cfg(enabled => 1, idle_governor => 'schedutil', reconciliation_interval => 45);
$capability_result = { die => "pvesh hangs on every node\n" };
my ($res, $err) = run_update(enabled => 0);
is($err, '', 'enabled=0 alone is accepted (pvesh set /cluster/power-management --enabled 0)');
is(stored()->{enabled}, 0, 'the emergency stop disables the policy');
is(stored()->{idle_governor}, 'schedutil', 'a partial update keeps the other stored properties');
is(stored()->{reconciliation_interval}, 45, 'a partial update keeps the stored interval');
is(scalar(@capability_calls), 0, 'disabling never runs capability discovery');
is($res->{enabled}, 0, 'the response is the merged configuration');
is($res->{digest}, PVE::DC::PowerSave::Config->digest($path), 'the response carries the new digest');

write_cfg(enabled => 1);
($res, $err) = run_update(enabled => 0, digest => 'a' x 64);
like($err, qr/configuration changed; reload before saving/, 'a given digest must still match when disabling');
is(stored()->{enabled}, 1, 'a rejected disable leaves the file alone');

($res, $err) = run_update(enabled => 0, digest => PVE::DC::PowerSave::Config->digest($path));
is($err, '', 'a matching digest is accepted');
is(stored()->{enabled}, 0, 'matching digest disables the policy');

write_cfg(enabled => 0);
($res, $err) = run_update(boot_protection_period => 300);
is($err, '', 'a partial update without a digest is accepted');
is(stored()->{boot_protection_period}, 300, 'the given property is merged');
is(stored()->{active_governor}, 'performance', 'the other properties stay unchanged');

# ---- when to validate capabilities -----------------------------------------

$capability_result = { complete => 0, reason => 'incomplete_node_capabilities', errors => [], common_governors => [] };
write_cfg(enabled => 1);
($res, $err) = run_update(reconciliation_interval => 60);
is($err, '', 'an interval change on an enabled policy does not need every node');
is(stored()->{reconciliation_interval}, 60, 'the interval change is stored');
is(scalar(@capability_calls), 0, 'an interval-only change skips capability discovery');

($res, $err) = run_update(idle_governor => 'schedutil');
like($err, qr/every node reports fresh/, 'changing a governor on an enabled policy validates capabilities');
is(stored()->{idle_governor}, 'powersave', 'a refused governor change is not stored');

write_cfg(enabled => 0);
($res, $err) = run_update(enabled => 1);
like($err, qr/every node reports fresh/, 'enabling validates capabilities');
is(stored()->{enabled}, 0, 'a refused enable is not stored');
is_deeply($capability_calls[0], [max_age => 10, stale_ok => 10], 'validation accepts no report older than 10 seconds, even while another request computes');
ok(defined($capability_in_lock) && !$capability_in_lock, 'capability discovery runs before the cluster lock is taken');

write_cfg(enabled => 0, idle_governor => 'schedutil');
($res, $err) = run_update(idle_governor => 'powersave');
is($err, '', 'a governor change while the policy stays disabled is not validated');
is(scalar(@capability_calls), 0, 'no capability discovery for a disabled policy');

$capability_result = undef;
write_cfg(enabled => 0);
($res, $err) = run_update(enabled => 1);
is($err, '', 'enabling with complete capabilities succeeds');
is(stored()->{enabled}, 1, 'the policy is enabled');

($res, $err) = run_update(idle_governor => 'nosuchgov');
like($err, qr/idle_governor 'nosuchgov' is not available on every node/, 'a governor outside the common set is refused');

# ---- digest first, then the lock ------------------------------------------

write_cfg(enabled => 0);
my $old_digest = PVE::DC::PowerSave::Config->digest($path);
write_cfg(enabled => 0, boot_protection_period => 99);
($res, $err) = run_update(enabled => 1, digest => $old_digest);
like($err, qr/configuration changed; reload before saving/, 'a stale digest is refused');
is(scalar(@capability_calls), 0, 'a stale digest fails before any capability work');
is(scalar(@PVETestStubs::lock_names), 0, 'a stale digest fails before the cluster lock is taken');

# ---- idempotent retry ------------------------------------------------------

write_cfg(enabled => 0);
$old_digest = PVE::DC::PowerSave::Config->digest($path);
($res, $err) = run_update(enabled => 1, idle_governor => 'schedutil', digest => $old_digest);
is($err, '', 'the first request succeeds');
my $saved_digest = $res->{digest};
($res, $err) = run_update(enabled => 1, idle_governor => 'schedutil', digest => $old_digest);
is($err, '', 'a retry whose result is already stored succeeds although the digest moved on');
is($res->{digest}, $saved_digest, 'the retry returns the current digest');
is(scalar(@capability_calls), 0, 'the retry needs no capability work');
($res, $err) = run_update(enabled => 1, idle_governor => 'powersave', digest => $old_digest);
like($err, qr/configuration changed; reload before saving/, 'a stale digest with different content is still refused');

# ---- digest returned from inside the lock ---------------------------------

write_cfg(enabled => 0);
{
    no warnings 'redefine';
    my $real_save = \&PVE::DC::PowerSave::Config::save;
    my $in_lock;
    local *PVE::DC::PowerSave::Config::save = sub {
        $in_lock = $PVETestStubs::locked;
        my $digest = $real_save->(@_);
        # Another admin saves right after the lock is released.
        write_cfg(enabled => 0, boot_protection_period => 777);
        return $digest;
    };
    ($res, $err) = run_update(reconciliation_interval => 62);
    is($err, '', 'the save succeeds');
    ok($in_lock, 'the configuration is saved while the cluster lock is held');
    isnt($res->{digest}, PVE::DC::PowerSave::Config->digest($path), 'the response does not carry the digest of a later save');
    my $snapshot_cfg = PVE::DC::PowerSave::Config->defaults;
    $snapshot_cfg->{reconciliation_interval} = 62;
    my $raw = join('', map { "$_: $snapshot_cfg->{$_}\n" } @keys);
    is($res->{digest}, sha256_hex($raw), 'the response carries the digest of the content this request saved');
}

# ---- a concurrent save while capabilities are checked -----------------------

write_cfg(enabled => 0);
{
    no warnings qw(redefine once);
    my $real = \&PVE::API2::Cluster::DCPowerSave::cluster_capabilities;
    local *PVE::API2::Cluster::DCPowerSave::cluster_capabilities = sub {
        write_cfg(enabled => 0, idle_governor => 'schedutil');
        return good_caps();
    };
    ($res, $err) = run_update(enabled => 1);
    like($err, qr/configuration changed; reload before saving/, 'an update without digest is refused when the merge changed a governor after validation');
    is(stored()->{enabled}, 0, 'and nothing unchecked is stored');

    write_cfg(enabled => 0);
    my $digest = PVE::DC::PowerSave::Config->digest($path);
    ($res, $err) = run_update(enabled => 1, digest => $digest);
    like($err, qr/configuration changed; reload before saving/, 'the digest is checked again inside the lock');
    is(stored()->{idle_governor}, 'schedutil', 'the other admin save survives');
}

# ---- unusable current file -------------------------------------------------

sub write_garbage {
    open(my $fh, '>', $path) or die $!;
    print {$fh} "garbage without colon\n";
    close($fh);
    return;
}

write_garbage();
my %all = (
    enabled => 0, active_governor => 'performance', idle_governor => 'powersave',
    migration_governor => 'performance', failsafe_governor => 'performance',
    reconciliation_interval => 30, event_poll_interval => 2, idle_candidate_delay => 5,
    boot_protection_period => 120,
);
($res, $err) = run_update(%all, reconciliation_interval => 77);
is($err, '', 'a full update replaces an unparsable file');
is(stored()->{reconciliation_interval}, 77, 'the replacement is stored');

write_garbage();
($res, $err) = run_update(enabled => 0);
is($err, '', 'enabled=0 repairs an unparsable file');
is_deeply(stored(), { %all, enabled => 0 }, 'the repaired file has enabled: 0 and the defaults');

write_garbage();
($res, $err) = run_update(enabled => 0, boot_protection_period => 5);
is(stored()->{boot_protection_period}, 5, 'repairing keeps the given properties');

write_garbage();
($res, $err) = run_update(reconciliation_interval => 60);
like($err, qr/cannot be loaded.*every property.*enabled/s, 'a partial non-disabling update of an unparsable file is refused with an explanation');
like(slurp(), qr/garbage without colon/, 'the unparsable file is left untouched');

write_garbage();
($res, $err) = run_update(enabled => 1);
like($err, qr/cannot be loaded/, 'enabling an unparsable file is refused');

write_garbage();
($res, $err) = run_update(%all, enabled => 1);
is($err, '', 'a full enabling update replaces an unparsable file');
is(scalar(@capability_calls), 1, 'and is validated against the capabilities');

write_garbage();
$capability_result = { complete => 0, errors => [], common_governors => [] };
($res, $err) = run_update(%all, enabled => 1);
like($err, qr/every node reports fresh/, 'a full enabling update of an unparsable file is still validated');
like(slurp(), qr/garbage without colon/, 'and a refused replacement leaves the file untouched');
$capability_result = undef;

# ---- missing file and quorum -----------------------------------------------

unlink($path);
($res, $err) = run_update(boot_protection_period => 9);
is($err, '', 'an update works when the file does not exist yet');
ok(-e $path, 'the file is created');

$PVETestStubs::quorum_error = 'no quorum';
@capability_calls = ();
$res = eval { $update->{code}->({ enabled => 0 }) };
like($@, qr/no quorum/, 'an update without quorum is refused');
PVETestStubs::reset_state();

# ---- capabilities GET ------------------------------------------------------

@capability_calls = ();
my $report = $capabilities->{code}->({});
is($report->{complete}, 1, 'the capabilities route returns the report');
is(scalar(@capability_calls), 1, 'the capabilities route asks for one report');

done_testing;
