use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use lib 'lib';
use PVE::DC::PowerSave::Config;
use PVE::DC::PowerSave::Controller;

{ package FakeCollector;
  sub new { bless { node => 'pve01', state => {} }, shift }
  sub collect { my ($self) = @_; return { %{$self->{state}} }; }
}
{ package FakeBackend;
  sub new { bless { cpupower => '/fake/cpupower', current => 'performance' }, shift }
  sub discover {
      my ($self) = @_;
      return { valid => 1, governors => { performance => 1, powersave => 1 },
               policies => [ { current => $self->{current}, governors => { performance => 1, powersave => 1 } } ] };
  }
  sub supports_all { my ($self, $cap, $gov) = @_; return $cap->{policies}[0]{governors}{$gov}; }
  sub verify_governor { my ($self, $gov) = @_; return ($self->{current} eq $gov, 'readback mismatch'); }
  sub set_governor { my ($self, $gov) = @_; $self->{current} = $gov; return (1, '', ''); }
}

my $dir = tempdir(CLEANUP => 1);
my $config = "$dir/governors.cfg";
my $cfg = { %{PVE::DC::PowerSave::Config->defaults}, enabled => 1, boot_protection_period => 0,
            active_governor => 'ondemand' };
PVE::DC::PowerSave::Config->save($cfg, $config, PVE::DC::PowerSave::Config->digest($config));
my $busy = FakeCollector->new;
$busy->{state} = { known => 1, tasks_known => 1, node_available => 1, running_guests => 1, running_vm_count => 1 };
my $backend = FakeBackend->new;
my $controller = PVE::DC::PowerSave::Controller->new(
    config_path => $config, collector => $busy, backend => $backend,
    lock_path => "$dir/lock", status_path => "$dir/status.json",
);
my $status = $controller->reconcile;
is($status->{reason}, 'configured_governor_unavailable', 'unsupported active governor is reported');
is($status->{desired_governor}, 'performance', 'status shows the failsafe governor actually requested');
is($status->{prerequisites}{cpu_policies}[0]{requested_governor}, 'performance', 'policy detail shows the requested failsafe governor');
is($backend->{current}, 'performance', 'failsafe governor is applied');

$cfg->{failsafe_governor} = 'conservative';
PVE::DC::PowerSave::Config->save($cfg, $config, PVE::DC::PowerSave::Config->digest($config));
$status = $controller->reconcile;
like($status->{last_error}, qr/^ondemand is unavailable.*; failsafe governor conservative is unavailable/,
    'error names both the requested and the unusable failsafe governor');

mkdir("$dir/status-is-a-directory") or die "mkdir: $!";
my $unpublishable = PVE::DC::PowerSave::Controller->new(
    config_path => $config, collector => $busy, backend => $backend,
    lock_path => "$dir/lock", status_path => "$dir/status-is-a-directory",
);
eval { $unpublishable->reconcile };
like($@, qr/cannot publish status/, 'status publication failure is reported');
ok(!-e "$dir/status-is-a-directory.$$", 'failed status publication leaves no temporary file');
done_testing;
