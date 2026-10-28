use strict;
use warnings;
use Test::More;
use Fcntl qw(:flock);
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json);
use lib 'lib';
use PVE::DC::PowerSave::Config;
use PVE::DC::PowerSave::Controller;

# Injected clocks keep these tests from sleeping. $NOW is the monotonic
# clock the controller sees; the status timestamps stay on the real clock.
my $NOW = 0;
my $clock = sub { return $NOW };

{ package FakeCollector;
  sub new { bless { node => 'pve01', reads => 0, boot => [], state => {}, die => 0 }, shift }
  sub collect {
      my ($self, $boot) = @_; $self->{reads}++; push @{$self->{boot}}, $boot ? 1 : 0;
      die "collector failed\n" if $self->{die};
      return { %{shift @{$self->{sequence}}} } if $self->{sequence} && @{$self->{sequence}};
      return { %{$self->{state}}, boot_protected => $boot ? 1 : 0 };
  }
}
{ package FakeBackend;
  sub new { bless { cpupower => '/fake/cpupower', current => 'performance', changes => [] }, shift }
  sub discover {
      my ($self) = @_;
      return { valid => 1, governors => { performance => 1, powersave => 1 },
               policies => [ { current => $self->{current}, governors => { performance => 1, powersave => 1 } } ] };
  }
  sub supports_all { my ($self, $cap, $gov) = @_; return $cap->{policies}[0]{governors}{$gov}; }
  sub verify_governor { my ($self, $gov) = @_; return ($self->{current} eq $gov, 'readback mismatch'); }
  sub set_governor { my ($self, $gov) = @_; $self->{current} = $gov; push @{$self->{changes}}, $gov; return (1, '', ''); }
}
{ package FakeObserver;
  sub new { bless { value => 'A' }, shift }
  sub fingerprint { return $_[0]{value} }
}

my $dir = tempdir(CLEANUP => 1);
my $config = "$dir/config.cfg";
my $cfg = { %{PVE::DC::PowerSave::Config->defaults}, enabled => 1, idle_candidate_delay => 5, boot_protection_period => 120 };
PVE::DC::PowerSave::Config->save($cfg, $config, PVE::DC::PowerSave::Config->digest($config));
my $idle_state = { known => 1, tasks_known => 1, node_available => 1, running_guests => 0 };
my $n = 0;
my $make = sub {
    my (%opt) = @_;
    my $id = $opt{id} // ++$n;
    my $collector = $opt{collector} // FakeCollector->new;
    $collector->{state} ||= { %$idle_state };
    $collector->{state} = { %$idle_state } if !%{$collector->{state}};
    my $backend = $opt{backend} // FakeBackend->new;
    my $controller = PVE::DC::PowerSave::Controller->new(
        config_path => $config, collector => $collector, backend => $backend,
        observer => $opt{observer}, clock => $clock, sleeper => $opt{sleeper} // sub { die "unexpected sleep\n" },
        lock_path => "$dir/lock$id", status_path => $opt{status_path} // "$dir/status$id.json",
        request_path => "$dir/request$id", once => $opt{once}, started => $opt{started},
    );
    return ($controller, $collector, $backend);
};

# --- Timers use the injected monotonic clock (boot protection, idle delay).
$NOW = 1000;
my ($c, $col, $be) = $make->(started => 1000);
$c->reconcile;
is($col->{boot}[0], 1, 'inside boot protection right after the service started');
$NOW = 1119;
$c->reconcile;
is($col->{boot}[-1], 1, 'still protected one second before boot_protection_period ends');
$NOW = 1120;
$c->reconcile;
is($col->{boot}[-1], 0, 'boot protection ends when the monotonic clock says so');
is($c->reconcile->{state}, 'IDLE_CANDIDATE', 'idle delay starts when the node is first seen empty');
$NOW = 1124;
is($c->reconcile->{state}, 'IDLE_CANDIDATE', 'idle delay still running after 4 s of monotonic time');
$NOW = 1126;
is($c->reconcile->{state}, 'IDLE', 'idle delay is measured with the monotonic clock');

# --- The idle delay restarts when the confirming re-read finds work.
$NOW = 2000;
my $racing = FakeCollector->new;
($c, $col, $be) = $make->(started => 0, collector => $racing);
is($c->reconcile->{state}, 'IDLE_CANDIDATE', 'empty node waits for the delay');
$NOW = 2006;
$racing->{sequence} = [ { %$idle_state }, { %$idle_state, running_guests => 1 } ];
is($c->reconcile->{state}, 'ACTIVE', 'work seen by the confirming re-read cancels the transition');
$NOW = 2007;
is($c->reconcile->{state}, 'IDLE_CANDIDATE', 'after a short task the idle delay starts again');
is($be->{current}, 'performance', 'the node is not moved to the idle governor early');
$NOW = 2013;
is($c->reconcile->{state}, 'IDLE', 'the node goes idle only after a full delay');

