use strict;
use warnings;
use Test::More;

our @registered;
BEGIN {
    package PVE::RESTHandler;
    sub import { }
    sub register_method { my ($class, $method) = @_; push @main::registered, $method; }
    $INC{'PVE/RESTHandler.pm'} = __FILE__;

    package PVE::Cluster;
    sub import { }
    $INC{'PVE/Cluster.pm'} = __FILE__;
}

use lib 'lib';
require PVE::API2::Cluster::DCPowerSave;

my %methods = map { $_->{name} => $_ } @registered;
ok($methods{index}, 'cluster configuration GET route is registered');
ok($methods{update}, 'cluster configuration PUT route is registered');
ok($methods{capabilities}, 'cluster capability route is registered');
is($methods{capabilities}{path}, 'capabilities', 'capability route has the expected path');
is($methods{capabilities}{method}, 'GET', 'capability route is read-only');
is_deeply(
    $methods{capabilities}{permissions}{check},
    ['perm', '/', ['Sys.Audit']],
    'capability discovery requires datacenter audit permission',
);

done_testing;
