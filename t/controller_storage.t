use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use lib 'lib';
use PVE::DC::PowerSave::Config;
use PVE::DC::PowerSave::Controller;

{ package FakeCollector;
  sub new { bless { node => 'pve01', reads => 0, state => {} }, shift }
  sub collect { my ($self) = @_; $self->{reads}++; return { %{$self->{state}} }; }
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
my $config_path = "$dir/config.cfg";
my $cfg = PVE::DC::PowerSave::Config->defaults;
$cfg->{enabled} = 1;
$cfg->{idle_candidate_delay} = 0;
$cfg->{boot_protection_period} = 0;
PVE::DC::PowerSave::Config->save($cfg, $config_path, PVE::DC::PowerSave::Config->digest($config_path));
my $collector = FakeCollector->new;
my $backend = FakeBackend->new;
my $controller = PVE::DC::PowerSave::Controller->new(
    config_path => $config_path, collector => $collector, backend => $backend,
    lock_path => "$dir/lock", status_path => "$dir/status.json",
);
my %empty = (known => 1, tasks_known => 1, node_available => 1, running_guests => 0);

$collector->{state} = { %empty, storage_services => ['ceph-osd', 'nfsd'] };
my $status = $controller->reconcile;
is($status->{state}, 'ACTIVE', 'node with storage services is not idled');
is($status->{reason}, 'storage_service', 'status reason names the storage service');
is_deeply($status->{storage_services}, ['ceph-osd', 'nfsd'], 'status lists the services found');
is($collector->{reads}, 1, 'no idle confirmation is attempted');
is($controller->{idle_seen_at}, undef, 'idle timer does not run while storage services are up');
is($backend->{current}, 'performance', 'active governor stays applied');

$collector->{state} = { %empty, storage_unknown => 1, storage_error => 'cannot read /proc' };
$collector->{reads} = 0;
$status = $controller->reconcile;
is($status->{reason}, 'storage_state_unknown', 'failed scan is reported');
is($status->{storage_error}, 'cannot read /proc', 'status carries the scan error');
is($collector->{reads}, 1, 'a failed scan never reaches the confirmation read');

$collector->{state} = { %empty, tasks_known => 0,
    task_state_detail => [ { node => 'pve02', error => 'ssh failed', retry_after => 99 } ] };
$status = $controller->reconcile;
is($status->{state}, 'ACTIVE', 'unreachable member is not an ERROR');
is($status->{reason}, 'task_state_unknown', 'it keeps the node active');
is($status->{task_state_detail}[0]{node}, 'pve02', 'status names the unreachable member');
ok(!$status->{last_error}, 'no error is raised for it');

$collector->{state} = { %empty, storage_services => [] };
$status = $controller->reconcile;
is($status->{state}, 'IDLE', 'without storage services the node still idles');
is_deeply($status->{storage_services}, [], 'status shows an empty service list');
done_testing;
