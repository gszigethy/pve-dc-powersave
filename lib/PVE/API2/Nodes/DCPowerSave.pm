package PVE::API2::Nodes::DCPowerSave;
use strict;
use warnings;
use JSON::PP qw(decode_json);
use Time::HiRes qw(time);
use PVE::RESTHandler;
use PVE::JSONSchema qw(get_standard_option);
use base qw(PVE::RESTHandler);

# The controller's runtime directory. Tests point this at a temporary one.
our $RUN_DIR = '/run/pve-dc-powersave';

my $node_property = { node => get_standard_option('pve-node') };

__PACKAGE__->register_method({
    name => 'status', path => '', method => 'GET', proxyto => 'node',
    description => 'Local CPU power management status',
    permissions => { check => ['perm', '/nodes/{node}', ['Sys.Audit']] },
    parameters => { additionalProperties => 0, properties => $node_property },
    returns => { type => 'object', additionalProperties => 1 },
    code => sub {
        my ($param) = @_;
        my $path = "$RUN_DIR/status.json";
        return { node => $param->{node}, state => 'ERROR', reason => 'service_not_reporting' } if !-r $path;
        open(my $fh, '<', $path) or die "cannot read status: $!\n";
        local $/ = undef; my $raw = <$fh>; close($fh);
        my $status = decode_json($raw);
        my $age = int(time - ($status->{last_reconciliation} || 0));
        my $stale_after = 2 * ($status->{reconciliation_interval} || 30) + 15;
        $stale_after = 120 if $stale_after < 120;
        if ($age > $stale_after) {
            $status->{state} = 'ERROR';
            $status->{reason} = 'service_status_stale';
            $status->{last_error} = "No reconciliation for $age seconds";
        }
        return $status;
    },
});

__PACKAGE__->register_method({
    name => 'reconcile', path => 'reconcile', method => 'POST', proxyto => 'node', protected => 1,
    description => 'Schedule a local CPU power management reconciliation',
    permissions => { check => ['perm', '/nodes/{node}', ['Sys.Modify']] },
    parameters => { additionalProperties => 0, properties => $node_property },
    returns => { type => 'null' },
    code => sub {
        mkdir($RUN_DIR, 0755) if !-d $RUN_DIR;
        my $path = "$RUN_DIR/reconcile.request";
        open(my $fh, '>', $path) or die "cannot request reconciliation: $!\n";
        print {$fh} time . ":$$\n";
        close($fh);
        return;
    },
});
1;
