package Guita::Handler::Auth;
use prelude;

use URI;
use LWP::UserAgent;
use HTTP::Request::Common;
use URI::Escape qw(uri_escape);
use JSON::XS;
use Digest::SHA1 qw(sha1_hex);
use Path::Class qw(file);
use DateTime;
use DateTime::Format::HTTP;

# see http://developer.github.com/v3/oauth/

sub default {
    my ($self, $c) = @_;

    my $auth_location = $c->req->param('auth_location') // '';
    $c->req->session->{auth_location} = $auth_location;

    my $uri = URI->new('https://github.com/login/oauth/authorize');
    $uri->query_form(
        client_id => GuitaConf('github_client_id'),
        scope => 'user,public_repo',
    );

    $c->redirect($uri->as_string);
}

sub callback {
    my ($self, $c) = @_;

    $c->throw(code => 400, message => 'Bad Request') unless $c->req->param('code');

    my $ua = LWP::UserAgent->new;
    my $access_token = do {
        my $res = $ua->request(POST(
            'https://github.com/login/oauth/access_token', 
            [
                client_id     => GuitaConf('github_client_id'),
                client_secret => GuitaConf('github_client_secret'),
                code          => scalar($c->req->param('code')),
            ],
        ));
        $c->throw(code => 400, message => 'Bad Request: token') if $res->is_error;

        my ($access_token) = $res->content =~ m/access_token=(.*?)(?:&|$)/xms;
        $access_token;
    };

    my $user_json = do {
        my $res = $ua->request(GET(
            'https://api.github.com/user?access_token=' . uri_escape($access_token),
        ));
        $c->throw(code => 400, message => 'Bad Request: user json') if $res->is_error;
        decode_json($res->content);
    };

    my $sk = sha1_hex(
        join('-', 'salt', GuitaConf('session_key_salt'), $user_json->{id}, time())
    );
    my $user = $c->dbixl->table('user')->search({ github_id => $user_json->{id} })->single;
    if ($user) {
        $user->sk($sk);
        my $struct = $user->struct;
        $struct->{api}->{user}      = $user_json;
        $user->{struct} = encode_json($struct);

        $user->update({
            name   => $user_json->{login},
            sk     => $sk,
            struct => encode_json( $struct ),
        });
    }
    else {
        $user = $c->dbixl->table('user')->insert({
            github_id => $user_json->{id},
            name      => $user_json->{login},
            sk        => $sk,
            struct    => encode_json({
                api => {
                    user      => $user_json,
                }
            }),
        });
    }
    my $expires = DateTime::Format::HTTP->format_datetime(
        DateTime->now(time_zone => 'local')->add( days => 7 )
    );
    my $domain = $c->req->uri->host;
    $c->res->headers->header('Set-Cookie' => qq[csk=$sk; path=/; expires=$expires; domain=$domain;]);

    my $auth_location = do {
        my $loc = $c->req->session->{auth_location};
        $loc = !$loc || ( $loc && $loc =~ m/^http/) ? '/' : $loc;
        $loc;
    };

    $c->redirect($auth_location);
}

sub logout {
    my ($self, $c) = @_;
    $c->throw(code => 400, message => 'Bad Request') if $c->user->is_guest;

    $c->user->update({ sk => '' });

    $c->redirect('/');
}

1;
