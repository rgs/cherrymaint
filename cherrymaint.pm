package cherrymaint;
use Dancer;
use HTML::Entities;

my $BLEADGITHOME = config->{gitroot};
my $STARTPOINT = config->{startpoint};
my $ENDPOINT = config->{endpoint};
my $GIT = "/usr/bin/git";
my $DATAFILE = "$ENV{HOME}/cherrymaint.db";

chdir $BLEADGITHOME or die "Can't chdir to $BLEADGITHOME: $!\n";

sub load_datafile {
    my $data = {};
    open my $fh, '<', $DATAFILE or die $!;
    while (<$fh>) {
        chomp;
        my ($commit, $value) = split / /;
        $data->{$commit} = 0 + $value;
    }
    close $fh;
    return $data;
}

sub save_datafile {
    my ($data) = @_;
    open my $fh, '>', $DATAFILE or die $!;
    for my $k (keys %$data) {
        print $fh "$k $data->{$k}\n" if $data->{$k};
    }
    close $fh;
}

get '/' => sub {
    my @log = qx($GIT log --no-color --oneline $STARTPOINT..$ENDPOINT);
    my $data = load_datafile;
    my @commits;
    for my $log (@log) {
        chomp $log;
        my ($commit, $message) = split / /, $log, 2;
        $commit =~ /^[0-9a-f]+$/ or die;
        $message = encode_entities($message);
        push @commits, {
            sha1 => $commit,
            msg => $message,
            status => $data->{$commit} || 0,
        };
    }
    template 'index', { commits => \@commits };
};

get '/mark' => sub {
    my $commit = params->{commit};
    my $value = params->{value};
    $commit =~ /^[0-9a-f]+$/ or die;
    $value =~ /^[0-9]$/ or die;
    my $data = load_datafile;
    $data->{$commit} = $value;
    save_datafile($data);
};

true;
