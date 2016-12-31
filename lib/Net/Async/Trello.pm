package Net::Async::Trello;
# ABSTRACT: Interaction with the trello.com API

use strict;
use warnings;

use parent qw(IO::Async::Notifier);

our $VERSION = '0.001';

no indirect;

use curry;
use Future;
use URI;
use URI::Template;
use JSON::MaybeXS;
use Syntax::Keyword::Try;

use File::ShareDir ();
use Log::Any qw($log);
use Path::Tiny ();

use Net::Async::OAuth::Client;

use Net::Async::WebSocket::Client;

use Net::Async::Trello::Organisation;
use Net::Async::Trello::Member;
use Net::Async::Trello::Board;
use Net::Async::Trello::Card;
use Net::Async::Trello::List;

my $json = JSON::MaybeXS->new;

sub configure {
	my ($self, %args) = @_;
	for my $k (grep exists $args{$_}, qw(key secret token token_secret)) {
		$self->{$k} = delete $args{$k};
		# die "provided but not true" unless $self->{$k};
	}
	$self->SUPER::configure(%args);
}

sub key { shift->{key} }
sub secret { shift->{secret} }
sub token { shift->{token} }
sub token_secret { shift->{token_secret} }

sub oauth {
	my ($self) = @_;
	$self->{oauth} //= Net::Async::OAuth::Client->new(
		realm           => 'Trello',
		consumer_key    => ($self->key // die 'Need an OAuth consumer key for Trello API'),
		consumer_secret => ($self->secret // die 'Need an OAuth consumer secret for Trello API'),
		token           => ($self->token // die 'Need an OAuth consumer key for Trello API'),
		token_secret    => ($self->token_secret // die 'Need an OAuth consumer secret for Trello API'),
	)
}

sub endpoints {
	my ($self) = @_;
	$self->{endpoints} ||= $json->decode(
		Path::Tiny::path(
			'share/endpoints.json' //
			File::ShareDir::dist_file(
				'Net-Async-Github',
				'endpoints.json'
			)
		)->slurp_utf8
	);
}

sub endpoint {
	my ($self, $endpoint, %args) = @_;
	URI::Template->new($self->endpoints->{$endpoint . '_url'})->process(%args);
}

sub http {
	my ($self) = @_;
	$self->{http} ||= do {
		require Net::Async::HTTP;
		$self->add_child(
			my $ua = Net::Async::HTTP->new(
				fail_on_error            => 1,
				max_connections_per_host => 4,
				pipeline                 => 1,
				max_in_flight            => 4,
				decode_content           => 1,
				timeout                  => 30,
				user_agent               => 'Mozilla/4.0 (perl; Net::Async::Trello; TEAM@cpan.org)',
			)
		);
		$ua
	}
}

sub auth_info {
	my ($self) = @_;
}

sub mime_type { shift->{mime_type} //= 'application/json' }
sub base_uri { shift->{base_uri} //= URI->new('https://api.trello.com/1/') }

sub http_get {
	my ($self, %args) = @_;

	$args{headers}{Authorization} = $self->oauth->authorization_header(
		method => 'GET',
		uri => $args{uri}
	);

	$log->tracef("GET %s { %s }", ''. $args{uri}, \%args);
    $self->http->GET(
        (delete $args{uri}),
		%args
    )->then(sub {
        my ($resp) = @_;
        return { } if $resp->code == 204;
        return { } if 3 == ($resp->code / 100);
        try {
#			warn "have " . $resp->as_string("\n");
            return Future->done($json->decode($resp->decoded_content))
        } catch {
            $log->errorf("JSON decoding error %s from HTTP response %s", $@, $resp->as_string("\n"));
            return Future->fail($@ => json => $resp);
        }
    })->else(sub {
        my ($err, $src, $resp, $req) = @_;
        $src //= '';
        if($src eq 'http') {
            $log->errorf("HTTP error %s, request was %s with response %s", $err, $req->as_string("\n"), $resp->as_string("\n"));
        } else {
            $log->errorf("Other failure (%s): %s", $src // 'unknown', $err);
        }
        Future->fail(@_);
    })
}

sub me {
	my ($self, %args) = @_;
	$self->http_get(
		uri => URI->new($self->base_uri . 'members/me')
	)->transform(
        done => sub { Net::Async::Trello::Member->new(%{ $_[0] }) }
    )
}

sub boards {
	my ($self, %args) = @_;
	$self->http_get(
		uri => URI->new($self->base_uri . 'members/me/boards')
	)->transform(
        done => sub { map Net::Async::Trello::Board->new(%$_), @{ $_[0] } }
    )
}

sub on_frame {
	my ($self, $frame) = @_;
}

sub _add_to_loop {
    my ($self, $loop) = @_;

    $self->add_child(
        $self->{ws} = Net::Async::WebSocket::Client->new(
            on_frame => $self->curry::weak::on_frame
        )
    );
}

1;
