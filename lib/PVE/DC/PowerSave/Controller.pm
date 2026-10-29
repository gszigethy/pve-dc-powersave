package PVE::DC::PowerSave::Controller;
use strict;
use warnings;
use Fcntl qw(:flock O_WRONLY O_CREAT O_NOFOLLOW);
use JSON::PP qw(encode_json decode_json);
use POSIX qw(uname);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC sleep);
use PVE::DC::PowerSave::Config;
use PVE::DC::PowerSave::DesiredState;

sub _read_line {
    my ($path) = @_;
    open(my $fh, '<', $path) or return;
    my $line = <$fh>; close($fh);
    chomp($line) if defined($line);
    return $line;
}

sub _all_policies_on {
    my ($cap, $governor) = @_;
    my @policies = @{$cap->{policies} || []};
    return $cap->{valid} && @policies && !grep { ($_->{current} // '') ne $governor } @policies;
}

# Intervals and deadlines use the monotonic clock, which a clock step (NTP
# or chrony correcting the time at boot) cannot shorten or stretch. Status
# timestamps stay in epoch seconds.
sub _monotonic { return clock_gettime(CLOCK_MONOTONIC); }

# Options besides the collaborators and paths:
#   clock    sub returning monotonic seconds (tests inject their own)
#   sleeper  sub that waits the given seconds
#   started  monotonic time that boot protection counts from
#   once     one-shot diagnostic run (see reconcile_once)
# The daemon counts boot protection from its own start. A one-shot run is a
# new process every time, so it counts from system boot instead: on Linux
# the monotonic clock starts at boot.
sub new {
    my ($class, %args) = @_;
    my $clock = $args{clock} || \&_monotonic;
    return bless {
        config_path => $args{config_path}, collector => $args{collector},
        backend => $args{backend}, observer => $args{observer}, idle_seen_at => undef,
        started => $args{started} // ($args{once} ? 0 : $clock->()),
        clock => $clock, sleeper => $args{sleeper} || sub { sleep($_[0]) }, once => $args{once},
        previous => {}, managed => 0, verbose => $args{verbose}, status_path => $args{status_path} || '/run/pve-dc-powersave/status.json',
        lock_path => $args{lock_path} || '/run/pve-dc-powersave/controller.lock',
        request_path => $args{request_path} || '/run/pve-dc-powersave/reconcile.request',
        logged_warnings => '',
    }, $class;
}

sub _open_lock {
    my ($self) = @_;
    my $path = $self->{lock_path};
    my $dir = $path; $dir =~ s|/[^/]+$||;
    mkdir($dir, 0755) if !-d $dir;
    # Only the service user may be able to create the lock. In a shared,
    # world-writable directory such as /run/lock any local user can create
    # and hold it first, and every reconciliation would then be skipped.
    my @dir_stat = lstat($dir) or die "lock: cannot stat $dir: $!\n";
    die "lock: $dir must be a directory owned by uid $> and not writable by others\n"
        if !-d _ || $dir_stat[4] != $> || ($dir_stat[2] & oct('022'));
    sysopen(my $lock, $path, O_WRONLY | O_CREAT | O_NOFOLLOW, oct('0600'))
        or die "lock: cannot open $path: $!\n";
    return $lock;
}

sub _publish {
    my ($self, $status) = @_;
    my $path = $self->{status_path};
    my $dir = $path; $dir =~ s|/[^/]+$||;
    mkdir($dir, 0755) if !-d $dir;
    my $tmp = "$path.$$";
    my $written = eval {
        open(my $fh, '>', $tmp) or die "cannot write status: $!\n";
        print {$fh} encode_json($status) or die "cannot write status: $!\n";
        close($fh) or die "cannot close status: $!\n";
        rename($tmp, $path) or die "cannot publish status: $!\n";
        1;
    };
    if (!$written) {
        my $error = $@;
        unlink($tmp);
        die $error;
    }
    return;
}

sub _log_change {
    my ($self, $status) = @_;
    my $old = $self->{previous};
    if ($self->{verbose} || join('|', map { $old->{$_} // '' } qw(state reason desired_governor last_error))
        ne join('|', map { $status->{$_} // '' } qw(state reason desired_governor last_error))) {
        warn "dc-powersave: state=$status->{state} desired=".($status->{desired_governor} // '-')
            ." reason=$status->{reason} guests=".($status->{running_vm_count} || 0)
            ."/".($status->{running_ct_count} || 0)
            .($status->{last_error} ? " error=$status->{last_error}" : '')."\n";
    }
    $self->{previous} = $status;
    return;
}

# Log configuration warnings (unknown settings, lines ignored while disabled)
# when they change, not on every reconciliation.
sub _log_warnings {
    my ($self, $warnings) = @_;
    my $joined = join("\n", @$warnings);
    return if $joined eq $self->{logged_warnings};
    $self->{logged_warnings} = $joined;
    warn "dc-powersave: configuration warning: $_\n" for @$warnings;
    return;
}

# Read the status the daemon last published, for a one-shot run. Returns the
# status (without its state when it is too old to trust) and whether it
# shows a fresh IDLE. Fresh means written within the staleness threshold the
# Nodes API applies to a status, max(2 * reconciliation_interval + 15, 120).
sub _published_status {
    my ($self, $cfg, $epoch) = @_;
    my $status = eval {
        open(my $fh, '<', $self->{status_path}) or die "no status\n";
        local $/ = undef;
        my $raw = <$fh>;
        close($fh);
        decode_json($raw);
    };
    return ({}, 0) if ref($status) ne 'HASH' || ($status->{node} // '') ne ($self->{collector}->{node} // '');
    my $stale_after = 2 * $cfg->{reconciliation_interval} + 15;
    $stale_after = 120 if $stale_after < 120;
    my $age = $epoch - ($status->{last_reconciliation} || 0);
    my $fresh = $age >= 0 && $age <= $stale_after;
    my $idle = $fresh && ($status->{state} // '') eq 'IDLE';
    delete $status->{state} if !$fresh;
    return ($status, $idle);
}

sub _apply_governor {
    my ($self, $governor) = @_;
    my ($verified) = $self->{backend}->verify_governor($governor);
    return (1, undef, 0) if $verified;
    my ($set_ok, undef, $set_error) = $self->{backend}->set_governor($governor);
    my ($read_ok, $read_error) = $self->{backend}->verify_governor($governor);
    return (1, undef, 1) if $set_ok && $read_ok;
    return (0, $set_error || $read_error || 'governor verification failed', 0);
}

# Returns the published status, or undef (without reconciling) when another
# reconciliation holds the lock. The undef is how callers tell "busy" from a
# completed run; a reconciliation that dies throws instead.
sub reconcile {
    my ($self) = @_;
    my $lock = $self->_open_lock;
    return if !flock($lock, LOCK_EX | LOCK_NB);
    my $now = $self->{clock}->();
    my $epoch = int(time);
    my $config_path = $self->{config_path} // PVE::DC::PowerSave::Config::path();
    my $report = PVE::DC::PowerSave::Config->load_report($config_path);
    my $cfg = $report->{cfg};
    $self->{idle_delay} = $cfg->{idle_candidate_delay};
    my $config_error;
    my @config_problems = map { my $text = $_; $text =~ s/\s+$//; $text } @{$report->{errors}};
    my @warnings = map { my $text = $_; $text =~ s/\s+$//; $text } @{$report->{warnings}};
    # Remember whether the last readable shared configuration enabled
    # management. A later missing file (deleted, or pmxcfs unavailable) must
    # stay an error rather than decay into the unmanaged defaults.
    if (!$report->{exists}) {
        $config_error = 'shared configuration disappeared' if $self->{managed};
    } else {
        $self->{managed} = $report->{enabled} ? 1 : 0 if defined $report->{enabled};
        if (@config_problems && defined($report->{enabled}) && !$report->{enabled}) {
            # A valid enabled: 0 stands. The other lines stay visible.
            push @warnings, map { "ignored while management is disabled: $_" } @config_problems;
        } elsif (@config_problems) {
            $config_error = join('; ', @config_problems);
        }
    }
    $self->_log_warnings(\@warnings);
    my $prior_idle = 0;
    if ($self->{once} && !$self->{seeded}++) {
        # A one-shot run is a new process. Start from what the daemon last
        # published instead of from nothing.
        ($self->{previous}, $prior_idle) = $self->_published_status($cfg, $epoch);
    }
    my $cap = $self->{backend}->discover;
    my $runtime = $self->{collector}->collect($now - $self->{started} < $cfg->{boot_protection_period});
    my $previous = $self->{previous};
    my $pve_version = eval { require PVE::pvecfg; PVE::pvecfg::version_info()->{version} };
    my $status = {
        node => $self->{collector}->{node}, enabled => $cfg->{enabled},
        reconciliation_interval => $cfg->{reconciliation_interval},
        last_reconciliation => $epoch,
        last_successful_reconciliation => $previous->{last_successful_reconciliation},
        last_governor_change => $previous->{last_governor_change},
        state => 'ACTIVE', reason => '', desired_governor => $cfg->{active_governor},
        running_vm_count => $runtime->{running_vm_count} || 0,
        running_ct_count => $runtime->{running_ct_count} || 0,
        protected => $runtime->{protected} ? 1 : 0,
        protection_reason => $runtime->{protection_reason},
        storage_services => $runtime->{storage_services} || [],
        storage_error => $runtime->{storage_error},
        task_state_detail => $runtime->{task_state_detail} || [],
        node_available => $runtime->{node_available} ? 1 : 0,
        configuration_warnings => \@warnings,
        prerequisites => {
            cpupower_installed => -x $self->{backend}->{cpupower} ? 1 : 0,
            cpupower_version => $cap->{cpupower_version},
            cpu_policies => $cap->{policies} || [],
            available_governors => [sort keys %{$cap->{governors} || {}}],
            kernel_version => (uname())[2],
            architecture => (uname())[4],
            debian_version => _read_line('/etc/debian_version'),
            pve_version => $pve_version,
        },
    };

    if (!$cfg->{enabled} && !$config_error) {
        $status->{state} = 'DISABLED'; $status->{reason} = 'management_disabled';
        $status->{desired_governor} = undef;
        $status->{actual_governors} = [map { $_->{current} } @{$cap->{policies} || []}];
        $self->{idle_seen_at} = undef;
        $self->_publish($status); $self->_log_change($status);
        close($lock); return $status;
    }

    if ($runtime->{known} && $runtime->{tasks_known} && !$runtime->{protected}
        && !PVE::DC::PowerSave::DesiredState->storage_blocks_idle($runtime)
        && !$runtime->{running_guests} && !$runtime->{boot_protected} && !$config_error) {
        # A fresh IDLE from the daemon counts as an already served delay for a
        # one-shot run, which can not wait for it without flipping the node.
        $self->{idle_seen_at} //= $prior_idle ? $now - $cfg->{idle_candidate_delay} : $now;
        if ($now - $self->{idle_seen_at} >= $cfg->{idle_candidate_delay}) {
            if (($previous->{state} // '') eq 'IDLE' && _all_policies_on($cap, $cfg->{idle_governor})) {
                # Already idle with the idle governor applied: no transition
                # follows, so the complete snapshot above is enough.
                $runtime->{idle_confirmed} = 1;
            } else {
                # Re-read authoritative local guest state and cluster tasks
                # just before the only transition that can reduce performance.
                $runtime = $self->{collector}->collect(0);
                $runtime->{idle_confirmed} = $runtime->{known} && $runtime->{tasks_known}
                    && !PVE::DC::PowerSave::DesiredState->storage_blocks_idle($runtime)
                    && !$runtime->{protected} && !$runtime->{running_guests};
                # New work seen by the confirmation restarts the delay.
                $self->{idle_seen_at} = undef if !$runtime->{idle_confirmed};
            }
        }
    } else { $self->{idle_seen_at} = undef; }

    my $desired = PVE::DC::PowerSave::DesiredState->decide(undef, $cfg, $runtime, $cap);
    $desired = { state => 'ACTIVE', governor => $cfg->{failsafe_governor}, reason => 'invalid_configuration' } if $config_error;
    $status->{state} = $desired->{state};
    $status->{reason} = $desired->{reason};
    $status->{desired_governor} = $desired->{governor};
    $status->{protected} = $runtime->{protected} ? 1 : 0;
    $status->{protection_reason} = $runtime->{protection_reason};
    @{$status}{qw(storage_services storage_error task_state_detail)} =
        ($runtime->{storage_services} || [], $runtime->{storage_error}, $runtime->{task_state_detail} || []);
    $status->{running_vm_count} = $runtime->{running_vm_count} || 0;
    $status->{running_ct_count} = $runtime->{running_ct_count} || 0;
    # Collect every distinct problem; a later one must not hide an earlier one.
    my @errors;
    my $add_error = sub {
        my ($text) = @_;
        return if !defined $text;
        $text =~ s/\s+$//;
        push @errors, $text if length($text) && !grep { $_ eq $text } @errors;
        return;
    };
    $add_error->($config_error);
    $add_error->($runtime->{error});
    $add_error->($cap->{error});
    $add_error->('idle governor unavailable on one or more CPU policies')
        if $desired->{reason} eq 'idle_governor_unavailable';
    my $governor = $desired->{governor};
    my $failsafe = $cfg->{failsafe_governor};

    if (!$cap->{valid}) {
        $add_error->('CPU governor management unavailable') if !$cap->{error};
    } elsif (!$self->{backend}->supports_all($cap, $governor)) {
        $add_error->("$governor is unavailable on a CPU policy"
            . ($governor eq $failsafe ? ' (it is also the failsafe governor)' : ''));
        $add_error->("failsafe governor $failsafe is unavailable on a CPU policy")
            if $governor ne $failsafe && !$self->{backend}->supports_all($cap, $failsafe);
        $governor = $failsafe;
        $status->{desired_governor} = $governor;
        $status->{state} = 'ERROR';
        $status->{reason} = 'configured_governor_unavailable';
    }
    if ($cap->{valid} && $self->{backend}->supports_all($cap, $governor)) {
        my ($verified, $apply_error, $changed) = $self->_apply_governor($governor);
        $status->{last_governor_change} = int(time) if $changed;
        if (!$verified) {
            $add_error->($apply_error);
            if ($governor ne $failsafe && $self->{backend}->supports_all($cap, $failsafe)) {
                # The requested governor could not be applied: fall back, and
                # verify the fallback the same way. The status names the
                # governor that is now requested.
                my ($safe, $safe_error, $safe_changed) = $self->_apply_governor($failsafe);
                $status->{last_governor_change} = int(time) if $safe_changed;
                $status->{desired_governor} = $failsafe;
                $status->{reason} = 'governor_verification_failed';
                $add_error->("failsafe governor $failsafe could not be applied: $safe_error") if !$safe;
            } elsif ($governor ne $failsafe) {
                $add_error->("failsafe governor $failsafe is unavailable on a CPU policy");
            }
        }
    }
    if (@errors) {
        $status->{state} = 'ERROR';
        $status->{last_error} = substr(join('; ', @errors), 0, 2048);
    }
    else { $status->{last_successful_reconciliation} = int(time); }
    my $actual = $self->{backend}->discover;
    $status->{actual_governors} = [map { $_->{current} } @{$actual->{policies} || []}];
    $status->{prerequisites}->{cpu_policies} = [map {
        my %policy = %$_;
        $policy{requested_governor} = $status->{desired_governor};
        \%policy;
    } @{$actual->{policies} || []}];
    $self->_publish($status); $self->_log_change($status);
    close($lock); return $status;
}

# One-shot run for diagnostics (pve-dc-powersave --once). It reports the
# state the daemon would reach and must not disturb a node the daemon has
# already settled: boot protection counts from system boot, and a fresh IDLE
# status from the daemon counts as an already served idle delay. If the first
# pass still ends in IDLE_CANDIDATE it waits out the remaining delay and
# reconciles once more on this object. That is the only extra pass.
# Returns the final status, or undef when another reconciliation holds the lock.
sub reconcile_once {
    my ($self) = @_;
    my $status = $self->reconcile;
    return if !$status;
    if (($status->{state} // '') eq 'IDLE_CANDIDATE' && defined $self->{idle_seen_at}) {
        my $wait = $self->{idle_seen_at} + $self->{idle_delay} - $self->{clock}->();
        $self->{sleeper}->($wait) if $wait > 0;
        $status = $self->reconcile;
    }
    return $status;
}

# One iteration of the daemon loop. $loop holds what survives between
# iterations. A trigger (a changed task fingerprint, a changed configuration
# digest, a reconcile request, a due idle delay, or the safety timer) counts
# as handled only once a reconciliation completed. While the lock is held by
# someone else or a reconciliation dies, the trigger stays pending and is
# retried after a backoff that starts at event_poll_interval, doubles, and is
# capped at reconciliation_interval. Returns the seconds to wait.
sub run_step {
    my ($self, $loop) = @_;
    my $cfg = PVE::DC::PowerSave::Config->load_report($self->{config_path})->{cfg};
    my $fingerprint = $self->{observer}->fingerprint;
    my $digest = eval { PVE::DC::PowerSave::Config->digest($self->{config_path}) } || 'config-error';
    my $request = -e $self->{request_path} ? (_read_line($self->{request_path}) // '') : '';
    my $now = $self->{clock}->();
    my $candidate_due = defined($self->{idle_seen_at})
        && ($self->{previous}->{state} // '') eq 'IDLE_CANDIDATE'
        && $now - $self->{idle_seen_at} >= $cfg->{idle_candidate_delay};
    my $triggered = $fingerprint ne ($loop->{fingerprint} // '') || $digest ne ($loop->{digest} // '')
        || $request ne ($loop->{request} // '') || $candidate_due
        || !defined($loop->{last_reconcile}) || $now - $loop->{last_reconcile} >= $cfg->{reconciliation_interval};
    if ($triggered && (!defined $loop->{retry_at} || $now >= $loop->{retry_at})) {
        my $status = eval { $self->reconcile };
        my $failure = $@;
        $now = $self->{clock}->();
        if ($status) {
            @$loop{qw(fingerprint digest request last_reconcile)} = ($fingerprint, $digest, $request, $now);
            delete @$loop{qw(retry_at retry_delay)};
        } else {
            warn "dc-powersave: reconcile failed: $failure" if $failure;
            warn "dc-powersave: another reconciliation is in progress; retrying\n" if !$failure && $self->{verbose};
            my $delay = $loop->{retry_delay} ? $loop->{retry_delay} * 2 : $cfg->{event_poll_interval};
            $delay = $cfg->{reconciliation_interval} if $delay > $cfg->{reconciliation_interval};
            @$loop{qw(retry_delay retry_at)} = ($delay, $now + $delay);
        }
    }
    return $cfg->{event_poll_interval};
}

sub run {
    my ($self) = @_;
    my $loop = {};
    while (1) {
        my $wait = $self->run_step($loop);
        $self->{sleeper}->($wait);
    }
    return;
}
1;
