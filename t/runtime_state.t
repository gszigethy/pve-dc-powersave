use strict;
use warnings;
use Test::More;
use lib 'lib';
use PVE::DC::PowerSave::RuntimeStateCollector;
use PVE::DC::PowerSave::EventObserver;
use PVE::DC::PowerSave::DesiredState;
use File::Temp qw(tempdir);

# A fake /proc: the collector never reads the real process table in tests.
sub add_proc {
    my ($root, $pid, $cmdline, $comm) = @_;
    mkdir("$root/$pid") or die "mkdir $root/$pid: $!";
    for my $file (['cmdline', $cmdline], ['comm', "$comm\n"]) {
        open(my $fh, '>', "$root/$pid/$file->[0]") or die "write: $!";
        print {$fh} $file->[1];
        close($fh);
    }
    return;
}
my $proc = tempdir(CLEANUP => 1);
add_proc($proc, 1, "/sbin/init\0splash\0", 'systemd');
add_proc($proc, 2, '', 'kthreadd');
add_proc($proc, 300, "/usr/bin/python3\0/usr/bin/ceph-osd\0", 'python3');
add_proc($proc, 301, "sleep\0600\0", 'ceph-osd');

{ package FixtureCollector;
  our @ISA = ('PVE::DC::PowerSave::RuntimeStateCollector');
  sub _json {
      my ($self, $verb, $path, @args) = @_;
      push @{$self->{calls}}, $path;
      die 'cluster task endpoint accepts no limit option' if $path eq '/cluster/tasks' && @args;
      return (0, undef, 'fixture unavailable') if !exists $self->{fixture}{$path};
      return (1, $self->{fixture}{$path}, undef);
  }
}

my $collector = FixtureCollector->new(node => 'pve01', proc_root => $proc, clock => sub { $main::now });
our $now = 1000;
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
is($observer->fingerprint, '["UPID:abc#ended"]', 'terminal task wakes reconciliation');
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
$collector->{fixture}{'/nodes/pve01/tasks'} = [ { type => 'vzdump', node => 'pve01', upid => 'UPID:backup' } ];
$state = $collector->collect(0);
ok($state->{protected}, 'local backup keeps a node with only stopped guests out of idle');
is($state->{protection_reason}, 'node_task', 'reason identifies a local host task');
is($state->{protection_task}, 'UPID:backup', 'protecting task is reported');
$collector->{fixture}{'/nodes/pve01/tasks'} = [ { type => 'somefuturetask', node => 'pve01', upid => 'UPID:new' } ];
ok($collector->collect(0)->{protected}, 'unknown local task type fails safe as work');
$collector->{fixture}{'/nodes/pve01/tasks'} = [ map { { type => $_, node => 'pve01', upid => "UPID:$_" } }
    qw(vncproxy vncshell spiceproxy spiceshell termproxy) ];
ok(!$collector->collect(0)->{protected}, 'open console sessions do not block idle');
$collector->{fixture}{'/nodes/pve01/tasks'} = [];
$collector->{fixture}{'/nodes/pve02/tasks'} = [ { type => 'vzdump', node => 'pve02', upid => 'UPID:remote-backup' } ];
ok(!$collector->collect(0)->{protected}, 'another node backup does not protect this node');
$collector->{fixture}{'/nodes/pve02/tasks'} = [];
$collector->{fixture}{'/cluster/tasks'} = [ { type => 'vzdump', node => 'pve01', upid => 'UPID:done', endtime => 1, status => 'OK' } ];
ok(!$collector->collect(0)->{protected}, 'finished local backup releases protection');
is_deeply($collector->collect(0)->{storage_services}, [], 'processes that merely mention a storage name are not storage services');
ok(!$collector->collect(0)->{storage_unknown}, 'a readable /proc is a complete scan');

