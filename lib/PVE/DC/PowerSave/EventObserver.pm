package PVE::DC::PowerSave::EventObserver;
use strict;
use warnings;
use JSON::PP;

sub new { return bless { collector => $_[1] }, $_[0] }

sub fingerprint {
    my ($self) = @_;
    my ($ok, $tasks) = $self->{collector}->_json('get', '/cluster/tasks');
    return 'task-query-error' if !$ok || ref($tasks) ne 'ARRAY';
    # This is only a wake-up hint. Reconciliation collects authoritative
    # runtime state independently, and its safety timer handles missed events.
    my @active = sort map { $_->{upid} // '' } grep {
        !$_->{endtime} && ($_->{status} // '') !~ /^(?:OK|ERROR|WARNINGS)$/
    } @$tasks;
    return JSON::PP->new->canonical->encode(\@active);
}
1;
