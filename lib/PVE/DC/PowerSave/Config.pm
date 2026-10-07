package PVE::DC::PowerSave::Config;
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);

my %DEFAULT = (
    enabled => 0,
    active_governor => 'performance',
    idle_governor => 'powersave',
    migration_governor => 'performance',
    failsafe_governor => 'performance',
    reconciliation_interval => 30,
    event_poll_interval => 2,
    idle_candidate_delay => 5,
    boot_protection_period => 120,
);
my @KEYS = qw(enabled active_governor idle_governor migration_governor failsafe_governor reconciliation_interval event_poll_interval idle_candidate_delay boot_protection_period);

sub path { return '/etc/pve/dc-powersave.cfg' }
sub defaults { return { %DEFAULT } }
## no critic (Subroutines::ProhibitBuiltinHomonyms)
# Public API retained for compatibility with callers that use Config->keys.
sub keys { return @KEYS }
## use critic

sub parse {
    my ($class, $raw) = @_;
    my %cfg = %DEFAULT;
    for my $line (split /\n/, $raw) {
        $line =~ s/#.*$//;
        next if $line =~ /^\s*$/;
        $line =~ /^\s*([a-z_]+)\s*:\s*(.*?)\s*$/ or die "invalid configuration line: $line\n";
        my ($key, $value) = ($1, $2);
        exists $DEFAULT{$key} or die "unknown setting: $key\n";
        $cfg{$key} = $value;
    }
    $class->validate(\%cfg);
    return \%cfg;
}

sub validate {
    my ($class, $cfg) = @_;
    for my $key (@KEYS) { exists $cfg->{$key} or die "missing setting: $key\n"; }
    $cfg->{enabled} =~ /^(?:0|1)$/ or die "enabled must be 0 or 1\n";
    for my $key (qw(active_governor idle_governor migration_governor failsafe_governor)) {
        $cfg->{$key} =~ /^[a-zA-Z0-9_.-]+$/ or die "invalid $key\n";
    }
    for my $key (qw(reconciliation_interval event_poll_interval idle_candidate_delay boot_protection_period)) {
        $cfg->{$key} =~ /^\d+$/ or die "invalid $key\n";
    }
    ($cfg->{reconciliation_interval} >= 5 && $cfg->{reconciliation_interval} <= 3600)
        or die "reconciliation_interval must be 5..3600\n";
    ($cfg->{event_poll_interval} >= 1 && $cfg->{event_poll_interval} <= 60)
        or die "event_poll_interval must be 1..60\n";
    $cfg->{idle_candidate_delay} <= 3600 or die "idle_candidate_delay must be 0..3600\n";
    $cfg->{boot_protection_period} <= 86400 or die "boot_protection_period must be 0..86400\n";
    return $cfg;
}

sub load {
    my ($class, $path) = @_;
    $path //= path();
    return $class->defaults if !-e $path;
    open(my $fh, '<', $path) or die "cannot read $path: $!\n";
    local $/ = undef;
    my $raw = <$fh>;
    close($fh);
    return $class->parse($raw);
}

sub digest {
    my ($class, $path) = @_;
    $path //= path();
    return sha256_hex('') if !-e $path;
    open(my $fh, '<', $path) or die "cannot read $path: $!\n";
    local $/ = undef;
    my $raw = <$fh>;
    close($fh);
    return sha256_hex($raw);
}

sub save {
    my ($class, $cfg, $path, $expected_digest) = @_;
    $path //= path();
    $class->validate($cfg);
    (defined($expected_digest) && $expected_digest eq $class->digest($path))
        or die "configuration changed; reload before saving\n";
    my $raw = join('', map { "$_: $cfg->{$_}\n" } @KEYS);
    # Replace the file in one step. Truncating in place lets a concurrent
    # reader on any node see an empty file, which parses as the disabled
    # defaults. pmxcfs supports rename within /etc/pve for this purpose.
    my $tmp = "$path.tmp.$$";
    my $written = eval {
        open(my $fh, '>', $tmp) or die "cannot write $tmp: $!\n";
        print {$fh} $raw or die "cannot write $tmp: $!\n";
        close($fh) or die "cannot close $tmp: $!\n";
        rename($tmp, $path) or die "cannot replace $path: $!\n";
        1;
    };
    if (!$written) {
        my $error = $@;
        unlink($tmp);
        die $error;
    }
    return $class->digest($path);
}
1;
