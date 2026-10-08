use strict;
use warnings;
use Test::More;
use Errno qw(EBUSY);
use File::Temp qw(tempdir);
use lib 'lib';
use PVE::DC::PowerSave::CpupowerBackend;

{ package FixtureBackend;
  our @ISA = ('PVE::DC::PowerSave::CpupowerBackend');
  # Reading attributes of an inactive cpufreq policy fails with EBUSY. A
  # plain file cannot reproduce that, so a marker file stands in for it.
  sub _read_attr {
      my ($self, $path) = @_;
      my ($policy) = $path =~ m|^(.*)/[^/]+$|;
      return (undef, Errno::EBUSY()) if -e "$policy/.inactive";
      return $self->SUPER::_read_attr($path);
  }
}

my $dir = tempdir(CLEANUP => 1);
my $sysfs = "$dir/cpufreq";
sub write_file { my ($path, $text) = @_; open(my $fh, '>', $path) or die "$path: $!"; print {$fh} $text; close($fh) or die; return; }
sub policy {
    my ($index, %attr) = @_;
    my $path = "$sysfs/policy$index";
    mkdir($sysfs); mkdir($path);
    write_file("$path/scaling_available_governors", ($attr{available} // 'performance powersave') . "\n");
    write_file("$path/scaling_governor", ($attr{current} // 'performance') . "\n");
    write_file("$path/scaling_driver", "acpi-cpufreq\n");
    write_file("$path/related_cpus", "$index\n");
    return $path;
}

# A fake cpupower that writes the requested governor to every active policy.
my $cpupower = "$dir/cpupower";
write_file($cpupower, <<"SH");
#!/bin/sh
[ "\$1" = "--version" ] && { echo "cpupower 6.8.12"; exit 0; }
[ "\$1 \$2 \$3 \$4" = "-c all frequency-set -g" ] || exit 2
for policy in $sysfs/policy*; do
    [ -e "\$policy/.inactive" ] || echo "\$5" > "\$policy/scaling_governor"
done
SH
chmod(oct('0755'), $cpupower) or die;

my $backend = FixtureBackend->new($cpupower);
$backend->{sysfs} = $sysfs;
policy(0); policy(1);
my $cap = $backend->discover;
ok($cap->{valid}, 'readable policies are valid');
is($cap->{cpupower_version}, 'cpupower 6.8.12', 'cpupower version is reported');
is(scalar @{$cap->{policies}}, 2, 'every policy is discovered');
is_deeply([sort keys %{$cap->{governors}}], [qw(performance powersave)], 'node governors are the policy intersection');
ok($backend->supports_all($cap, 'powersave'), 'governor present on every policy is supported');
ok(!$backend->supports_all($cap, 'schedutil'), 'missing governor is unsupported');

my ($ok, $error) = $backend->verify_governor('powersave');
ok(!$ok, 'readback detects the current governor differs');
is($error, 'governor readback mismatch', 'readback mismatch is explained');
ok(($backend->set_governor('powersave'))[0], 'cpupower applies a governor');
ok(($backend->verify_governor('powersave'))[0], 'readback confirms the applied governor');
ok(!($backend->set_governor('powersave;reboot'))[0], 'governor names cannot carry shell syntax');

my $offline = policy(2, available => 'performance powersave', current => 'performance');
write_file("$offline/.inactive", '');
$cap = $backend->discover;
ok($cap->{valid}, 'an offline CPU policy does not invalidate the node');
is_deeply([map { $_->{path} } @{$cap->{policies}}], ["$sysfs/policy0", "$sysfs/policy1"], 'offline CPU policy is skipped');
ok($backend->supports_all($cap, 'powersave'), 'offline CPU policy does not remove governors');
ok(($backend->verify_governor('powersave'))[0], 'readback ignores the offline CPU policy');

unlink("$offline/.inactive");
unlink("$offline/scaling_driver");
$cap = $backend->discover;
ok(!$cap->{valid}, 'a partly unreadable policy still fails closed');
like($cap->{error}, qr/unreadable policy .*policy2/, 'unreadable policy is named');

policy(2);
write_file("$_/.inactive", '') for glob("$sysfs/policy*");
$cap = $backend->discover;
ok(!$cap->{valid}, 'no active policy is not a valid capability report');
is($cap->{error}, 'no active CPU frequency policies', 'no active policy is explained');

my $missing = PVE::DC::PowerSave::CpupowerBackend->new("$dir/absent");
is($missing->discover->{error}, 'cpupower executable missing', 'missing cpupower is reported');
done_testing;
