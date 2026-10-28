use strict;
use warnings;
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json);
use Test::More;
use lib 'lib', 't/lib';
use PVETestStubs;

require PVE::API2::Nodes::DCPowerSave;

my $class = 'PVE::API2::Nodes::DCPowerSave';
my $status = PVETestStubs::method($class, 'status');
my $reconcile = PVETestStubs::method($class, 'reconcile');

ok($status, 'node status route is registered');
ok($reconcile, 'node reconcile route is registered');
is($status->{method}, 'GET', 'status is a read');
is($status->{proxyto}, 'node', 'status is answered by the node itself');
is_deeply($status->{permissions}{check}, ['perm', '/nodes/{node}', ['Sys.Audit']], 'status requires Sys.Audit');
is($reconcile->{method}, 'POST', 'reconcile is a write');
ok($reconcile->{protected}, 'reconcile runs in pvedaemon');
is_deeply($reconcile->{permissions}{check}, ['perm', '/nodes/{node}', ['Sys.Modify']], 'reconcile requires Sys.Modify');

my $root = tempdir(CLEANUP => 1);
my $run = "$root/run";
{
    no warnings 'once';
    $PVE::API2::Nodes::DCPowerSave::RUN_DIR = $run;
}

sub write_status {
    my ($data) = @_;
    mkdir($run) if !-d $run;
    open(my $fh, '>', "$run/status.json") or die $!;
    print {$fh} encode_json($data);
    close($fh);
    return;
}

# ---- status ---------------------------------------------------------------

my $result = $status->{code}->({ node => 'pve01' });
is($result->{state}, 'ERROR', 'a missing status file is an error');
is($result->{reason}, 'service_not_reporting', 'a missing status file means the service is not reporting');
is($result->{node}, 'pve01', 'the answer names the node');

write_status({ node => 'pve01', state => 'IDLE', last_reconciliation => time - 400, reconciliation_interval => 30 });
$result = $status->{code}->({ node => 'pve01' });
is($result->{state}, 'ERROR', 'a stale status is an error');
is($result->{reason}, 'service_status_stale', 'a stale status has its own reason');
like($result->{last_error}, qr/No reconciliation for \d+ seconds/, 'a stale status says how old it is');

write_status({ node => 'pve01', state => 'IDLE', reason => 'idle_verified', last_reconciliation => time - 5, reconciliation_interval => 30 });
$result = $status->{code}->({ node => 'pve01' });
is($result->{state}, 'IDLE', 'a fresh status is passed through');
is($result->{reason}, 'idle_verified', 'a fresh status keeps its reason');

write_status({ state => 'IDLE', last_reconciliation => time - 200, reconciliation_interval => 3600 });
$result = $status->{code}->({ node => 'pve01' });
is($result->{state}, 'IDLE', 'the stale limit follows a long reconciliation interval');

write_status({ state => 'ACTIVE', last_reconciliation => time - 100 });
$result = $status->{code}->({ node => 'pve01' });
is($result->{state}, 'ACTIVE', 'a status younger than the 120 s floor is fresh');

# ---- reconcile ------------------------------------------------------------

unlink("$run/reconcile.request");
my $before = time;
my $return = $reconcile->{code}->({ node => 'pve01' });
ok(-e "$run/reconcile.request", 'reconcile writes the request file');
open(my $fh, '<', "$run/reconcile.request") or die $!;
my $line = <$fh>;
close($fh);
like($line, qr/^\d+(?:\.\d+)?:$$\n$/, 'the request file holds a timestamp and the requesting pid');
cmp_ok((split /:/, $line)[0], '>=', int($before), 'the timestamp is current');
is($return, undef, 'reconcile returns nothing');

my $fresh = "$root/fresh-run";
$PVE::API2::Nodes::DCPowerSave::RUN_DIR = $fresh;
$reconcile->{code}->({ node => 'pve01' });
ok(-e "$fresh/reconcile.request", 'reconcile creates the runtime directory when the service never ran');

done_testing;
