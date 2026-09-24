use strict;
use warnings;
use Test::More;
use lib 'lib';
use PVE::DC::PowerSave::RuntimeStateCollector;
use PVE::DC::PowerSave::EventObserver;

{ package FixtureCollector;
  our @ISA = ('PVE::DC::PowerSave::RuntimeStateCollector');
  sub _json {
      my ($self, $verb, $path, @args) = @_;
      die 'cluster task endpoint accepts no limit option' if $path eq '/cluster/tasks' && @args;
      return (0, undef, 'fixture unavailable') if !exists $self->{fixture}{$path};
      return (1, $self->{fixture}{$path}, undef);
  }
}

my $collector = FixtureCollector->new(node => 'pve01');
$collector->{fixture} = {
    '/cluster/status' => [ { type => 'cluster', quorate => 1 }, { type => 'node', name => 'pve01', online => 1 } ],
    '/nodes/pve01/qemu' => [ { vmid => 100, status => 'stopped' } ],
    '/nodes/pve01/lxc' => [ { vmid => 101, status => 'stopped' } ],
    '/cluster/tasks' => [],
    '/nodes/pve01/tasks' => [],
};
my $state = $collector->collect(0);
ok($state->{known} && $state->{tasks_known}, 'complete empty snapshot');
is($state->{running_guests}, 0, 'stopped guests do not count as workload');
$collector->{fixture}{'/nodes/pve01/qemu'}[0]{status} = 'running';
$state = $collector->collect(0);
is($state->{running_vm_count}, 1, 'running VM counts as workload');
$collector->{fixture}{'/nodes/pve01/qemu'}[0]{status} = 'stopped';
$collector->{fixture}{'/cluster/tasks'} = [ { type => 'qmigrate', node => 'pve02', upid => 'UPID:abc' } ];
my $observer = PVE::DC::PowerSave::EventObserver->new($collector);
is($observer->fingerprint, '["UPID:abc"]', 'active task wakes reconciliation');
$state = $collector->collect(0);
ok($state->{protected}, 'migration with unknown target protects every node');
is($state->{protection_reason}, 'migration_target_unknown', 'reason identifies uncertainty');
$collector->{fixture}{'/cluster/tasks'}[0]{target} = '100';
$state = $collector->collect(0);
ok($state->{protected}, 'guest ID in target field cannot be mistaken for destination node');
$collector->{fixture}{'/cluster/tasks'}[0]{endtime} = 1;
is($observer->fingerprint, '[]', 'terminal task wakes reconciliation');
$state = $collector->collect(0);
ok(!$state->{protected}, 'terminal migration releases protection');
$collector->{fixture}{'/nodes/pve01/tasks'} = [ { type => 'qmstart', node => 'pve01', upid => 'UPID:local' } ];
$state = $collector->collect(0);
ok($state->{protected}, 'local active task protects even if cluster task view lags');
$collector->{fixture}{'/nodes/pve01/tasks'} = [];
$collector->{fixture}{'/cluster/status'}[2] = { type => 'node', name => 'pve02', online => 1 };
$collector->{fixture}{'/nodes/pve02/tasks'} = [ { type => 'qmigrate', node => 'pve02', upid => 'UPID:remote' } ];
$state = $collector->collect(0);
ok($state->{protected}, 'remote source task protects target despite stale cluster task list');
$collector->{fixture}{'/nodes/pve02/tasks'} = [];
$collector->{fixture}{'/cluster/status'}[0]{quorate} = 0;
$state = $collector->collect(0);
ok(!$state->{known}, 'lost quorum invalidates runtime snapshot');
done_testing;
