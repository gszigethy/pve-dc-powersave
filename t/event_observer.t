use strict;
use warnings;
use Test::More;
use lib 'lib';
use PVE::DC::PowerSave::EventObserver;

{ package FakeCollector;
  sub new { bless { calls => 0, tasks => [], node => 'pve01' }, shift }
  sub _json { my ($self) = @_; $self->{calls}++; return (1, $self->{tasks}, undef); }
}

my $collector = FakeCollector->new;
my @cluster_tasks = (
    { upid => 'UPID:b', type => 'qmigrate', node => 'pve02' },
    { upid => 'UPID:a', type => 'vzdump', node => 'pve01' },
    { upid => 'UPID:done', type => 'qmstart', node => 'pve01', endtime => 10, status => 'OK' },
);
my $observer = PVE::DC::PowerSave::EventObserver->new($collector, tasklist => sub { return [@cluster_tasks] });
is($observer->fingerprint, '["UPID:a","UPID:b","UPID:done#ended"]',
    'in-process task list yields sorted task IDs, finished ones marked');
is($collector->{calls}, 0, 'in-process task list does not start pvesh');

# Tasks that cannot change this node's decision do not wake it.
my $print = sub {
    my @tasks = @_;
    return PVE::DC::PowerSave::EventObserver->new($collector, tasklist => sub { return [@tasks] })->fingerprint;
};
my @base = ({ upid => 'UPID:a', type => 'vzdump', node => 'pve01' });
my $quiet = $print->(@base);
my @consoles = map { { upid => "UPID:c$_", type => $_, node => 'pve01' } }
    qw(vncproxy vncshell spiceproxy spiceshell termproxy);
is($print->(@base, @consoles), $quiet, 'open console sessions do not change the fingerprint');
is($print->(@base, map { { %$_, endtime => 5, status => 'OK' } } @consoles), $quiet,
    'closing a console session does not change it either');
is($print->(@base, { upid => 'UPID:r', type => 'vzdump', node => 'pve02' }), $quiet,
    'a backup on another node does not change it');
is($print->(@base, { upid => 'UPID:r', type => 'dirremove', node => 'pve02' }), $quiet,
    'a storage removal on another node does not change it');
isnt($print->(@base, { upid => 'UPID:m', type => 'hamigrate', node => 'pve02' }), $quiet,
    'a migration on another node changes it');
isnt($print->(@base, { upid => 'UPID:m', type => 'vzdump', node => 'pve01' }), $quiet,
    'a new local task changes it');

# A guest start that begins and ends between two polls is still noticed.
my $before = $print->(@base);
my $running = $print->(@base, { upid => 'UPID:s', type => 'qmstart', node => 'pve01' });
my $finished = $print->(@base, { upid => 'UPID:s', type => 'qmstart', node => 'pve01', endtime => 9, status => 'OK' });
isnt($finished, $before, 'a finished qmstart changes the fingerprint');
isnt($finished, $running, 'the end of a task changes it again');
is($print->(reverse(@base, { upid => 'UPID:s', type => 'qmstart', node => 'pve01', endtime => 9, status => 'OK' })),
    $finished, 'fingerprint does not depend on list order');
is($print->(@base, { upid => 'UPID:s', type => 'qmstart', node => 'pve01', status => 'OK' }), $finished,
    'terminal status alone also marks a task ended');

$collector->{tasks} = [ { upid => 'UPID:fallback' } ];
$observer = PVE::DC::PowerSave::EventObserver->new($collector, tasklist => sub { die "ipcc failed\n" });
is($observer->fingerprint, '["UPID:fallback"]', 'failing in-process task list falls back to pvesh');
is($collector->{calls}, 1, 'fallback queries pvesh once');

$observer = PVE::DC::PowerSave::EventObserver->new($collector, tasklist => sub { return });
is($observer->fingerprint, '["UPID:fallback"]', 'missing in-process task list falls back to pvesh');

$observer = PVE::DC::PowerSave::EventObserver->new($collector, tasklist => undef);
is($observer->fingerprint, '["UPID:fallback"]', 'no in-process source uses pvesh');

{ package PVE::Cluster;
  our @updates;
  sub cfs_update { push @updates, [@_]; return; }
  sub get_tasklist { return [ { upid => 'UPID:pmxcfs' } ]; }
  $INC{'PVE/Cluster.pm'} = __FILE__;
}
$collector->{calls} = 0;
$observer = PVE::DC::PowerSave::EventObserver->new($collector);
is($observer->fingerprint, '["UPID:pmxcfs"]', 'default source is the PVE::Cluster task list');
is_deeply(\@PVE::Cluster::updates, [[1]], 'cluster state is refreshed and IPC errors are raised, not warned');
is($collector->{calls}, 0, 'default source does not start pvesh');

$collector->{tasks} = undef;
$observer = PVE::DC::PowerSave::EventObserver->new($collector, tasklist => undef);
is($observer->fingerprint, 'task-query-error', 'unusable task data is a distinct fingerprint');
done_testing;
