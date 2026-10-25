#!/usr/bin/env perl
# The version files a release writes, read and compared the same way by the
# back-merge (actions/backmerge) and by the pull request check (guard.sh), so
# "a version never goes backwards" means one thing in both.
#
#   files                        stdin paths -> the ones that are version files
#   values   PATH FILE           one "key<TAB>value" line per version key (for
#                                test.sh and for a person debugging)
#   align    PATH BASE OURS THEIRS
#                                rewrite every version key in all three stages
#                                to the higher of ours and theirs, so a
#                                three-way merge of what is left keeps it; exit 1
#                                when two values cannot be compared
#   regress  PATH OLD NEW [MB]   one "PATH: key: old -> new" line per key NEW
#                                has lower than OLD; with MB (the merge base),
#                                only keys NEW changed from MB count
#   max      A B                 the higher of two versions; exit 2 if they
#                                cannot be compared
#   changelog OURS THEIRS        OURS with every release section of THEIRS that
#                                OURS lacks, each placed before the first lower
#                                release; exit 1 when neither has a release
#                                heading to place by
#
# PATH is the file's repository path: its base name says how to read it.
#   package.json, bun.lock       the root "version" (bun.lock: the root
#                                workspace's)
#   package-lock.json            the root "version", on both of its lines
#   version.properties, gradle.properties
#                                version/versionName/VERSION_NAME and
#                                versionCode/VERSION_CODE/buildNumber
#   pubspec.yaml                 version: x.y.z+N (the build number counts)
#   Cargo.toml                   version in [package] or [workspace.package]
#   project.pbxproj              MARKETING_VERSION, CURRENT_PROJECT_VERSION
#                                (every build configuration; the highest is the
#                                file's value)
#
# Versions compare by semver precedence, loosely: missing parts are 0, so "1.2"
# is 1.2.0 and a bare build number "803" is 803.0.0. A pubspec build number
# (+N) breaks a tie. Anything that does not parse compares only as equal.
use strict;
use warnings;

my $NAMES = qr{(?:^|/)(package\.json|package-lock\.json|bun\.lock|version\.properties|gradle\.properties|pubspec\.yaml|Cargo\.toml|project\.pbxproj)$};

# The npm family: where the root version sits in the decoded file, and how many
# leading `"version": "<it>"` lines are the root's (the root lines come first).
my %NPM = (
  'package.json'      => [sub { $_[0]{version} }, 1],
  'package-lock.json' => [sub { $_[0]{version} }, 2],
  'bun.lock'          => [sub { ref $_[0]{workspaces} eq 'HASH' && ref $_[0]{workspaces}{''} eq 'HASH' ? $_[0]{workspaces}{''}{version} : undef }, 1],
);

sub kind { my ($p) = @_; return $p =~ $NAMES ? $1 : ''; }

sub slurp {
  my ($f) = @_;
  open my $fh, '<', $f or die "versions.pl: cannot read $f: $!\n";
  local $/; my $s = <$fh>; close $fh;
  return defined $s ? $s : '';
}

sub spew {
  my ($f, $s) = @_;
  open my $fh, '>', $f or die "versions.pl: cannot write $f: $!\n";
  print $fh $s; close $fh;
}

# --- comparison -------------------------------------------------------------

sub parse {
  my ($v) = @_;
  return undef unless defined $v && $v =~ /^v?(\d+(?:\.\d+)*)(?:-([0-9A-Za-z.-]+))?(?:\+([0-9A-Za-z.-]+))?$/;
  my @n = split /\./, $1;
  push @n, 0 while @n < 3;
  return { n => \@n, pre => $2, build => $3 };
}

