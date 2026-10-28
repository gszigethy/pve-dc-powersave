package PVE::DC::PowerSave::DesiredState;
use strict;
use warnings;

# True when a service for other nodes or clients runs here, or the scan that
# looks for one failed. Only a complete scan with no match is proof of absence.
sub storage_blocks_idle {
    my ($class, $runtime) = @_;
    return ($runtime->{storage_unknown} || @{$runtime->{storage_services} || []}) ? 1 : 0;
}

sub decide {
    my ($class, $node, $cfg, $runtime, $capability) = @_;
    my $active = sub { { state => 'ACTIVE', governor => $cfg->{active_governor}, reason => shift } };
    return $active->('plugin_disabled') if !$cfg->{enabled};
    return $active->('node_unavailable') if !$runtime->{node_available};
    return $active->('runtime_state_unknown') if !$runtime->{known};
    return $active->('boot_protection') if $runtime->{boot_protected};
    return $active->('prerequisite_failure') if !$capability->{valid};
    return $active->('task_state_unknown') if !$runtime->{tasks_known};
    return { state => 'PROTECTED', governor => $cfg->{migration_governor}, reason => $runtime->{protection_reason} || 'operation_in_progress', protected => 1 } if $runtime->{protected};
    return $active->('running_guest') if $runtime->{running_guests} > 0;
    return $active->('storage_service') if @{$runtime->{storage_services} || []};
    return $active->('storage_state_unknown') if $runtime->{storage_unknown};
    return $active->('idle_governor_unavailable') if !@{$capability->{policies} || []}
        || grep { !$_->{governors}{$cfg->{idle_governor}} } @{$capability->{policies}};
    return { state => 'IDLE_CANDIDATE', governor => $cfg->{active_governor}, reason => 'waiting_for_idle_confirmation' } if !$runtime->{idle_confirmed};
    return { state => 'IDLE', governor => $cfg->{idle_governor}, reason => 'no_running_guests' };
}
1;
