use strict;
use warnings;
use Test::More;
use lib 'lib';
use PVE::DC::PowerSave::EventObserver;

{ package FakeCollector;
  sub new { bless { calls => 0, tasks => [] }, shift }
  sub _json { my ($self) = @_; $self->{calls}++; return (1, $self->{tasks}, undef); }
}

my $collector = FakeCollector->new;
my @cluster_tasks = (
    { upid => 'UPID:b', type => 'qmigrate' },
    { upid => 'UPID:a', type => 'vzdump' },
    { upid => 'UPID:done', type => 'qmstart', endtime => 10, status => 'OK' },
);
my $observer = PVE::DC::PowerSave::EventObserver->new($collector, tasklist => sub { return [@cluster_tasks] });
is($observer->fingerprint, '["UPID:a","UPID:b"]', 'in-process task list yields sorted active task IDs');
is($collector->{calls}, 0, 'in-process task list does not start pvesh');

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
