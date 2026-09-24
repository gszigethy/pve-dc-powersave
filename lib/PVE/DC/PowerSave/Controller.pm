package PVE::DC::PowerSave::Controller;
use strict;
use warnings;
use Fcntl qw(:flock);
use JSON::PP qw(encode_json);
use POSIX qw(uname);
use Time::HiRes qw(time sleep);
use PVE::DC::PowerSave::Config;
use PVE::DC::PowerSave::DesiredState;

sub _read_line {
    my ($path) = @_;
    open(my $fh, '<', $path) or return undef;
    my $line = <$fh>; close($fh);
    chomp($line) if defined($line);
    return $line;
}

sub new {
    my ($class, %args) = @_;
    return bless {
        config_path => $args{config_path}, collector => $args{collector},
        backend => $args{backend}, observer => $args{observer}, started => time, idle_seen_at => undef,
        previous => {}, verbose => $args{verbose}, status_path => $args{status_path} || '/run/pve-dc-powersave/status.json',
        lock_path => $args{lock_path} || '/run/lock/pve-dc-powersave.lock',
    }, $class;
}

sub _publish {
    my ($self, $status) = @_;
    my $path = $self->{status_path};
    my $dir = $path; $dir =~ s|/[^/]+$||;
    mkdir($dir, 0755) if !-d $dir;
    my $tmp = "$path.$$";
    open(my $fh, '>', $tmp) or die "cannot write status: $!\n";
    print {$fh} encode_json($status);
    close($fh) or die "cannot close status: $!\n";
    rename($tmp, $path) or die "cannot publish status: $!\n";
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
}