# Storage services keep a node active.
add_proc($proc, 4242, "/usr/bin/ceph-osd\0-f\0--cluster\0ceph\0--id\0 0\0", 'ceph-osd');
$state = $collector->collect(0);
is_deeply($state->{storage_services}, ['ceph-osd'], 'ceph-osd process is reported as storage service');
my $cfg = { enabled => 1, active_governor => 'performance', idle_governor => 'powersave', migration_governor => 'performance' };
my $cap = { valid => 1, policies => [ { governors => { performance => 1, powersave => 1 } } ] };
my $decision = PVE::DC::PowerSave::DesiredState->decide('pve01', $cfg, { %$state, idle_confirmed => 1 }, $cap);
is($decision->{state}, 'ACTIVE', 'node running ceph-osd stays active');
is($decision->{reason}, 'storage_service', 'reason names the storage service');
system('rm', '-rf', "$proc/4242");
add_proc($proc, 77, '', 'nfsd');
$state = $collector->collect(0);
is_deeply($state->{storage_services}, ['nfsd'], 'nfsd kernel thread is matched by comm');
$decision = PVE::DC::PowerSave::DesiredState->decide('pve01', $cfg, { %$state, idle_confirmed => 1 }, $cap);
is($decision->{reason}, 'storage_service', 'nfsd kernel thread keeps the node active');
add_proc($proc, 78, "/usr/lib/x86_64-linux-gnu/proxmox-backup/proxmox-backup-proxy\0", 'proxmox-backup-');
add_proc($proc, 79, "/usr/sbin/glusterfsd\0-s\0node\0", 'glusterfsd');
add_proc($proc, 80, "tgtd\0-f\0", 'tgtd');
add_proc($proc, 81, "/usr/bin/ceph-osd\0", 'ceph-osd');
add_proc($proc, 82, "/usr/bin/ceph-mon\0", 'ceph-mon');
add_proc($proc, 83, "/usr/bin/ceph-mds\0", 'ceph-mds');
is_deeply($collector->collect(0)->{storage_services},
    [qw(ceph-mds ceph-mon ceph-osd glusterfsd nfsd proxmox-backup-proxy tgtd)],
    'every listed service is found once, by argv[0] basename (comm of PBS is truncated)');
for my $pid (77 .. 83) { system('rm', '-rf', "$proc/$pid"); }
is_deeply($collector->collect(0)->{storage_services}, [], 'stopped services disappear from the report');

# An unreadable process table is no proof.
my $broken = FixtureCollector->new(node => 'pve01', proc_root => "$proc/missing");
$broken->{fixture} = $collector->{fixture};
$state = $broken->collect(0);
ok($state->{storage_unknown}, 'unreadable /proc is reported as unknown');
like($state->{storage_error}, qr/cannot read/, 'unknown storage state has a reason');
$decision = PVE::DC::PowerSave::DesiredState->decide('pve01', $cfg, { %$state, idle_confirmed => 1 }, $cap);
is($decision->{state}, 'ACTIVE', 'a failed scan never proves idle');
mkdir("$proc/500") or die;
$state = $collector->collect(0);
ok($state->{storage_unknown}, 'a process whose cmdline cannot be read makes the scan incomplete');
rmdir("$proc/500");
my $empty = tempdir(CLEANUP => 1);
$broken = FixtureCollector->new(node => 'pve01', proc_root => $empty);
$broken->{fixture} = $collector->{fixture};
ok($broken->collect(0)->{storage_unknown}, 'a /proc without any process is not a valid scan');

# Task classification: only real relocations protect other nodes.
$collector->{fixture}{'/cluster/status'}[2] = { type => 'node', name => 'pve02', online => 1 };
$collector->{fixture}{'/cluster/tasks'} = [];
$collector->{fixture}{'/nodes/pve01/tasks'} = [];
for my $type (qw(dirremove lvmremove lvmthinremove zfsremove hastart hastop vzdump)) {
    $collector->{fixture}{'/nodes/pve02/tasks'} = [ { type => $type, node => 'pve02', upid => "UPID:$type" } ];
    ok(!$collector->collect(0)->{protected}, "$type on another node does not protect this node");
}
$collector->{fixture}{'/nodes/pve02/tasks'} = [];
$collector->{fixture}{'/nodes/pve01/tasks'} = [ { type => 'zfsremove', node => 'pve01', upid => 'UPID:zr' } ];
$state = $collector->collect(0);
is($state->{protection_reason}, 'node_task', 'a local storage removal is still local work, not a migration');
$collector->{fixture}{'/nodes/pve01/tasks'} = [];
for my $type (qw(qmigrate vzmigrate migrateall hamigrate harelocate futuremigration)) {
    $collector->{fixture}{'/nodes/pve02/tasks'} = [ { type => $type, node => 'pve02', upid => "UPID:$type" } ];
    $state = $collector->collect(0);
    is($state->{protection_reason}, 'migration_target_unknown', "$type with unknown target protects every node");
}
$collector->{fixture}{'/nodes/pve02/tasks'} = [];

