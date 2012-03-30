package cherrymaint;
use Dancer;
use HTML::Entities;
use Socket qw/inet_aton/;
use List::Util qw/min max/;
use Fcntl qw/LOCK_EX LOCK_UN/;

my $BLEADGITHOME = config->{gitroot};
my $TESTING      = config->{testing}; # single-user mode, for testing
my $GIT          = config->{gitpath};
my $DATAFILE     = config->{datafile};
my $LOCK         = config->{lock};
my @BRANCHES     = reverse sort keys %{config->{branches}};

$_ = (glob)[0] for $GIT, $BLEADGITHOME, $DATAFILE, $LOCK;

chdir $BLEADGITHOME or die "Can't chdir to $BLEADGITHOME: $!\n";

sub any_eq {
    my $str = shift;
    $str eq $_ and return 1 for @_;
    0;
}

sub branchname {
    my $b = params->{branch} // $BRANCHES[0];
    return $b if $b ~~ @BRANCHES;
    die "Invalid branch name";
}
sub  startpoint { branchpoint(0) }
sub    endpoint { branchpoint(1) }
sub branchpoint { config->{branches}{branchname()}[$_[0]] }

sub load_datafile {
    my $data = {};
    open my $fh, '<', $DATAFILE or die "Can't open $DATAFILE: $!";
    while (<$fh>) {
        chomp;
        my ($branchstart, $commit, $value, @votes) = split ' ';
        $data->{$commit} = [
            0 + $value,
            [ @votes ],
            $branchstart,
        ];
    }
    close $fh;
    return $data;
}

sub save_datafile {
    my ($data) = @_;
    open my $fh, '>', $DATAFILE or die "Can't open $DATAFILE: $!";
    for my $k (keys %$data) {
        next unless $data->{$k};
        my ($value, $votes, $branchstart) = @{ $data->{$k} };
        my @votes = @{ $votes || [] };
        print $fh "$branchstart $k $value @votes\n";
    }
    close $fh;
}

sub lock_datafile {
    my ($id) = @_;
    open my $fh, '>', $LOCK or die $!;
    flock $fh, LOCK_EX      or die $!;
    print $fh "$id\n";
    return bless { fh => $fh }, 'cherrymaint::lock';
}

sub cherrymaint::lock::DESTROY {
    my ($lock) = @_;
    my $fh = $lock->{fh};
    flock $fh, LOCK_UN or die $!;
    close $fh;
}

sub unlock_datafile {
    $_[0]->DESTROY;
}

sub get_user {
    if ($TESTING) {
        my ($user) = getpwuid $<;
        return $user;
    }
    my ($addr, $port) = @_;
    $addr      = sprintf '%08X', unpack 'L', inet_aton $addr;
    $port      = sprintf '%04X', $port;
    my $remote = join ':', $addr, $port;
    open my $tcp, '<', '/proc/net/tcp' or die $!;
    while (<$tcp>) {
        next unless /^\s*\d+:/;
        my @parts = split ' ';
        next unless $#parts >= 7 and $parts[1] eq $remote;
        my $user = getpwuid $parts[7];
        die 'Invalid user' unless defined $user and $user !~ /\s/;
        return $user;
    }
    die "Couldn't find the current user";
    return;
}

my %cache;

sub get_log {
    my $sp = startpoint;
    my $ep = endpoint;
    my $from = qx($GIT log --pretty=format:%H -1 $sp);
    my $to   = qx($GIT log --pretty=format:%H -1 $ep);
    my $cached = $cache{$from}{$to};
    return @$cached if defined $cached;

    local $ENV{PAGER} = '';
    open my $fh, '-|', $GIT, qw(log --no-color --pretty=oneline --abbrev-commit --no-merges),
                             "$from..$to"
         or die $!;
    my @log;
    while (<$fh>) {
        chomp;
        my ($commit, $message) = split / /, $_, 2;
        $commit =~ /^[0-9a-f]+$/ or die;
        utf8::decode $message;
        $message = encode_entities($message);
        push @log, [ $commit, $message ];
    }
    %cache = (); # Keep only one entry in the cache
    $cache{$from}{$to} = \@log;
    return @log;
}

