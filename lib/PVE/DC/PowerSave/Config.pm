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

# Check one setting. Returns an error message, or undef when the value is fine.
sub _key_error {
    my ($key, $value) = @_;
    return "missing setting: $key\n" if !defined $value;
    if ($key eq 'enabled') {
        return $value =~ /^(?:0|1)$/ ? undef : "enabled must be 0 or 1\n";
    }
    if ($key =~ /_governor$/) {
        return $value =~ /^[a-zA-Z0-9_.-]+$/ ? undef : "invalid $key\n";
    }
    $value =~ /^\d+$/ or return "invalid $key\n";
    my %range = (
        reconciliation_interval => [5, 3600], event_poll_interval => [1, 60],
        idle_candidate_delay => [0, 3600], boot_protection_period => [0, 86400],
    );
    my ($min, $max) = @{$range{$key}};
    return ($value >= $min && $value <= $max) ? undef : "$key must be $min..$max\n";
}

# Parse the file text without dying. Returns a hash:
#   cfg      all settings; a missing or invalid one takes its default
#   enabled  0 or 1 when the file has a valid enabled line, otherwise undef
#   errors   problems that make the file unusable (messages end in "\n")
#   warnings unknown settings, which are ignored
# A file without an enabled line is an error, not "disabled": an empty or
# truncated file must not switch management off on every node.
sub parse_report {
    my ($class, $raw) = @_;
    my (%seen, @errors, @warnings);
    for my $line (split /\n/, $raw // '') {
        my $text = $line;
        $text =~ s/#.*$//;
        next if $text =~ /^\s*$/;
        if ($text !~ /^\s*([A-Za-z0-9_.-]+)\s*:\s*(.*?)\s*$/) {
            $line =~ s/^\s+|\s+$//g;
            push @errors, 'invalid configuration line: ' . substr($line, 0, 80) . "\n";
            next;
        }
        my ($key, $value) = ($1, $2);
        if (!exists $DEFAULT{$key}) {
            push @warnings, "unknown setting ignored: $key\n";
            next;
        }
        $seen{$key} = $value;
    }
    my %cfg = %DEFAULT;
    my $enabled;
    for my $key (@KEYS) {
        if (!exists $seen{$key}) {
            push @errors, "missing setting: enabled\n" if $key eq 'enabled';
            next;
        }
        my $error = _key_error($key, $seen{$key});
        if ($error) { push @errors, $error; next; }
        $cfg{$key} = $seen{$key};
        $enabled = $seen{$key} if $key eq 'enabled';
    }
    return { cfg => \%cfg, enabled => $enabled, errors => \@errors, warnings => \@warnings };
}

# Read and parse a file without dying. A missing file is the unmanaged
# defaults; an unreadable one is an error. The result has the keys of
# parse_report plus exists (whether the file is there).
sub load_report {
    my ($class, $path) = @_;
    $path //= path();
    if (!-e $path) {
        return { cfg => $class->defaults, enabled => 0, errors => [], warnings => [], exists => 0 };
    }
    my $raw = eval { _slurp($path) };
    if (!defined $raw) {
        my $error = $@ || "cannot read $path\n";
        return { cfg => $class->defaults, enabled => undef, errors => [$error], warnings => [], exists => 1 };
    }
    my $report = $class->parse_report($raw);
    $report->{exists} = 1;
    return $report;
}

# Strict parse: dies with the first problem and returns only the settings.
# Unknown settings are ignored; parse_report lists them as warnings.
sub parse {
    my ($class, $raw) = @_;
    my $report = $class->parse_report($raw);
    die $report->{errors}[0] if @{$report->{errors}};
    return $report->{cfg};
}

sub validate {
    my ($class, $cfg) = @_;
    for my $key (@KEYS) { exists $cfg->{$key} or die "missing setting: $key\n"; }
    for my $key (@KEYS) {
        my $error = _key_error($key, $cfg->{$key});
        die $error if $error;
    }
    return $cfg;
}

sub _slurp {
    my ($path) = @_;
    open(my $fh, '<', $path) or die "cannot read $path: $!\n";
    local $/ = undef;
    my $raw = <$fh>;
    close($fh);
    return $raw;
}

# The lines of the current file that name a setting this version does not
# know, verbatim and in order. save() carries them over so a node running an
# older version does not erase settings a newer node wrote.
sub _unknown_lines {
    my ($path) = @_;
    return () if !-e $path;
    my $raw = eval { _slurp($path) };
    return () if !defined $raw;
    my @lines;
    for my $line (split /\n/, $raw) {
        (my $text = $line) =~ s/#.*$//;
        next if $text !~ /^\s*([A-Za-z0-9_.-]+)\s*:/;
        next if exists $DEFAULT{$1};
        $line =~ s/\s+$//;
        push @lines, $line;
    }
    return @lines;
}

sub load {
    my ($class, $path) = @_;
    $path //= path();
    return $class->defaults if !-e $path;
    return $class->parse(_slurp($path));
}

sub digest {
    my ($class, $path) = @_;
    $path //= path();
    return sha256_hex('') if !-e $path;
    return sha256_hex(_slurp($path));
}

sub save {
    my ($class, $cfg, $path, $expected_digest) = @_;
    $path //= path();
    $class->validate($cfg);
    (defined($expected_digest) && $expected_digest eq $class->digest($path))
        or die "configuration changed; reload before saving\n";
    my $raw = join('', map { "$_: $cfg->{$_}\n" } @KEYS);
    $raw .= "$_\n" for _unknown_lines($path);
    # Replace the file in one step. Truncating in place lets a concurrent
    # reader on any node see an empty file, which is a configuration error
    # on every node. pmxcfs supports rename within /etc/pve for this purpose.
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
