package PVETestStubs;
# Minimal stand-ins for the Proxmox modules the API2 plugins load, so the
# plugin modules compile and run without a PVE install. Loading this module
# registers the stubs in %INC; require the plugin afterwards.
use strict;
use warnings;

# Every register_method call, keyed by the registering class and method name.
our %methods;
# Set while PVE::Cluster::cfs_lock_file is running its callback.
our $locked = 0;
# check_cfs_quorum dies with this message when set.
our $quorum_error;
# Names of the cfs locks taken, in order.
our @lock_names;

sub method {
    my ($class, $name) = @_;
    return $methods{$class}{$name};
}

sub reset_state {
    $locked = 0;
    $quorum_error = undef;
    @lock_names = ();
    return;
}

BEGIN {
    package PVE::RESTHandler;
    sub import { }
    sub register_method {
        my ($class, $method) = @_;
        $PVETestStubs::methods{$class}{$method->{name}} = $method;
        return;
    }
    $INC{'PVE/RESTHandler.pm'} = __FILE__;

    package PVE::JSONSchema;
    sub import {
        my ($class, @names) = @_;
        my $caller = caller;
        no strict 'refs';  ## no critic (TestingAndDebugging::ProhibitNoStrict)
        *{"${caller}::$_"} = \&{"PVE::JSONSchema::$_"} for @names;
        return;
    }
    sub get_standard_option { my ($name) = @_; return { type => 'string', description => $name }; }
    $INC{'PVE/JSONSchema.pm'} = __FILE__;

    package PVE::Cluster;
    sub import { }
    sub check_cfs_quorum {
        die "$PVETestStubs::quorum_error\n" if defined $PVETestStubs::quorum_error;
        return 1;
    }
    # Like the real function: run the callback under a lock, return its
    # result, and leave the error in $@ instead of dying.
    sub cfs_lock_file {
        my ($name, $timeout, $code, @args) = @_;
        push @PVETestStubs::lock_names, $name;
        local $PVETestStubs::locked = 1;
        my $result = eval { $code->(@args) };
        return $result;
    }
    $INC{'PVE/Cluster.pm'} = __FILE__;
}

1;
