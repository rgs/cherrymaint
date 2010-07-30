package cherrymaint;
use Dancer;
use HTML::Entities;
use Socket qw/inet_aton/;
use List::Util qw/min max/;
use Fcntl qw/LOCK_EX LOCK_UN/;

my $BLEADGITHOME = config->{gitroot};
my $STARTPOINT = config->{startpoint};
my $ENDPOINT = config->{endpoint};
my $GIT = "/usr/local/bin/git";
my $DATAFILE = "$ENV{HOME}/cherrymaint.db";
my $LOCK     = "$ENV{HOME}/cherrymaint.lock";

chdir $BLEADGITHOME or die "Can't chdir to $BLEADGITHOME: $!\n";

sub any_eq {
    my $str = shift;
    $str eq $_ and return 1 for @_;
    0;
}

sub load_datafile {
    my $data = {};
    open my $fh, '<', $DATAFILE or die $!;
    while (<$fh>) {
        chomp;
        my ($commit, $value, @votes) = split ' ';
        $data->{$commit} = [
            0 + $value,
            \@votes,
        ];
    }
    close $fh;
    return $data;
}

sub save_datafile {
    my ($data) = @_;
    open my $fh, '>', $DATAFILE or die $!;
    for my $k (keys %$data) {
        next unless $data->{$k};
        my ($value, $votes) = @{ $data->{$k} };
        my @votes = @{ $votes || [] };
        print $fh "$k $value @votes\n";
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
        die 'Invalid user' unless defined $user;
        return $user;
    }
    die "Couldn't find the current user";
    return;
}

get '/' => sub {
    my $user = get_user(@ENV{qw/REMOTE_ADDR REMOTE_PORT/});
    my @log  = qx($GIT log --no-color --oneline --no-merges $STARTPOINT..$ENDPOINT);
    my $data = do {
        my $lock = lock_datafile("$$-$user");
        load_datafile;
    };
    my @commits;
    for my $log (@log) {
        chomp $log;
        my ($commit, $message) = split / /, $log, 2;
        $commit =~ /^[0-9a-f]+$/ or die;
        $message = encode_entities($message);
        my $status = $data->{$commit}->[0] || 0;
        my $votes  = $data->{$commit}->[1];
        push @commits, {
            sha1   => $commit,
            msg    => $message,
            status => $status,
            votes  => $votes,
        };
    }
    template 'index', {
        commits => \@commits,
        user    => $user,
    };
};

get '/mark' => sub {
    my $commit = params->{commit};
    my $value = params->{value};
    $commit =~ /^[0-9a-f]+$/ or die;
    $value =~ /^[0-6]$/ or die;
    my $user = get_user(@ENV{qw/REMOTE_ADDR REMOTE_PORT/});
    my $lock = lock_datafile("$$-$user-mark");
    my $data = load_datafile;
    my $state = $data->{$commit};
    if ($value == 0) { # Unexamined
        $state = [
            $value,
            [ ],
        ];
    } elsif ($value == 1 or $value == 6) { # Rejected or To be discussed
        $state = [
            $value,
            [ $user ],
        ];
    } elsif ($value == 5) { # Cherry-picked
        $state->[0] = $value;
    } else { # Vote
        my $old_value = $state->[0];
        if (not defined $old_value or $old_value < 2) {
            $state = [
                2,
                [ $user ],
            ];
        } elsif ($old_value < 5) {
            my @votes = @{ $state->[1] || [] };
            if ($old_value < $value) {
                unless (any_eq $user => @votes) {
                    $state->[0] = $old_value + 1;
                    push @{ $state->[1] }, $user;
                }
            } elsif ($old_value > $value) {
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
    return join ' ', @{ $state->[1] || [] };
};

true;