# --- Triggers stay pending until a reconciliation completed.
{
    $NOW = 100;
    my $observer = FakeObserver->new;
    my ($rc, $rcol) = $make->(started => 0, observer => $observer);
    my $loop = {};
    is($rc->run_step($loop), 2, 'a step returns event_poll_interval to wait');
    is($rcol->{reads}, 1, 'first step reconciles');
    $NOW = 101;
    $rc->run_step($loop);
    is($rcol->{reads}, 1, 'nothing changed: no reconciliation');

    open(my $holder, '>>', "$dir/lock$n") or die "lock: $!";
    flock($holder, LOCK_EX | LOCK_NB) or die "flock: $!";
    $observer->{value} = 'B';
    $NOW = 102;
    $rc->run_step($loop);
    is($rcol->{reads}, 1, 'busy lock: reconciliation did not run');
    is($loop->{retry_delay}, 2, 'retry starts at event_poll_interval');
    $NOW = 103;
    $rc->run_step($loop);
    is($rcol->{reads}, 1, 'retry is not attempted before the backoff ends');
    close($holder);
    $NOW = 104;
    $rc->run_step($loop);
    is($rcol->{reads}, 2, 'the change is handled once the lock is free');
    is($loop->{fingerprint}, 'B', 'a completed reconciliation marks the trigger as handled');
    ok(!defined $loop->{retry_at}, 'the backoff is cleared after success');
    $NOW = 105;
    $rc->run_step($loop);
    is($rcol->{reads}, 2, 'a handled trigger is not repeated');

    # A reconciliation that dies keeps the trigger pending too, and the
    # backoff grows to a cap instead of becoming a tight loop.
    $rcol->{die} = 1;
    $observer->{value} = 'C';
    my @delays;
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    for (1 .. 7) {
        $NOW = $loop->{retry_at} if defined $loop->{retry_at};
        $NOW += 1 if !defined $loop->{retry_at};
        $rc->run_step($loop);
        push @delays, $loop->{retry_delay};
    }
    is_deeply(\@delays, [2, 4, 8, 16, 30, 30, 30], 'backoff doubles up to reconciliation_interval and stays there');
    is($loop->{fingerprint}, 'B', 'a reconciliation that died does not mark the trigger as handled');
    like($warnings[0], qr/reconcile failed: collector failed/, 'the failure is logged');
    my $reads = $rcol->{reads};
    $NOW = $loop->{retry_at} - 1;
    $rc->run_step($loop);
    is($rcol->{reads}, $reads, 'no retry before the capped backoff has passed');
    $rcol->{die} = 0;
    $NOW = $loop->{retry_at};
    $rc->run_step($loop);
    is($loop->{fingerprint}, 'C', 'the pending change is handled once reconciliation works again');
    is($rcol->{reads}, $reads + 1, 'exactly one retry succeeded');
}
{
    # The safety timer and a config change are triggers as well.
    $NOW = 500;
    my $busy_col = FakeCollector->new;
    $busy_col->{state} = { %$idle_state, running_guests => 1, running_vm_count => 1 };
    my ($rc, $rcol) = $make->(started => 0, observer => FakeObserver->new, collector => $busy_col);
    my $loop = {};
    $rc->run_step($loop);
    $NOW = 529;
    $rc->run_step($loop);
    is($rcol->{reads}, 1, 'the timer has not fired after 29 s');
    $NOW = 530;
    $rc->run_step($loop);
    is($rcol->{reads}, 2, 'the timer fires after reconciliation_interval');
    $cfg->{idle_candidate_delay} = 6;
    PVE::DC::PowerSave::Config->save($cfg, $config, PVE::DC::PowerSave::Config->digest($config));
    $NOW = 531;
    $rc->run_step($loop);
    is($rcol->{reads}, 3, 'a configuration change triggers a reconciliation');
    open(my $req, '>', "$dir/request$n") or die "request: $!";
    print {$req} "1:1\n";
    close($req);
    $NOW = 532;
    $rc->run_step($loop);
    is($rcol->{reads}, 4, 'a reconcile request triggers a reconciliation');
    $cfg->{idle_candidate_delay} = 5;
    PVE::DC::PowerSave::Config->save($cfg, $config, PVE::DC::PowerSave::Config->digest($config));
    my $slept = 0;
    my ($lc) = $make->(started => 0, observer => FakeObserver->new, collector => $busy_col, sleeper => sub { $slept = $_[0]; die "stop\n" });
    eval { $lc->run };
    is($slept, 2, 'run waits event_poll_interval between steps');
    like($@, qr/^stop/, 'run loops until the sleeper stops it');
}
{
    $NOW = 600;
    my ($rc, $rcol) = $make->(started => 0, observer => FakeObserver->new);
    my $loop = {};
    $rc->run_step($loop);
    $NOW = 601;
    $rc->run_step($loop);
    is($rcol->{reads}, 1, 'steady state');
    # Candidate delay: IDLE_CANDIDATE is followed up without waiting for the timer.
    is($rc->{previous}{state}, 'IDLE_CANDIDATE', 'node waits for the idle delay');
    $NOW = 606;
    $rc->run_step($loop);
    is($rcol->{reads}, 3, 'the due idle delay triggers a reconciliation (with its confirming re-read)');
    is($rc->{previous}{state}, 'IDLE', 'and the node becomes idle');
}

