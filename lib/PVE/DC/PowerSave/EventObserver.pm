package PVE::DC::PowerSave::EventObserver;
use strict;
use warnings;
use JSON::PP;

sub new {
    my ($class, $collector, %args) = @_;
    my $tasklist = exists $args{tasklist} ? $args{tasklist} : _cluster_tasklist();
    return bless { collector => $collector, tasklist => $tasklist }, $class;
}

# PVE::Cluster serves the pmxcfs task list that /cluster/tasks returns, over
# IPC. Polling it in process avoids starting a pvesh process, which loads
# the whole PVE API, every event_poll_interval.
sub _cluster_tasklist {
    return if !eval { require PVE::Cluster; 1 };
    return sub {
        PVE::Cluster::cfs_update(1);
        return PVE::Cluster::get_tasklist();
    };
}

sub fingerprint {
    my ($self) = @_;
    my $tasks = $self->{tasklist} ? eval { $self->{tasklist}->() } : undef;
    if (ref($tasks) ne 'ARRAY') {
        (my $ok, $tasks) = $self->{collector}->_json('get', '/cluster/tasks');
        return 'task-query-error' if !$ok || ref($tasks) ne 'ARRAY';
    }
    # This is only a wake-up hint. Reconciliation collects authoritative
    # runtime state independently, and its safety timer handles missed events.
    my @active = sort map { $_->{upid} // '' } grep {
        !$_->{endtime} && ($_->{status} // '') !~ /^(?:OK|ERROR|WARNINGS)$/
    } @$tasks;
    return JSON::PP->new->canonical->encode(\@active);
}
1;
