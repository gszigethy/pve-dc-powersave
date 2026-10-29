use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use lib 'lib';
use PVE::DC::PowerSave::Config;
use PVE::DC::PowerSave::Controller;

{ package FakeCollector;
  sub new { bless { node => 'pve01', state => {} }, shift }
  sub collect { my ($self) = @_; return { %{$self->{state}} }; }
}
{ package FakeBackend;
  sub new { bless { cpupower => '/fake/cpupower', current => 'performance', fail => {}, calls => [] }, shift }
  sub discover {
      my ($self) = @_;
      return { valid => 0, error => $self->{invalid}, governors => {} } if $self->{invalid};
      return { valid => 1, governors => { performance => 1, powersave => 1 },
               policies => [ { current => $self->{current}, governors => { performance => 1, powersave => 1 } } ] };
  }
  sub supports_all { my ($self, $cap, $gov) = @_; return $cap->{policies}[0]{governors}{$gov}; }
  sub verify_governor { my ($self, $gov) = @_; return ($self->{current} eq $gov, 'readback mismatch'); }
  sub set_governor {
      my ($self, $gov) = @_; push @{$self->{calls}}, $gov;
      return (0, '', "cannot set $gov") if $self->{fail}{$gov};
      $self->{current} = $gov; return (1, '', '');
  }
}

my $dir = tempdir(CLEANUP => 1);
my $config = "$dir/governors.cfg";
my $cfg = { %{PVE::DC::PowerSave::Config->defaults}, enabled => 1, boot_protection_period => 0,
            active_governor => 'ondemand' };
PVE::DC::PowerSave::Config->save($cfg, $config, PVE::DC::PowerSave::Config->digest($config));
my $busy = FakeCollector->new;
$busy->{state} = { known => 1, tasks_known => 1, node_available => 1, running_guests => 1, running_vm_count => 1 };
my $backend = FakeBackend->new;
my $controller = PVE::DC::PowerSave::Controller->new(
    config_path => $config, collector => $busy, backend => $backend,
    lock_path => "$dir/lock", status_path => "$dir/status.json",
);
my $status = $controller->reconcile;
is($status->{reason}, 'configured_governor_unavailable', 'unsupported active governor is reported');
is($status->{desired_governor}, 'performance', 'status shows the failsafe governor actually requested');
is($status->{prerequisites}{cpu_policies}[0]{requested_governor}, 'performance', 'policy detail shows the requested failsafe governor');
is($backend->{current}, 'performance', 'failsafe governor is applied');

$cfg->{failsafe_governor} = 'conservative';
PVE::DC::PowerSave::Config->save($cfg, $config, PVE::DC::PowerSave::Config->digest($config));
$status = $controller->reconcile;
like($status->{last_error}, qr/^ondemand is unavailable.*; failsafe governor conservative is unavailable/,
    'error names both the requested and the unusable failsafe governor');

# Both governors named in the error appear once each.
$cfg = { %{PVE::DC::PowerSave::Config->defaults}, enabled => 1, boot_protection_period => 0,
         active_governor => 'ondemand', failsafe_governor => 'ondemand' };
PVE::DC::PowerSave::Config->save($cfg, $config, PVE::DC::PowerSave::Config->digest($config));
$status = $controller->reconcile;
is(() = $status->{last_error} =~ /ondemand/g, 1, 'a governor that is both requested and failsafe is named once');
like($status->{last_error}, qr/^ondemand is unavailable on a CPU policy/, 'and the error says it is unavailable');

