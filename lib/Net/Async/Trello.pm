package Net::Async::Trello;

use strict;
use warnings;

use parent qw(IO::Async::Notifier);

use Future;
use URI;
use URI::Template;
use JSON::MaybeXS;
use Syntax::Keyword::Try;

use File::ShareDir ();
use Log::Any qw($log);
use Path::Tiny ();

my $json = JSON::MaybeXS->new;

sub configure {
	my ($self, %args) = @_;
	for my $k (grep exists $args{$_}, qw(token)) {
		$self->{$k} = delete $args{$k};
	}
	$self->SUPER::configure(%args);
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
				user_agent               => 'Mozilla/4.0 (perl; Net::Async::Github; TEAM@cpan.org)',
			)
		);
		$ua
	}
}

sub auth_info {
	my ($self) = @_;
	if(my $key = $self->api_key) {
		return (
			user => $self->api_key,
			pass => '',
		);
	} elsif(my $token = $self->token) {
		return (
			headers => {
				Authorization => 'token ' . $token
			}
		)
	} else {
		die "need some form of auth, try passing a token or api_key"
	}
}

sub api_key { shift->{api_key} }
sub token { shift->{token} }

sub mime_type { shift->{mime_type} //= 'application/vnd.github.v3+json' }
sub base_uri { shift->{base_uri} //= URI->new('https://api.github.com') }

sub http_get {
	my ($self, %args) = @_;
	my %auth = $self->auth_info;

	if(my $hdr = delete $auth{headers}) {
		$args{headers}{$_} //= $hdr->{$_} for keys %$hdr
	}
	$args{$_} //= $auth{$_} for keys %auth;

	$log->tracef("GET %s { %s }", ''. $args{uri}, \%args);
    $self->http->GET(
        (delete $args{uri}),
		%args
    )->then(sub {
        my ($resp) = @_;
        return { } if $resp->code == 204;
        return { } if 3 == ($resp->code / 100);
        try {
			warn "have " . $resp->as_string("\n");
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

1;
