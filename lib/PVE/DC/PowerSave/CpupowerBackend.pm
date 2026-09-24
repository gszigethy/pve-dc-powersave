package PVE::DC::PowerSave::CpupowerBackend;
use strict;
use warnings;
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
sub new { bless { cpupower => $_[1] || '/usr/bin/cpupower' }, $_[0] }
sub _read { my ($path) = @_; open(my $fh, '<', $path) or return undef; my $v = <$fh>; close($fh); chomp($v //= ''); return $v; }
sub _run {
    my ($self, @cmd) = @_;
    my ($stdout, $stderr, $status, $pid);
    my $ok = eval {
        local $SIG{ALRM} = sub { die "cpupower timed out\n" };
        alarm 10;
        my $err = gensym;
        $pid = open3(undef, my $out, $err, @cmd); local $/;
        $stdout = <$out> // ''; $stderr = <$err> // '';
        waitpid($pid, 0); $pid = undef; $status = $?;
        alarm 0; 1;
    };
    alarm 0;
    if (!$ok && $pid) { kill 'TERM', $pid; waitpid($pid, 0); }
    return (0, '', $@ || 'cpupower failed') if !$ok;
    return ($status == 0, $stdout, $stderr);
}
sub discover {
    my ($self) = @_;
    return { valid => 0, error => 'cpupower executable missing', governors => {} } if !-x $self->{cpupower};
    my ($functional, $version, $version_error) = $self->_run($self->{cpupower}, '--version');
    return { valid => 0, error => "cpupower is not functional: $version_error", governors => {} } if !$functional;
    my @paths = glob('/sys/devices/system/cpu/cpufreq/policy*');
    return { valid => 0, error => 'no CPU frequency policies', governors => {} } if !@paths;
    my (%governors, @policies);
    for my $path (@paths) {
        my ($available, $current, $driver, $cpus) = map { _read("$path/$_") } qw(scaling_available_governors scaling_governor scaling_driver related_cpus);
        return { valid => 0, error => "unreadable policy $path", governors => {} } if !defined $available || !defined $current || !defined $driver || !defined $cpus;
        my %supported = map { $_ => 1 } grep { length($_) } split(/\s+/, $available);
        if (!@policies) { %governors = %supported; }
        else { delete $governors{$_} for grep { !$supported{$_} } keys %governors; }
        push @policies, { path => $path, current => $current, driver => $driver, cpus => $cpus, governors => \%supported };
    }
    $version ||= $version_error;
    chomp($version);
    return { valid => 1, cpupower_version => $version, governors => \%governors, policies => \@policies };
}
sub supports_all { my ($self, $cap, $governor) = @_; return 0 if !$cap->{valid}; return !grep { !$_->{governors}{$governor} } @{$cap->{policies}}; }
sub set_governor { my ($self, $governor) = @_; return (0, '', 'invalid governor') if $governor !~ /^[A-Za-z0-9_.-]+$/; return $self->_run($self->{cpupower}, '-c', 'all', 'frequency-set', '-g', $governor); }
sub verify_governor {
    my ($self, $governor) = @_; my $cap = $self->discover;
    return (0, $cap->{error}) if !$cap->{valid};
    return (0, "governor $governor unavailable on a policy") if !$self->supports_all($cap, $governor);
    return (0, 'governor readback mismatch') if grep { $_->{current} ne $governor } @{$cap->{policies}};
    return (1, undef);
}
1;