# --- --once leaves the node as the daemon settled it.
{
    # The daemon settles on IDLE.
    $NOW = 10_000;
    my ($daemon, $dcol, $dbe) = $make->(started => 0, id => 'once', status_path => "$dir/shared-status.json");
    $daemon->reconcile;
    $NOW = 10_006;
    is($daemon->reconcile->{state}, 'IDLE', 'daemon reaches IDLE');
    is($dbe->{current}, 'powersave', 'daemon applied the idle governor');
    my $published = decode_json(do { open(my $fh, '<', "$dir/shared-status.json") or die "status: $!"; local $/; <$fh> });

    # Same backend (the node's real governors), new process.
    $NOW = 10_010;
    my ($once, $ocol) = $make->(once => 1, backend => $dbe, status_path => "$dir/shared-status.json");
    @{$dbe->{changes}} = ();
    my $status = $once->reconcile_once;
    is($status->{state}, 'IDLE', '--once keeps a confirmed idle node idle');
    is_deeply($dbe->{changes}, [], '--once changes no governor');
    is($dbe->{current}, 'powersave', 'the idle governor is still applied');
    is($ocol->{reads}, 1, '--once needs a single snapshot for a settled idle node');
    is($status->{last_successful_reconciliation} >= $published->{last_successful_reconciliation} ? 1 : 0, 1,
        'timestamps carry over from the published status');
    is($ocol->{boot}[0], 0, '--once counts boot protection from system boot (uptime 10010 s), not from its own start');

    # Work on the node: the shortcut is never taken.
    $ocol->{state} = { %$idle_state, running_guests => 1, running_vm_count => 1 };
    $NOW = 10_011;
    my ($busy) = $make->(once => 1, backend => $dbe, collector => $ocol, status_path => "$dir/shared-status.json");
    $status = $busy->reconcile_once;
    is($status->{state}, 'ACTIVE', '--once on a node with a running guest reports ACTIVE');
    is($dbe->{current}, 'performance', 'the active governor is applied when the guest is running');

    # A stale published IDLE is not trusted: the delay is served in full.
    $dbe->{current} = 'powersave';
    open(my $fh, '<', "$dir/shared-status.json") or die "status: $!";
    my $raw = do { local $/; <$fh> };
    close($fh);
    my $old = decode_json($raw);
    $old->{state} = 'IDLE';
    $old->{last_reconciliation} = time - 3600;
    open($fh, '>', "$dir/stale-status.json") or die "status: $!";
    print {$fh} JSON::PP::encode_json($old);
    close($fh);
    $NOW = 10_100;
    my $slept = 0;
    my $ccol = FakeCollector->new;
    my ($stale) = $make->(once => 1, backend => $dbe, collector => $ccol, status_path => "$dir/stale-status.json",
        sleeper => sub { $slept = $_[0]; $NOW += $_[0]; });
    @{$dbe->{changes}} = ();
    $status = $stale->reconcile_once;
    is($slept, 5, 'a stale status: --once waits idle_candidate_delay');
    is($status->{state}, 'IDLE', 'and reports the result of the second pass');
    is($ccol->{reads}, 3, 'exactly one extra pass (second pass adds the confirming re-read)');
    is_deeply($dbe->{changes}, ['performance', 'powersave'], 'the first pass is the usual candidate step');

    # No status at all: also a full delay, and never more than two passes.
    unlink("$dir/stale-status.json");
    $NOW = 10_200;
    $slept = 0;
    $ccol = FakeCollector->new;
    $ccol->{sequence} = [ { %$idle_state }, { %$idle_state }, { %$idle_state, running_guests => 1 } ];
    ($stale) = $make->(once => 1, backend => $dbe, collector => $ccol, status_path => "$dir/stale-status.json",
        sleeper => sub { $slept = $_[0]; $NOW += $_[0]; });
    $status = $stale->reconcile_once;
    is($status->{state}, 'ACTIVE', 'work seen by the second pass is reported');
    is($ccol->{reads}, 3, 'never more than one extra pass');

    # Boot protection counts from system boot.
    $NOW = 50;
    my $bcol = FakeCollector->new;
    my ($boot) = $make->(once => 1, collector => $bcol, status_path => "$dir/boot-status.json");
    $status = $boot->reconcile_once;
    is($bcol->{boot}[0], 1, '--once shortly after system boot is inside boot protection');
    is($status->{reason}, 'boot_protection', 'and reports it');

    # A held lock still means "busy".
    open(my $holder, '>>', "$dir/lockbusy") or die "lock: $!";
    flock($holder, LOCK_EX | LOCK_NB) or die "flock: $!";
    my ($held) = $make->(once => 1, id => 'busy', status_path => "$dir/busy-status.json");
    is($held->reconcile_once, undef, '--once reports a busy lock as undef');
    close($holder);
}
done_testing;