sub calculate_vote_stats {
    my $data = shift;
    my $log = shift;

    my $no_commits      = 0;
    my $no_votes        = 0;
    my %votes_by_user;
    my @commits_by_status;

    for my $log (@$log) {
        my ($commit, $message) = @$log;
        $no_commits++;
        $commit =~ /^[0-9a-f]+$/ or die "<$commit> is not a SHA1";
        my $status = $data->{$commit}->[0] || 0;
        my $votes  = $data->{$commit}->[1];
        $commits_by_status[$status]++;
        foreach my $user (@{$votes||[]}) {
            $no_votes++;
            $votes_by_user{$user} ||= {name => $user};
            $votes_by_user{$user}{total}++;
            if ($status == 1) {
                $votes_by_user{$user}{rejected}++;
            } elsif ($status == 6) {
                $votes_by_user{$user}{discussion}++;
            } else {
                $votes_by_user{$user}{voted}++;
            }
        }
    }

    # rejected or cherry-picked is considered done.
    my $no_commits_done = $commits_by_status[1] + $commits_by_status[5];

    my @users = map { $votes_by_user{$_} }
                sort { $votes_by_user{$b}{total} <=> $votes_by_user{$a}{total} }
                keys %votes_by_user;

    my @statuses = qw(unexamined rejected requested
                      seconded approved cherry_picked to_be_discussed);

    return {
        no_votes        => $no_votes,
        no_commits      => $no_commits,
        no_commits_done => $no_commits_done,
        users           => \@users,
        startpoint      => startpoint(),
        endpoint        => endpoint(),
        (map { "no_" . $statuses[$_] => $commits_by_status[$_] } 0..$#statuses),
    };
}

get '/' => sub {
    my $page = params->{page};
    $page = 0 unless defined $page;
    $page =~ /^[0-9]+$/ or die 'Invalid page number';

    my $limit = params->{limit};
    $limit = 250 unless defined $limit and $limit ne '';
    $limit =~ /^[0-9]+$/ or die 'Invalid limit';

    my $user = params->{ro} ? 'view' : get_user(@ENV{qw/REMOTE_ADDR REMOTE_PORT/});
    my @log  = get_log;
    my $data = do {
        my $lock = lock_datafile("$$-$user");
        load_datafile;
    };

    my (@pages, $current_page);
    if ($limit) {
        my $num = 0;
        for (my $start = 0; $start <= $#log; $start += $limit) {
            my $end = $start + $limit - 1;
            $end    = $#log if $end > $#log;
            if ($num == $page) {
                $current_page = [ $start => $end ];
            }
            push @pages, [ $num, $num == $page ? 1 : 0 ];
            ++$num;
        }
        unless ($current_page) { # Page was out of bounds
            $page = 0;
            $current_page = [ 0 => -1 ];
        }
    } else {
        $page = 0;
        $current_page = [ 0 => $#log ];
        @pages = [ 0, 1 ];
    }

    my ($start, $end) = @$current_page;
    my @commits;
    for my $i ($start .. $end) {
        next if $i > $#log;
        my $log    = $log[$i];
        my $commit = $log->[0];
        my $status = $data->{$commit}->[0] || 0;
        my $votes  = $data->{$commit}->[1];
        push @commits, {
            sha1   => $commit,
            msg    => $log->[1],
            status => $status,
            votes  => $votes,
        };
    }
    template 'index', {
        commits   => \@commits,
        user      => $user,
        limit     => $limit,
        cur_page  => $page,
        last_page => $#pages,
        pages     => \@pages,
        branches  => \@BRANCHES,
        branch    => branchname(),
        ro        => params->{ro} ? 1 : 0,
    };
};

get '/mark' => sub {
    my $commit = params->{commit};
    $commit =~ /^[0-9a-f]+$/ or die 'Invalid commit sha1';

    my $value = params->{value};
    $value =~ /^[0-6]$/ or die 'Invalid grade value';

    my $user = get_user(@ENV{qw/REMOTE_ADDR REMOTE_PORT/});
    my $lock = lock_datafile("$$-$user-mark");
    my $data = load_datafile;

    my $state = $data->{$commit};
    if ($value == 0) { # Unexamined
        $state = [
            $value,
            [ ],
            branchname(),
        ];
    } elsif ($value == 1 or $value == 6) { # Rejected or To be discussed
        $state = [
            $value,
            [ $user ],
            branchname(),
        ];
    } elsif ($value == 5) { # Cherry-picked
        if (defined $state) {
            $state->[0] = $value; # don't override list of users
        }
        else {
            $state = [
                $value,
                [ $user ],
                branchname(),
            ];
        }
    } else { # Vote
        my $old_value = $state->[0];
        if (not defined $old_value or $old_value < 2 or $old_value == 6) {
            # Voting from unexamined / rejected / to be discussed
            $state = [
                2,
                [ $user ],
                branchname(),
            ];
        } elsif ($old_value == 5) {
            # Downvoting from cherry-picked : revert to the state corresponding
            # to the number of stored voters
            my @votes = @{ $state->[1] || [] };
            my $votes = @votes;
            unless (any_eq $user => @votes) {
                # The current user hasn't voted yet, revert to one grade above
                push @{ $state->[1] }, $user;
                ++$votes;
            }
            $state->[0] = ($votes <= 3) ? (1 + $votes) : 4;
        } elsif ($old_value < 5) {
            my @votes = @{ $state->[1] || [] };
            if ($old_value < $value) {
                # Upvoting, only bump the vote by 1 if the user hasn't voted yet
                unless (any_eq $user => @votes) {
                    $state->[0] = $old_value + 1;
                    push @{ $state->[1] }, $user;
                }
            } elsif ($old_value > $value) {
                # Downvoting, only drop the vote by 1 if the user has voted
                my $idx = 0;
                for (@votes) {
                    last if $user eq $_;
                    $idx++;
                }
                if ($idx < @votes) {
                    $state->[0] = $old_value - 1;
                    splice @{ $state->[1] }, $idx, 1;
                }
            }
        }
    }
    $data->{$commit} = $state;
    save_datafile($data);
    return join ' ', $state->[0], @{ $state->[1] || [] };
};

get '/stats' => sub {
    my @log = get_log;
    my $data = load_datafile;
    my $stats = calculate_vote_stats($data, \@log);
    template 'stats', $stats;
};

true;