# Member queries only happen when the node could otherwise idle.
$now = 1000;
my $calls = sub { scalar grep { $_ eq '/nodes/pve02/tasks' } @{$collector->{calls}} };
$collector->{calls} = [];
$state = $collector->collect(0);
is($calls->(), 1, 'idle-eligible node asks the other member for its active tasks');
$collector->{fixture}{'/nodes/pve01/qemu'}[0]{status} = 'running';
$collector->{calls} = [];
$state = $collector->collect(0);
is($calls->(), 0, 'no member query while a guest runs');
ok($state->{tasks_known}, 'the broadcast alone is enough while a guest runs');
$collector->{fixture}{'/nodes/pve01/qemu'}[0]{status} = 'stopped';
add_proc($proc, 4243, "/usr/bin/ceph-osd\0", 'ceph-osd');
$collector->{calls} = [];
$state = $collector->collect(0);
is($calls->(), 0, 'no member query while a storage service runs');
ok($state->{tasks_known}, 'task state is known from the broadcast on a storage node');
system('rm', '-rf', "$proc/4243");
$collector->{fixture}{'/cluster/tasks'} = [ { type => 'qmigrate', node => 'pve02', upid => 'UPID:bc' } ];
$collector->{calls} = [];
$state = $collector->collect(0);
is($calls->(), 0, 'no member query when the broadcast already protects the node');
ok($state->{protected} && $state->{tasks_known}, 'protection from the broadcast needs no member view');
$collector->{fixture}{'/cluster/tasks'} = [];

# One failing member is no proof, not an error, and is not hammered.
delete $collector->{fixture}{'/nodes/pve02/tasks'};
$collector->{calls} = [];
$state = $collector->collect(0);
ok(!$state->{tasks_known}, 'failed member query means task state is unknown');
ok(!defined $state->{error}, 'a failed member query is not a collection error');
ok($state->{known}, 'local runtime state stays known');
is($state->{task_state_detail}[0]{node}, 'pve02', 'detail names the failing member');
like($state->{task_state_detail}[0]{error}, qr/fixture unavailable/, 'detail carries the reason');
$decision = PVE::DC::PowerSave::DesiredState->decide('pve01', $cfg, { %$state, idle_confirmed => 1 }, $cap);
is($decision->{state}, 'ACTIVE', 'member failure keeps the node active');
is($decision->{reason}, 'task_state_unknown', 'reason is task_state_unknown');
is($calls->(), 1, 'failing member queried once');
$now += 30;
$state = $collector->collect(0);
is($calls->(), 1, 'failing member is not queried again within 60 s');
ok(!$state->{tasks_known}, 'while backing off there is still no proof');
like($state->{task_state_detail}[0]{error}, qr/fixture unavailable/, 'backoff keeps the reason visible');
$now += 31;
$collector->{fixture}{'/nodes/pve02/tasks'} = [];
$state = $collector->collect(0);
is($calls->(), 2, 'failing member is queried again after the backoff');
ok($state->{tasks_known}, 'recovered member restores task knowledge');
is_deeply($state->{task_state_detail}, [], 'no detail once every member answers');
$collector->{fixture}{'/nodes/pve02/tasks'} = [ map { { type => 'vzdump', node => 'pve02', upid => "UPID:n$_" } } 1 .. 500 ];
$now += 100;
$state = $collector->collect(0);
ok(!$state->{tasks_known}, 'a truncated member list is still no proof');
like($state->{task_state_detail}[0]{error}, qr/truncated/, 'truncation is named');
$collector->{fixture}{'/cluster/status'}[0]{quorate} = 0;
$state = $collector->collect(0);
ok(!$state->{known}, 'lost quorum invalidates runtime snapshot');
done_testing;
