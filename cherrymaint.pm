package cherrymaint;
use Dancer;

get '/' => sub {
    template 'index';
};

true;
