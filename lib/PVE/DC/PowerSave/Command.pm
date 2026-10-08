package PVE::DC::PowerSave::Command;
use strict;
use warnings;
use IO::Select;
use IPC::Open3 qw(open3);
use POSIX qw(WNOHANG);
use Symbol qw(gensym);
use Time::HiRes qw(time sleep);

# Run a command without a shell and return (exit_ok, stdout, stderr). A
# start failure or timeout returns (0, '', message). Both pipes are drained
# together: reading one to EOF first deadlocks once the child fills the
# other pipe's buffer (64 KiB on Linux).
sub run {
    my ($cmd, $timeout, $label) = @_;
    $label //= $cmd->[0];
    my %output = (stdout => '', stderr => '');
    my ($pid, $status);
    my $ok = eval {
        my $err = gensym;
        $pid = open3(my $in, my $out, $err, @$cmd);
        close($in);
        my %stream = (fileno($out) => 'stdout', fileno($err) => 'stderr');
        my $select = IO::Select->new($out, $err);
        my $deadline = time + $timeout;
        while ($select->count) {
            my $left = $deadline - time;
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
        while (waitpid($pid, WNOHANG) == 0) {
            die "$label timed out\n" if time >= $deadline;
            sleep(0.01);
        }
        $status = $?;
        $pid = undef;
        1;
    };
    if (!$ok) {
        my $error = $@ || "$label failed";
        if ($pid) { kill('TERM', $pid); waitpid($pid, 0); }
        return (0, '', $error);
    }
    return ($status == 0, $output{stdout}, $output{stderr});
}
1;
