package cherrymaint;
use Dancer;
use HTML::Entities;
use Socket qw/inet_aton/;
use List::Util qw/min max/;

my $BLEADGITHOME = config->{gitroot};
my $STARTPOINT = config->{startpoint};
my $ENDPOINT = config->{endpoint};
my $TESTING = config->{testing}; # single-user mode, for testing
my $GIT = "/usr/local/bin/git";
my $DATAFILE = "$ENV{HOME}/cherrymaint.db";

chdir $BLEADGITHOME or die "Can't chdir to $BLEADGITHOME: $!\n";

sub load_datafile {
    my $data = {};
    open my $fh, '<', $DATAFILE or die "Can't open $DATAFILE: $!";
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
    open my $fh, '>', $DATAFILE or die "Can't open $DATAFILE: $!";
    for my $k (keys %$data) {
        next unless $data->{$k};
        my ($value, $votes) = @{ $data->{$k} };
        my @votes = @{ $votes || [] };
        print $fh "$k $value @votes\n";
    }
    close $fh;
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
        die 'Invalid user' unless defined $user;
        return $user;
    }
    die "Couldn't find the current user";
    return;
}

get '/' => sub {
    my $user = get_user(@ENV{qw/REMOTE_ADDR REMOTE_PORT/});
    my @log  = qx($GIT log --no-color --oneline --no-merges $STARTPOINT..$ENDPOINT);
    my $data = load_datafile;
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
    my @votes;
    my $commit = params->{commit};
    my $value = params->{value};
    $commit =~ /^[0-9a-f]+$/ or die;
    $value =~ /^[0-5]$/ or die;
    my $user = get_user(@ENV{qw/REMOTE_ADDR REMOTE_PORT/});
    my $data = load_datafile;
    if ($value == 0) { # Unexamined
        $data->{$commit} = [
            $value,
        ];
    } elsif ($value == 1) { # Rejected
        $data->{$commit} = [
            $value,
            [ $user ],
        ];
        @votes = ($user);
    } elsif ($value == 5) { # Cherry-picked
        $data->{$commit}->[0] = $value;
        @votes = @{ $data->{$commit}->[1] || [] };
    } else { # Vote
        my $old_value = $data->{$commit}->[0];
        if (not defined $old_value or $old_value < 2) {
            $data->{$commit} = [
                2,
                [ $user ],
            ];
            @votes = ($user);
        } elsif ($old_value < 5) {
            @votes = @{ $data->{$commit}->[1] || [] };
            if ($old_value < $value) {
                unless (eval { $user eq $_ and return 1 for @votes; 0 }) {
                    $data->{$commit}->[0] = $old_value + 1;
                    push @{ $data->{$commit}->[1] }, $user;
                    push @votes, $user;
                }
            } elsif ($old_value > $value) {
                my $idx = eval {
                    my $i = 0;
                    $user eq $_ and return $i++ for @votes;
                    undef
                };
                if (defined $idx) {
                    $data->{$commit}->[0] = $old_value - 1;
                    splice @{ $data->{$commit}->[1] }, $idx, 1;
                    @votes = @{ $data->{$commit}->[1] || [] };
                }
            }
        }
    }
    save_datafile($data);
    return "@votes";
};

true;