# Earlier configuration, runtime and capability errors are not overwritten.
{
    my $bad_config = "$dir/bad.cfg";
    open(my $fh, '>', $bad_config) or die "write: $!";
    print {$fh} "enabled: 1\nfailsafe_governor: conservative\nboot_protection_period: 0\nnot a setting\n";
    close($fh);
    my $failing = FakeCollector->new;
    $failing->{state} = { known => 0, tasks_known => 0, node_available => 1, error => 'runtime unavailable' };
    my $be = FakeBackend->new;
    my $ctl = PVE::DC::PowerSave::Controller->new(
        config_path => $bad_config, collector => $failing, backend => $be,
        lock_path => "$dir/errors.lock", status_path => "$dir/errors-status.json",
    );
    my $result = $ctl->reconcile;
    is($result->{state}, 'ERROR', 'combined problems are an error');
    like($result->{last_error}, qr/invalid configuration line: not a setting/, 'the configuration problem is kept');
    like($result->{last_error}, qr/runtime unavailable/, 'the runtime problem is kept');
    # failsafe_governor: conservative is valid text but missing on the policy
    # only when the configuration is usable; here the file is invalid, so the
    # defaults apply and performance is requested.
    $be->{invalid} = 'cpupower executable missing';
    $result = $ctl->reconcile;
    like($result->{last_error}, qr/invalid configuration line.*runtime unavailable.*cpupower executable missing/,
        'configuration, runtime and capability errors accumulate in order');
    is(() = $result->{last_error} =~ /cpupower executable missing/g, 1, 'the same message is not repeated');
}
{
    my $ok_config = "$dir/ok.cfg";
    open(my $fh, '>', $ok_config) or die "write: $!";
    print {$fh} "enabled: 1\nactive_governor: ondemand\nfailsafe_governor: conservative\nboot_protection_period: 0\n";
    close($fh);
    my $failing = FakeCollector->new;
    $failing->{state} = { known => 1, tasks_known => 1, node_available => 1, running_guests => 1, error => 'task view unavailable' };
    my $ctl = PVE::DC::PowerSave::Controller->new(
        config_path => $ok_config, collector => $failing, backend => FakeBackend->new,
        lock_path => "$dir/errors2.lock", status_path => "$dir/errors2-status.json",
    );
    like($ctl->reconcile->{last_error}, qr/^task view unavailable; ondemand is unavailable.*; failsafe governor conservative is unavailable/,
        'a runtime error is kept next to the unavailable-governor errors');
}

# The failsafe governor is verified like any other change.
{
    my $idle_config = "$dir/idle.cfg";
    open(my $fh, '>', $idle_config) or die "write: $!";
    print {$fh} "enabled: 1\nidle_candidate_delay: 0\nboot_protection_period: 0\n";
    close($fh);
    my $empty = FakeCollector->new;
    $empty->{state} = { known => 1, tasks_known => 1, node_available => 1, running_guests => 0 };
    my $be = FakeBackend->new;
    $be->{fail}{powersave} = 1;
    my $ctl = PVE::DC::PowerSave::Controller->new(
        config_path => $idle_config, collector => $empty, backend => $be,
        lock_path => "$dir/failsafe.lock", status_path => "$dir/failsafe-status.json",
    );
    my $result = $ctl->reconcile;
    is($result->{state}, 'ERROR', 'a governor that cannot be applied is an error');
    is($result->{desired_governor}, 'performance', 'the status names the failsafe governor that is now requested');
    is($result->{prerequisites}{cpu_policies}[0]{requested_governor}, 'performance', 'policy detail names it too');
    is_deeply($result->{actual_governors}, ['performance'], 'the actual governors are read back');
    is_deeply($be->{calls}, ['powersave'], 'the failsafe governor was already in place: no extra command');
    like($result->{last_error}, qr/cannot set powersave/, 'the original failure is reported');
    unlike($result->{last_error}, qr/failsafe governor performance could not/, 'a failsafe that works adds no error');

    # The node sits on a third governor and neither idle nor failsafe can be set.
    $be = FakeBackend->new;
    $be->{current} = 'schedutil';
    $be->{fail}{powersave} = 1;
    $be->{fail}{performance} = 1;
    $ctl = PVE::DC::PowerSave::Controller->new(
        config_path => $idle_config, collector => $empty, backend => $be,
        lock_path => "$dir/failsafe2.lock", status_path => "$dir/failsafe2-status.json",
    );
    $result = $ctl->reconcile;
    is($result->{desired_governor}, 'performance', 'the failsafe governor is requested');
    is_deeply($result->{actual_governors}, ['schedutil'], 'the status shows what the node really runs');
    like($result->{last_error}, qr/cannot set powersave.*failsafe governor performance could not be applied: cannot set performance/,
        'a failed failsafe adds an error');
    is_deeply($be->{calls}, ['powersave', 'performance'], 'the failsafe governor was tried after the failed one');
}

mkdir("$dir/status-is-a-directory") or die "mkdir: $!";
my $unpublishable = PVE::DC::PowerSave::Controller->new(
    config_path => $config, collector => $busy, backend => $backend,
    lock_path => "$dir/lock", status_path => "$dir/status-is-a-directory",
);
eval { $unpublishable->reconcile };
like($@, qr/cannot publish status/, 'status publication failure is reported');
ok(!-e "$dir/status-is-a-directory.$$", 'failed status publication leaves no temporary file');
done_testing;
