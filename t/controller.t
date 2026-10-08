use strict;
use warnings;
use Test::More;
use Fcntl qw(:flock);
use File::Temp qw(tempdir);
use lib 'lib';
use PVE::DC::PowerSave::Config;
use PVE::DC::PowerSave::Controller;

{ package FakeCollector;
  sub new { bless { node => 'pve01', reads => 0, state => {} }, shift }
  sub collect {
      my ($self) = @_; $self->{reads}++;
      return { %{shift @{$self->{sequence}}} } if $self->{sequence} && @{$self->{sequence}};
      return { %{$self->{state}} };
  }
}
{ package FakeBackend;
  sub new { bless { cpupower => '/fake/cpupower', current => 'performance', changes => [] }, shift }
  sub discover {
      my ($self) = @_;
      return { valid => 1, governors => { performance => 1, powersave => 1 },
               policies => [ { current => $self->{current}, governors => { performance => 1, powersave => 1 } } ] };
  }
  sub supports_all { my ($self, $cap, $gov) = @_; return $cap->{policies}[0]{governors}{$gov}; }
  sub verify_governor { my ($self, $gov) = @_; return ($self->{current} eq $gov, 'readback mismatch'); }
  sub set_governor { my ($self, $gov) = @_; $self->{current} = $gov; push @{$self->{changes}}, $gov; return (1, '', ''); }
}

my $dir = tempdir(CLEANUP => 1);
my $config_path = "$dir/config.cfg";
my $cfg = PVE::DC::PowerSave::Config->defaults;
$cfg->{enabled} = 1;
$cfg->{idle_candidate_delay} = 0;
$cfg->{boot_protection_period} = 0;
PVE::DC::PowerSave::Config->save($cfg, $config_path, PVE::DC::PowerSave::Config->digest($config_path));
my $collector = FakeCollector->new;
$collector->{state} = { known => 1, tasks_known => 1, node_available => 1, running_guests => 0 };
my $backend = FakeBackend->new;
my $controller = PVE::DC::PowerSave::Controller->new(
    config_path => $config_path, collector => $collector, backend => $backend,
    lock_path => "$dir/lock", status_path => "$dir/status.json",
);
my $status = $controller->reconcile;
is($status->{state}, 'IDLE', 'complete double snapshot permits idle');
is($collector->{reads}, 2, 'idle transition re-reads authoritative state');
is($backend->{current}, 'powersave', 'idle governor was applied and verified');

$collector->{state} = { known => 0, tasks_known => 0, node_available => 1,
                        running_guests => 0, error => 'runtime unavailable' };
$status = $controller->reconcile;
is($status->{state}, 'ERROR', 'uncertain runtime is visible as an error');
is($status->{desired_governor}, 'performance', 'uncertainty requests active governor');
is($backend->{current}, 'performance', 'active governor is restored');

my $racing_collector = FakeCollector->new;
$racing_collector->{sequence} = [
    { known => 1, tasks_known => 1, node_available => 1, running_guests => 0 },
    { known => 1, tasks_known => 1, node_available => 1, running_guests => 1 },
];
my $racing_backend = FakeBackend->new;
my $racing_controller = PVE::DC::PowerSave::Controller->new(
    config_path => $config_path, collector => $racing_collector, backend => $racing_backend,
    lock_path => "$dir/race.lock", status_path => "$dir/race-status.json",
);
$status = $racing_controller->reconcile;
is($status->{state}, 'ACTIVE', 'guest appearing during final check cancels idle');
is($racing_backend->{current}, 'performance', 'race leaves active governor applied');
unlink($config_path);
$status = $controller->reconcile;
is($status->{state}, 'ERROR', 'loss of previously enabled shared configuration is an error');
is($status->{desired_governor}, 'performance', 'lost configuration requests failsafe governor');
$status = $controller->reconcile;
is($status->{state}, 'ERROR', 'lost configuration remains an error on later reconciliations');
is($status->{reason}, 'invalid_configuration', 'lost configuration is not reported as deliberately disabled');
$cfg->{enabled} = 0;
PVE::DC::PowerSave::Config->save($cfg, $config_path, PVE::DC::PowerSave::Config->digest($config_path));
is($controller->reconcile->{state}, 'DISABLED', 'restored disabled configuration clears the error');
unlink($config_path);
is($controller->reconcile->{state}, 'DISABLED', 'missing configuration after a disabled policy stays unmanaged');
is(PVE::DC::PowerSave::Controller->new->{lock_path}, '/run/pve-dc-powersave/controller.lock',
    'default lock lives in the service runtime directory, not world-writable /run/lock');
my $shared = "$dir/shared";
mkdir($shared) or die "mkdir $shared: $!";
chmod(oct('1777'), $shared) or die "chmod $shared: $!";
my $exposed = PVE::DC::PowerSave::Controller->new(
    config_path => $config_path, collector => $collector, backend => $backend,
    lock_path => "$shared/lock", status_path => "$dir/exposed-status.json",
);
eval { $exposed->reconcile };
like($@, qr/not writable by others/, 'lock in a directory other users can write is refused');
ok(!-e "$shared/lock", 'no lock file is created in an unsafe directory');
symlink("$dir/symlink-target", "$dir/symlink.lock") or die "symlink: $!";
my $linked = PVE::DC::PowerSave::Controller->new(
    config_path => $config_path, collector => $collector, backend => $backend,
    lock_path => "$dir/symlink.lock", status_path => "$dir/linked-status.json",
);
eval { $linked->reconcile };
like($@, qr/lock: cannot open/, 'symlinked lock file is not followed');
ok(!-e "$dir/symlink-target", 'symlink target is not created');
open(my $holder, '>>', "$dir/lock") or die "lock: $!";
flock($holder, LOCK_EX) or die "flock: $!";
is($controller->reconcile, undef, 'a held lock still skips an overlapping reconciliation');
close($holder);
ok($controller->reconcile, 'reconciliation resumes once the lock is released');
done_testing;
