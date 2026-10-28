package PVE::DC::PowerSave::Command;
use strict;
use warnings;
use IO::Select;
use POSIX qw(WNOHANG);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC sleep);

# How long a timed-out command gets to react to SIGTERM, and then to SIGKILL,
# before run() stops waiting for it.
our $TERM_GRACE = 2;
our $KILL_GRACE = 2;

# Children that survived SIGKILL (uninterruptible sleep, for example). They
# are reaped by later calls instead of blocking the caller.
our @UNREAPED;

sub _signal { my ($signal, $target) = @_; return kill($signal, $target); }

sub _now { return clock_gettime(CLOCK_MONOTONIC); }

# Start the command in its own process group, with stdin on /dev/null and
# stdout and stderr on pipes. Returns ($pid, $stdout, $stderr) or dies. The
# group lets a timeout stop the command together with everything it started.
sub _spawn {
    my ($cmd) = @_;
    pipe(my $out_r, my $out_w) or die "pipe: $!\n";
    pipe(my $err_r, my $err_w) or die "pipe: $!\n";
    # Perl marks these close-on-exec, so a successful exec closes the write
    # end and the parent reads end-of-file; a failed exec reports its errno.
    pipe(my $exec_r, my $exec_w) or die "pipe: $!\n";
    my $pid = fork();
    die "fork: $!\n" if !defined $pid;
    if (!$pid) {
        my $failure = sub { syswrite($exec_w, $_[0]); POSIX::_exit(127); };
        POSIX::setpgid(0, 0) or $failure->("cannot create process group: $!");
        open(STDIN, '<', '/dev/null') or $failure->("cannot open /dev/null: $!");
        open(STDOUT, '>&', $out_w) or $failure->("cannot redirect stdout: $!");
        open(STDERR, '>&', $err_w) or $failure->("cannot redirect stderr: $!");
        # A failed exec warns on stderr, which is the pipe; report it instead.
        local $SIG{__WARN__} = sub { };
        exec { $cmd->[0] } @$cmd or $failure->("cannot execute $cmd->[0]: $!");
    }
    close($out_w); close($err_w); close($exec_w);
    # Also set the group from the parent so it exists before the child runs.
    POSIX::setpgid($pid, $pid);
    my $problem = '';
    sysread($exec_r, $problem, 4096);
    close($exec_r);
    if (length $problem) {
        waitpid($pid, 0);
        die "$problem\n";
    }
    return ($pid, $out_r, $err_r);
}

# Reap earlier children that could not be killed. Never blocks.
sub _reap_unreaped {
    @UNREAPED = grep { waitpid($_, WNOHANG) == 0 } @UNREAPED;
    return;
}

# Wait up to $seconds for the leader to exit. With $group set, also wait for
# the rest of its process group. Returns the wait status, or undef if the
# process is still there.
sub _wait_exit {
    my ($pid, $seconds, $reaped) = @_;
    my $end = _now() + $seconds;
    while (1) {
        if (!defined $$reaped) {
            my $got = waitpid($pid, WNOHANG);
            $$reaped = $? if $got == $pid;
            $$reaped = -1 if $got < 0;
        }
        return $$reaped if defined($$reaped) && !kill(0, -$pid);
        return if _now() >= $end;
        sleep(0.01);
    }
    return;
}

# Stop a timed-out command: SIGTERM to the group, a short wait, SIGKILL to the
# group, a short wait. A process that still has not exited (stuck in D state)
# is left for _reap_unreaped; the caller is never blocked on it.
sub _terminate {
    my ($pid, $reaped) = @_;
    _signal('TERM', -$pid);
    _signal('TERM', $pid) if !defined $$reaped;
    return if defined _wait_exit($pid, $TERM_GRACE, $reaped);
    _signal('KILL', -$pid);
    _signal('KILL', $pid) if !defined $$reaped;
    return if defined _wait_exit($pid, $KILL_GRACE, $reaped);
    push @UNREAPED, $pid if !defined $$reaped;
    return;
}

# Run a command without a shell and return (exit_ok, stdout, stderr). A
# start failure or timeout returns (0, '', message). Both pipes are drained
# together: reading one to EOF first deadlocks once the child fills the
# other pipe's buffer (64 KiB on Linux).
#
# The command runs in its own process group. On a timeout the group gets
# SIGTERM, then SIGKILL, so a command that ignores SIGTERM or leaves a child
# holding the pipes cannot block the caller: run() returns within about
# $timeout + 4 seconds. The deadline uses the monotonic clock.
sub run {
    my ($cmd, $timeout, $label) = @_;
    $label //= $cmd->[0];
    _reap_unreaped();
    my %output = (stdout => '', stderr => '');
    my ($pid, $status, $reaped);
    my $ok = eval {
        my ($out, $err);
        ($pid, $out, $err) = _spawn($cmd);
        my %stream = (fileno($out) => 'stdout', fileno($err) => 'stderr');
        my $select = IO::Select->new($out, $err);
        my $deadline = _now() + $timeout;
        while ($select->count) {
            my $left = $deadline - _now();
            die "$label timed out\n" if $left <= 0;
            for my $fh ($select->can_read($left)) {
                my $name = $stream{fileno($fh)};
                my $bytes = sysread($fh, my $chunk, 65536);
                die "$label output unreadable: $!\n" if !defined $bytes;
                if ($bytes) { $output{$name} .= $chunk; next; }
                $select->remove($fh);
                close($fh);
            }
        }
        while (!defined $reaped) {
            my $got = waitpid($pid, WNOHANG);
            if ($got == $pid) { $reaped = $?; }
            elsif ($got < 0) { $reaped = -1; }
            elsif (_now() >= $deadline) { die "$label timed out\n"; }
            else { sleep(0.01); }
        }
        $status = $reaped;
        1;
    };
    if (!$ok) {
        my $error = $@ || "$label failed";
        _terminate($pid, \$reaped) if $pid;
        return (0, '', $error);
    }
    return ($status == 0, $output{stdout}, $output{stderr});
}
1;
