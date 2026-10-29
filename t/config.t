use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);
use lib 'lib';
use PVE::DC::PowerSave::Config;

my ($fh, $path) = tempfile();
close($fh);
my $cfg = PVE::DC::PowerSave::Config->defaults;
my $digest = PVE::DC::PowerSave::Config->digest($path);
my $saved = PVE::DC::PowerSave::Config->save($cfg, $path, $digest);
is(PVE::DC::PowerSave::Config->load($path)->{enabled}, 0, 'configuration starts disabled');
is($saved, PVE::DC::PowerSave::Config->digest($path), 'digest follows write');
open(my $reader, '<', $path) or die "cannot open $path: $!";
my $before = do { local $/ = undef; my $raw = <$reader>; seek($reader, 0, 0); $raw };
$saved = PVE::DC::PowerSave::Config->save({ %$cfg, enabled => 1 }, $path, $saved);
my $seen = do { local $/ = undef; <$reader> };
close($reader);
is($seen, $before, 'save replaces the file instead of truncating it under concurrent readers');
is(PVE::DC::PowerSave::Config->load($path)->{enabled}, 1, 'replacement content is visible to new readers');
my $dir = $path; $dir =~ s|/[^/]+$||;
opendir(my $dh, $dir) or die "cannot list $dir: $!";
my ($base) = $path =~ m|([^/]+)$|;
is_deeply([grep { /^\Q$base\E\.tmp\./ } readdir($dh)], [], 'no temporary file is left behind');
closedir($dh);
eval { PVE::DC::PowerSave::Config->save({ %$cfg, enabled => 1 }, $path, $digest) };
like($@, qr/configuration changed/, 'stale UI write is rejected');
eval { PVE::DC::PowerSave::Config->parse("enabled: 1\nidle_governor: powersave;touch /tmp/x\n") };
like($@, qr/invalid idle_governor/, 'governor cannot contain shell syntax');
eval { PVE::DC::PowerSave::Config->parse("enabled: 1\nreconciliation_interval: 2\n") };
like($@, qr/reconciliation_interval must be 5\.\.3600/, 'interval range is enforced');
eval { PVE::DC::PowerSave::Config->parse("enabled: 1\nenabled_by: me\nthis is not a setting\n") };
like($@, qr/invalid configuration line: this is not a setting/, 'a line that is not key: value is invalid');

# An existing file without an enabled line is an error, not "disabled".
for my $case (['empty file', ''], ['whitespace only', "  \n\n\t\n"], ['comments only', "# nothing here\n# enabled: 1\n"],
              ['truncated before enabled', "active_governor: performance\nidle_governor: powersave\n"],
              ['truncated mid-line', "enab"]) {
    my ($name, $raw) = @$case;
    eval { PVE::DC::PowerSave::Config->parse($raw) };
    like($@, qr/enabled|invalid configuration line/, "$name: parse reports the problem");
    my $report = PVE::DC::PowerSave::Config->parse_report($raw);
    ok(!defined $report->{enabled}, "$name: enabled is not defined in the report");
    ok(scalar @{$report->{errors}}, "$name: the report has an error");
}
my ($empty_fh, $empty) = tempfile();
close($empty_fh);
eval { PVE::DC::PowerSave::Config->load($empty) };
like($@, qr/missing setting: enabled/, 'load of an empty existing file dies');
ok(!PVE::DC::PowerSave::Config->load_report($empty)->{enabled} && @{PVE::DC::PowerSave::Config->load_report($empty)->{errors}},
    'load_report of an empty existing file is an error');
unlink($empty);
my $missing = PVE::DC::PowerSave::Config->load("$empty.missing");
is($missing->{enabled}, 0, 'a missing file still means the defaults');
my $missing_report = PVE::DC::PowerSave::Config->load_report("$empty.missing");
is_deeply([$missing_report->{exists}, $missing_report->{errors}], [0, []], 'a missing file is not an error in the report');
my $partial = PVE::DC::PowerSave::Config->parse("enabled: 1\n");
is($partial->{idle_governor}, 'powersave', 'other missing keys take their defaults');
is($partial->{boot_protection_period}, 120, 'missing numbers take their defaults');

# Unknown keys are warnings, and save keeps them.
my $unknown_raw = "enabled: 1\nfuture_key: 7\nidle_governor: powersave # note\nsensor2: a b\n";
is(PVE::DC::PowerSave::Config->parse($unknown_raw)->{enabled}, 1, 'configuration with unknown keys still parses');
my @parsed = PVE::DC::PowerSave::Config->parse($unknown_raw);
is(scalar @parsed, 1, 'parse returns a single value in list context');
my $unknown_report = PVE::DC::PowerSave::Config->parse_report($unknown_raw);
is_deeply($unknown_report->{warnings}, ["unknown setting ignored: future_key\n", "unknown setting ignored: sensor2\n"],
    'unknown keys are reported as warnings');
is_deeply($unknown_report->{errors}, [], 'unknown keys are not errors');
my ($uf, $upath) = tempfile();
print {$uf} "# header\nenabled: 1\nfuture_key: 7  \nactive_governor: performance\nsensor2: a b # keep\n";
close($uf);
my $udigest = PVE::DC::PowerSave::Config->digest($upath);
my $loaded = PVE::DC::PowerSave::Config->load($upath);
$loaded->{idle_candidate_delay} = 9;
my $new_digest = PVE::DC::PowerSave::Config->save($loaded, $upath, $udigest);
open(my $ur, '<', $upath) or die "cannot open $upath: $!";
my @saved = <$ur>;
close($ur);
is_deeply([grep { /^(?:future_key|sensor2)/ } @saved], ["future_key: 7\n", "sensor2: a b # keep\n"],
    'save keeps unknown lines verbatim and in their original order');
is($saved[-1], "sensor2: a b # keep\n", 'unknown lines follow the known settings');
is(PVE::DC::PowerSave::Config->load($upath)->{idle_candidate_delay}, 9, 'known settings are updated by the save');
is($new_digest, PVE::DC::PowerSave::Config->digest($upath), 'save still returns the new digest');
PVE::DC::PowerSave::Config->save(PVE::DC::PowerSave::Config->load($upath), $upath, $new_digest);
open($ur, '<', $upath) or die "cannot open $upath: $!";
is(scalar(grep { /^future_key/ } <$ur>), 1, 'saving twice does not duplicate unknown lines');
close($ur);
unlink($upath);

# A disabled policy is visible even when other lines are invalid.
my $disabled = PVE::DC::PowerSave::Config->parse_report("enabled: 0\nidle_governor: bad;gov\nthis is junk\n");
is($disabled->{enabled}, 0, 'a valid enabled: 0 is reported despite other invalid lines');
is(scalar @{$disabled->{errors}}, 2, 'the invalid lines are still listed');
is($disabled->{cfg}{idle_governor}, 'powersave', 'an invalid value falls back to its default');
unlink($path);
done_testing;