sub cmp_pre {
  my ($a, $b) = @_;
  return 0 if !defined $a && !defined $b;
  return 1 if !defined $a;   # a release outranks any prerelease of it
  return -1 if !defined $b;
  my @a = split /\./, $a; my @b = split /\./, $b;
  for my $i (0 .. ($#a < $#b ? $#a : $#b)) {
    my ($x, $y) = ($a[$i], $b[$i]);
    my ($nx, $ny) = ($x =~ /^\d+$/, $y =~ /^\d+$/);
    my $c = $nx && $ny ? $x <=> $y : $nx ? -1 : $ny ? 1 : $x cmp $y;
    return $c if $c;
  }
  return @a <=> @b;
}

# -1, 0 or 1; undef when the two cannot be compared.
sub vcmp {
  my ($a, $b) = @_;
  return 0 if $a eq $b;
  my ($x, $y) = (parse($a), parse($b));
  return undef unless $x && $y;
  my @x = @{ $x->{n} }; my @y = @{ $y->{n} };
  push @x, 0 while @x < @y; push @y, 0 while @y < @x;
  for my $i (0 .. $#x) { my $c = $x[$i] <=> $y[$i]; return $c if $c; }
  my $c = cmp_pre($x->{pre}, $y->{pre});
  return $c if $c;
  my ($bx, $by) = ($x->{build} // '', $y->{build} // '');
  return 0 if $bx eq $by;
  return $bx =~ /^\d+$/ && $by =~ /^\d+$/ ? $bx <=> $by : undef;
}

sub vmax {
  my ($a, $b) = @_;
  return $a unless defined $b && $b ne '';
  return $b unless defined $a && $a ne '';
  my $c = vcmp($a, $b);
  return defined $c ? ($c >= 0 ? $a : $b) : undef;
}

# --- reading and rewriting --------------------------------------------------

# Line rules: [key, regex with the value in $2]. The prefix up to the value is $1,
# so a rewrite keeps spacing and quotes as they were.
my %RULES = (
  'version.properties' => [
    ['version',     qr/^(\s*(?:version|versionName|VERSION_NAME|appVersion)\s*[=:]\s*)([^\s#]+)/],
    ['versionCode', qr/^(\s*(?:versionCode|VERSION_CODE|buildNumber|BUILD_NUMBER)\s*[=:]\s*)(\d+)/],
  ],
  'pubspec.yaml' => [
    ['version', qr/^(version:\s*['"]?)([^\s'"#]+)/],
  ],
  'project.pbxproj' => [
    ['MARKETING_VERSION',       qr/^(\s*MARKETING_VERSION\s*=\s*"?)([^";\s]+)/],
    ['CURRENT_PROJECT_VERSION', qr/^(\s*CURRENT_PROJECT_VERSION\s*=\s*"?)([^";\s]+)/],
  ],
);
$RULES{'gradle.properties'} = $RULES{'version.properties'};

# Each line of a Cargo.toml with the section it sits in, so only the package's
# own version counts, never a dependency table's.
sub cargo_lines {
  my ($s) = @_;
  my ($sec, @out) = ('');
  for my $l (split /^/, $s) {
    $sec = $1 if $l =~ /^\s*\[\s*([^\]]+?)\s*\]\s*$/;
    push @out, [$sec, $l];
  }
  return @out;
}
my $CARGO_VER = qr/^(\s*version\s*=\s*")([^"]+)/;
sub cargo_pkg { return $_[0] eq 'package' || $_[0] eq 'workspace.package'; }

# key -> the file's value for it (the highest where it occurs more than once).
sub values_of {
  my ($path, $s) = @_;
  my $k = kind($path);
  my %v;
  my $add = sub { my ($key, $val) = @_; $v{$key} = exists $v{$key} ? (vmax($v{$key}, $val) // $v{$key}) : $val; };
  if (my $npm = $NPM{$k}) {
    require JSON::PP;   # relaxed: bun.lock has trailing commas
    my $j = eval { JSON::PP->new->relaxed->decode($s) };
    my $r = ref $j eq 'HASH' ? $npm->[0]->($j) : undef;
    $v{version} = $r if defined $r && !ref $r;
  } elsif ($k eq 'Cargo.toml') {
    for (cargo_lines($s)) { my ($sec, $l) = @$_; $add->('version', $2) if cargo_pkg($sec) && $l =~ $CARGO_VER; }
  } elsif (my $rules = $RULES{$k}) {
    for my $l (split /^/, $s) { for (@$rules) { $add->($_->[0], $2) if $l =~ $_->[1]; } }
  }
  return \%v;
}

# $s with key's value $old replaced by $new wherever it stands as that key.
sub set_value {
  my ($path, $s, $key, $old, $new) = @_;
  return $s if $old eq $new;
  my $k = kind($path);
  if (my $npm = $NPM{$k}) {
    my $n = 0;
    $s =~ s/("version"\s*:\s*")\Q$old\E(")/ $n++ < $npm->[1] ? "$1$new$2" : $& /ge;
    return $s;
  }
  if ($k eq 'Cargo.toml') {
    return join '', map { my ($sec, $l) = @$_; $l =~ s/$CARGO_VER/$1$new/ if cargo_pkg($sec) && $l =~ $CARGO_VER && $2 eq $old; $l } cargo_lines($s);
  }
  my ($rule) = grep { $_->[0] eq $key } @{ $RULES{$k} || [] };
  return $s unless $rule;
  my $re = $rule->[1];
  return join '', map { my $l = $_; $l =~ s/$re/$1$new/ if $l =~ $re && $2 eq $old; $l } split /^/, $s;
}

# --- changelogs -------------------------------------------------------------

# A release heading as semantic-release writes it: `# [1.2.0](...)`,
# `## [1.2.1](...) (date)`, `## 1.0.0 (date)`, or a monorepo's `# [name@1.2.0]`.
my $RELEASE = qr/^#{1,2}\s+\[?(?:[\w.\/-]+@)?v?(\d+\.\d+\.\d+[0-9A-Za-z.+-]*)/;

sub sections {
  my ($s) = @_;
  my ($pre, @sec) = ('');
  for my $l (split /^/, $s) {
    if ($l =~ $RELEASE) { push @sec, [$1, $l]; }
    elsif (@sec)        { $sec[-1][1] .= $l; }
    else                { $pre .= $l; }
  }
  return ($pre, @sec);
}

sub ends_blank { my $t = $_[0]; $t .= "\n" unless $t =~ /\n\z/; $t .= "\n" unless $t =~ /\n\n\z/; return $t; }

sub merge_changelog {
  my ($ours, $theirs) = @_;
  my ($pre, @out) = sections($ours);
  my (undef, @add) = sections($theirs);
  return undef unless @out || @add;
  my %have = map { $_->[0] => 1 } @out;
  for my $s (grep { !$have{ $_->[0] } } @add) {
    my $at = scalar @out;
    for my $i (0 .. $#out) { my $c = vcmp($out[$i][0], $s->[0]); if (defined $c && $c < 0) { $at = $i; last; } }
    if ($at < @out) { splice @out, $at, 0, [$s->[0], ends_blank($s->[1])]; next; }
    if (@out) { $out[-1][1] = ends_blank($out[-1][1]); } elsif ($pre ne '') { $pre = ends_blank($pre); }
    push @out, $s;
  }
  return $pre . join '', map { $_->[1] } @out;
}

# --- commands ---------------------------------------------------------------

my $cmd = shift @ARGV // '';
if ($cmd eq 'files') {
  while (my $l = <STDIN>) { chomp $l; print "$l\n" if kind($l); }
} elsif ($cmd eq 'values') {
  my ($path, $f) = @ARGV;
  my $v = values_of($path, slurp($f));
  print "$_\t$v->{$_}\n" for sort keys %$v;
} elsif ($cmd eq 'align') {
  my ($path, @f) = @ARGV;
  my @s = map { slurp($_) } @f;
  my @v = map { values_of($path, $_) } @s;
  my %keys = map { $_ => 1 } map { keys %$_ } @v[1, 2];
  for my $key (sort keys %keys) {
    my $t = vmax($v[1]{$key}, $v[2]{$key});
    exit 1 unless defined $t;
    for my $i (0 .. 2) { $s[$i] = set_value($path, $s[$i], $key, $v[$i]{$key}, $t) if defined $v[$i]{$key}; }
  }
  spew($f[$_], $s[$_]) for 0 .. 2;
} elsif ($cmd eq 'regress') {
  my ($path, $old, $new, $mb) = @ARGV;
  my ($o, $n) = (values_of($path, slurp($old)), values_of($path, slurp($new)));
  my $m = defined $mb ? values_of($path, slurp($mb)) : undef;
  for my $key (sort keys %$n) {
    next unless defined $o->{$key};
    next if $m && defined $m->{$key} && $m->{$key} eq $n->{$key};
    my $c = vcmp($n->{$key}, $o->{$key});
    print "$path: $key: $o->{$key} -> $n->{$key}\n" if defined $c && $c < 0;
  }
} elsif ($cmd eq 'max') {
  my $m = vmax(@ARGV[0, 1]);
  exit 2 unless defined $m;
  print "$m\n";
} elsif ($cmd eq 'changelog') {
  my $m = merge_changelog(slurp($ARGV[0]), slurp($ARGV[1]));
  exit 1 unless defined $m;
  print $m;
} else {
  die "usage: versions.pl files|values|align|regress|max|changelog ...\n";
}
