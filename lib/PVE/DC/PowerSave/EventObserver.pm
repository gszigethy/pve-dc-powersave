package PVE::DC::PowerSave::EventObserver;
use strict;
use warnings;
use JSON::PP;
use PVE::DC::PowerSave::RuntimeStateCollector;

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
    # Only tasks that can change this node's decision count: non-console
    # tasks on this node, and migrations anywhere. A finished task stays in
    # the list with an "ended" marker, so a guest start that begins and ends
    # between two polls still changes the fingerprint. The list is the
    # cluster broadcast, which PVE already bounds in size.
    my $node = $self->{collector}{node};
    my @relevant;
    for my $task (grep { ref($_) eq 'HASH' } @$tasks) {
        my $type = $task->{type} // '';
        my $local = !defined($node) || !defined($task->{node}) || $task->{node} eq $node;
        next if !PVE::DC::PowerSave::RuntimeStateCollector::is_migration_task($type)
            && !($local && !PVE::DC::PowerSave::RuntimeStateCollector::is_console_task($type));
        my $ended = $task->{endtime} || ($task->{status} // '') =~ /^(?:OK|ERROR|WARNINGS)$/;
        push @relevant, ($task->{upid} // '') . ($ended ? '#ended' : '');
    }
    @relevant = sort @relevant;
    return JSON::PP->new->canonical->encode(\@relevant);
}
1;