sub reconcile {
    my ($self) = @_;
    open(my $lock, '>>', $self->{lock_path}) or die "lock: $!\n";
    return if !flock($lock, LOCK_EX | LOCK_NB);
    my $now = time;
    my $cfg = eval { PVE::DC::PowerSave::Config->load($self->{config_path}) };
    my $config_error = $@;
    my $config_path = $self->{config_path} // PVE::DC::PowerSave::Config::path();
    $config_error ||= 'shared configuration disappeared' if !-e $config_path && $self->{previous}->{enabled};
    $cfg ||= PVE::DC::PowerSave::Config->defaults;
    my $cap = $self->{backend}->discover;
    my $runtime = $self->{collector}->collect($now - $self->{started} < $cfg->{boot_protection_period});
    my $previous = $self->{previous};
    my $pve_version = eval { require PVE::pvecfg; PVE::pvecfg::version_info()->{version} };
    my $status = {
        node => $self->{collector}->{node}, enabled => $cfg->{enabled},
        reconciliation_interval => $cfg->{reconciliation_interval},
        last_reconciliation => int($now),
        last_successful_reconciliation => $previous->{last_successful_reconciliation},
        last_governor_change => $previous->{last_governor_change},
        state => 'ACTIVE', reason => '', desired_governor => $cfg->{active_governor},
        running_vm_count => $runtime->{running_vm_count} || 0,
        running_ct_count => $runtime->{running_ct_count} || 0,
        protected => $runtime->{protected} ? 1 : 0,
        protection_reason => $runtime->{protection_reason},
        node_available => $runtime->{node_available} ? 1 : 0,
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
        && !$runtime->{running_guests} && !$runtime->{boot_protected} && !$config_error) {
        $self->{idle_seen_at} //= $now;
        if ($now - $self->{idle_seen_at} >= $cfg->{idle_candidate_delay}) {
            # Re-read authoritative local guest state and cluster tasks just
            # before the only transition that can reduce performance.
            $runtime = $self->{collector}->collect(0);
            $runtime->{idle_confirmed} = $runtime->{known} && $runtime->{tasks_known}
                && !$runtime->{protected} && !$runtime->{running_guests};
        }
    } else { $self->{idle_seen_at} = undef; }

    my $desired = PVE::DC::PowerSave::DesiredState->decide(undef, $cfg, $runtime, $cap);
    $desired = { state => 'ACTIVE', governor => $cfg->{failsafe_governor}, reason => 'invalid_configuration' } if $config_error;
    $status->{state} = $desired->{state};
    $status->{reason} = $desired->{reason};
    $status->{desired_governor} = $desired->{governor};
    $status->{protected} = $runtime->{protected} ? 1 : 0;
    $status->{protection_reason} = $runtime->{protection_reason};
    $status->{running_vm_count} = $runtime->{running_vm_count} || 0;
    $status->{running_ct_count} = $runtime->{running_ct_count} || 0;
    my $error = $config_error || $runtime->{error} || $cap->{error};
    $error ||= 'idle governor unavailable on one or more CPU policies'
        if $desired->{reason} eq 'idle_governor_unavailable';
    my $governor = $desired->{governor};

    if (!$cap->{valid}) {
        $error ||= 'CPU governor management unavailable';
    } elsif (!$self->{backend}->supports_all($cap, $governor)) {
        $error = "$governor is unavailable on a CPU policy";
        $governor = $cfg->{failsafe_governor};
        $status->{state} = 'ERROR';
        $status->{reason} = 'configured_governor_unavailable';
    }
    if ($cap->{valid} && $self->{backend}->supports_all($cap, $governor)) {
        my ($verified) = $self->{backend}->verify_governor($governor);
        if (!$verified) {
            my ($set_ok, undef, $set_error) = $self->{backend}->set_governor($governor);
            my ($read_ok, $read_error) = $self->{backend}->verify_governor($governor);
            $verified = $set_ok && $read_ok;
            if ($verified) { $status->{last_governor_change} = int(time); }
            else { $error = $set_error || $read_error || 'governor verification failed'; }
        }
        if (!$verified && $governor ne $cfg->{failsafe_governor}
            && $self->{backend}->supports_all($cap, $cfg->{failsafe_governor})) {
            $self->{backend}->set_governor($cfg->{failsafe_governor});
        }
        $error ||= 'governor verification failed' if !$verified;
    } else {
        $error ||= 'failsafe governor is unavailable';
    }
    if ($error) {
        $status->{state} = 'ERROR';
        $status->{last_error} = substr("$error", 0, 2048);
    }
    else { $status->{last_successful_reconciliation} = int(time); }
    my $actual = $self->{backend}->discover;
    $status->{actual_governors} = [map { $_->{current} } @{$actual->{policies} || []}];
    $status->{prerequisites}->{cpu_policies} = [map {
        { %$_, requested_governor => $status->{desired_governor} }
    } @{$actual->{policies} || []}];
    $self->_publish($status); $self->_log_change($status);
    close($lock); return $status;
}

sub run {
    my ($self) = @_;
    my ($last_fingerprint, $last_digest, $last_reconcile, $last_request) = ('', '', 0, '');
    while (1) {
        my $cfg = eval { PVE::DC::PowerSave::Config->load($self->{config_path}) } || PVE::DC::PowerSave::Config->defaults;
        my $fingerprint = $self->{observer}->fingerprint;
        my $digest = eval { PVE::DC::PowerSave::Config->digest($self->{config_path}) } || 'config-error';
        my $request_file = '/run/pve-dc-powersave/reconcile.request';
        my $request = -e $request_file ? (_read_line($request_file) // '') : '';
        my $candidate_due = defined($self->{idle_seen_at})
            && ($self->{previous}->{state} // '') eq 'IDLE_CANDIDATE'
            && time - $self->{idle_seen_at} >= $cfg->{idle_candidate_delay};
        if ($fingerprint ne $last_fingerprint || $digest ne $last_digest || $request ne $last_request || $candidate_due
            || time - $last_reconcile >= $cfg->{reconciliation_interval}) {
            eval { $self->reconcile }; warn "dc-powersave: reconcile failed: $@" if $@;
            ($last_reconcile, $last_fingerprint, $last_digest, $last_request) = (time, $fingerprint, $digest, $request);
        }
        sleep($cfg->{event_poll_interval});
    }
}
1;
