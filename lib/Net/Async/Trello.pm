package Net::Async::Trello;
# ABSTRACT: Interaction with the trello.com API

use strict;
use warnings;

use parent qw(IO::Async::Notifier);

our $VERSION = '0.001';

=head1 NAME

Net::Async::Trello

=head1 DESCRIPTION

Provides a basic interface for interacting with the L<Trello|https://trello.com> webservice.

=cut

no indirect;

use Dir::Self;
use curry;
use Future;
use URI;
use URI::QueryParam;
use URI::Template;
use URI::wss;
use HTTP::Request;

use JSON::MaybeXS;
use Syntax::Keyword::Try;

use File::ShareDir ();
use Log::Any qw($log);
use Path::Tiny ();

use IO::Async::SSL;

use Net::Async::OAuth::Client;

use Net::Async::WebSocket::Client;

use Net::Async::Trello::Organisation;
use Net::Async::Trello::Member;
use Net::Async::Trello::Board;
use Net::Async::Trello::Card;
use Net::Async::Trello::List;

use Ryu::Async;
use Adapter::Async::OrderedList::Array;

my $json = JSON::MaybeXS->new;

=head2 me

Returns profile information for the current user.

=cut

sub me {
	my ($self, %args) = @_;
	$self->http_get(
		uri => URI->new($self->base_uri . 'members/me')
	)->transform(
        done => sub {
            Net::Async::Trello::Member->new(
                %{ $_[0] },
                trello => $self,
            )
        }
    )
}

=head2 boards

Returns a L<Ryu::Source> representing the available boards.

=cut

sub boards {
	my ($self, %args) = @_;
    $self->api_get_list(
        endpoint => 'boards',
        class    => 'Net::Async::Trello::Board',
    )
}

sub board {
	my ($self, %args) = @_;
    my $id = delete $args{id};
	$self->http_get(
		uri => URI->new($self->base_uri . 'board/' . $id)
	)->transform(
        done => sub {
            Net::Async::Trello::Board->new(
                %{ $_[0] },
                trello => $self,
            )
        }
    )
}

sub configure {
	my ($self, %args) = @_;
	for my $k (grep exists $args{$_}, qw(key secret token token_secret ws_token)) {
		$self->{$k} = delete $args{$k};
	}
	$self->SUPER::configure(%args);
}

sub ws_token { shift->{ws_token} }

sub key { shift->{key} }
sub secret { shift->{secret} }
sub token { shift->{token} }
sub token_secret { shift->{token_secret} }

sub oauth {
	my ($self) = @_;
	$self->{oauth} //= Net::Async::OAuth::Client->new(
		realm           => 'Trello',
		consumer_key    => $self->key,
		consumer_secret => $self->secret,
		token           => $self->token,
		token_secret    => $self->token_secret,
	)
}

sub http {
	my ($self) = @_;
	$self->{http} ||= do {
		require Net::Async::HTTP;
		$self->add_child(
			my $ua = Net::Async::HTTP->new(
				fail_on_error            => 1,
				max_connections_per_host => 2,
				pipeline                 => 0,
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

=head2 endpoints

=cut

sub endpoints {
	my ($self) = @_;
	$self->{endpoints} ||= do {
        my $path = Path::Tiny::path(__DIR__)->parent(3)->child('share/endpoints.json');
        $path = Path::Tiny::path(
            File::ShareDir::dist_file(
                'Net-Async-Trello',
                'endpoints.json'
            )
        ) unless $path->exists;
        $json->decode($path->slurp_utf8)
    };
}

=head2 endpoint

=cut

sub endpoint {
	my ($self, $endpoint, %args) = @_;
	URI::Template->new(
        $self->endpoints->{$endpoint . '_url'}
    )->process(%args);
}

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
        $log->tracef("%s => %s", $args{uri}, $resp->decoded_content);
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

sub socket_io {
	my ($self, %args) = @_;

    my $uri = $self->endpoint('socket_io');
	$args{headers}{Authorization} = $self->oauth->authorization_header(
		method => 'GET',
		uri => $uri,
	);

	$log->tracef("GET %s { }", ''. $uri);
    $self->http->GET(
        $uri,
		%args
    )->then(sub {
        my ($resp) = @_;
        return { } if $resp->code == 204;
        return { } if 3 == ($resp->code / 100);
        my @info = split /:/, $resp->decoded_content;
        die "expected websocket" unless $info[3] eq 'websocket';
        Future->done($info[0]);
    });
}

sub websocket {
    my ($self, %args) = @_;
    $self->{ws_connection} ||= $self->socket_io->on_done(sub {
        my $k = shift;
        $log->tracef("Will use key [%s] for socket.io", $k);
    })->then(sub {
        my ($k) = @_;
        #
        # my $uri = URI->new('wss://trello.com/socket.io/1/websocket/' . $k);
        my $uri = $self->endpoint(
            'websockets',
            # token => '506d9fab25bc40ed5ab957b4/' . $self->token
            # socket.io - only works for socket.io, except not even that
            # token => $k,
            # hardcoded from browser
            token => $self->ws_token,
        );
        warn "uri = $uri\n";
        $self->{ws}->connect(
            url        => $uri,
            host       => $uri->host,
            ($uri->scheme eq 'wss'
            ? (
                service      => 443,
                extensions   => [ qw(SSL) ],
                SSL_hostname => $uri->host,
            ) : (
                service    => 80,
            ))
        )
    })->then(sub {
        my ($conn) = @_;
        $log->tracef("Connected");
        # $conn->send_frame($json->encode({"type"=> "ping","reqid"=>0}));
        Future->done;
    });
}

sub api_get_list {
    use Variable::Disposition qw(retain_future);
    use Scalar::Util qw(refaddr);
    use Future::Utils qw(fmap0);
    use namespace::clean qw(retain_future refaddr);

	my ($self, %args) = @_;
    my $label = $args{endpoint}
    ? ('Trello[' . $args{endpoint} . ']')
    : (caller 1)[3];

    die "Must be a member of a ::Loop" unless $self->loop;

    # Hoist our HTTP API call into a source of items
    my $src = $self->ryu->source(
        label => $label
    );
    my $uri = $args{endpoint}
    ? $self->endpoint(
        $args{endpoint},
        %{$args{endpoint_args}}
    ) : URI->new(
        $self->base_uri . $args{uri}
    );

    my $per_page = (delete $args{per_page}) || 100;
    $uri->query_param(
        limit => $per_page
    );
    my $f = (fmap0 {
#        $uri->query_param(
#            before => $per_page
#        );
        $self->http_get(
            uri => $uri,
        )->on_done(sub {
            $log->tracef("we received %s", $_[0]);
            $src->emit(
                $args{class}->new(
                    %$_,
                    ($args{extra} ? %{$args{extra}} : ()),
                    trello => $self
                )
            ) for @{ $_[0] };
            $src->finish;
        })->on_fail(sub {
            $src->fail(@_)
        })->on_cancel(sub {
            $src->cancel
        });
    } foreach => [1]);

    # If our source finishes earlier than our HTTP request, then cancel the request
    $src->completed->on_ready(sub {
        return if $f->is_ready;
        $log->tracef("Finishing HTTP request early for %s since our source is no longer active", $label);
        $f->cancel
    });

    # Track active requests
    my $refaddr = Scalar::Util::refaddr($f);
    retain_future(
        $self->pending_requests->push([ {
            id  => $refaddr,
            src => $src,
            uri => $args{uri},
            future => $f,
        } ])->then(sub {
            $f->on_ready(sub {
                retain_future(
                    $self->pending_requests->extract_first_by(sub { $_->{id} == $refaddr })
                )
            });
        })
    );
    $src
}

sub pending_requests {
    shift->{pending_requests} //= Adapter::Async::OrderedList::Array->new
}

sub next_request_id {
    ++shift->{request_id}
}

{
my %types = reverse %Protocol::WebSocket::Frame::TYPES;
sub on_raw_frame {
	my ($self, $ws, $frame, $bytes) = @_;
    my $text = Encode::decode_utf8($bytes);
    $log->debugf("Have frame opcode %d type %s with bytes [%s]", $frame->opcode, $types{$frame->opcode}, $text);

    # Empty frame is used for PING, send a response back
    if($frame->opcode == 1) {
        if(!length($bytes)) {
            $ws->send_frame('');
        } else {
            $log->tracef("<< %s", $text);
            try {
                my $data = $json->decode($text);
                if(my $chan = $data->{idModelChannel}) {
                    $log->tracef("Notification for [%s] - %s", $chan, $data);
                    $self->{update_channel}{$chan}->emit($data->{notify});
                } else {
                    $log->warnf("No idea what %s is", $data);
                }
            } catch {
                warn "oh noes - $@ from $text";
            }
        }
    }
}
}

sub on_frame {
	my ($self, $ws, $text) = @_;
    $log->debugf("Have WS frame [%s]", $text);
}

sub ryu { shift->{ryu} }

sub _add_to_loop {
    my ($self, $loop) = @_;

    $self->add_child(
        $self->{ryu} = Ryu::Async->new
    );

    $self->add_child(
        $self->{ws} = Net::Async::WebSocket::Client->new(
            on_raw_frame => $self->curry::weak::on_raw_frame,
            on_frame     => sub { },
        )
    );
}

sub oauth_request {
    my ($self, $code) = @_;

    # We don't provide any scope or expiration details at this point. Those are added to the URI in the browser.
    my $uri = URI->new('https://trello.com/1/OAuthGetRequestToken');
    my $req = HTTP::Request->new(POST => "$uri");
    $req->protocol('HTTP/1.1');

    warn "Get auth header";
    # $req->header(Authorization => 'Bearer ' . $self->req);
    $self->oauth->configure(
        token => '',
        token_secret => '',
    );
    my $hdr = $self->oauth->authorization_header(
        method => 'POST',
        uri    => $uri,
    );
    $req->header('Authorization' => $hdr);
    $log->infof("Resulting auth header for userstream was %s", $hdr);

    $req->header('Host' => $uri->host);
    # $req->header('User-Agent' => 'OAuth gem v0.4.4');
    $req->header('Connection' => 'close');
    $req->header('Accept' => '*/*');
    $self->http->do_request(
        request => $req,
    )->then(sub {
        my ($resp) = @_;
        $log->debugf("RequestToken response was %s", $resp->as_string("\n"));
        my $rslt = URI->new('http://localhost?' . $resp->decoded_content)->query_form_hash;
        $log->debugf("Extracted token [%s]", $rslt->{oauth_token});
        $self->oauth->configure(token => $rslt->{oauth_token});
        $log->debugf("Extracted secret [%s]", $rslt->{oauth_token_secret});
        $self->oauth->configure(token_secret => $rslt->{oauth_token_secret});

        my $auth_uri = URI->new(
            'https://trello.com/1/OAuthAuthorizeToken'
        );
        $auth_uri->query_param(oauth_token => $rslt->{oauth_token});
        $auth_uri->query_param(scope => 'read,write');
        $auth_uri->query_param(name => 'trelloctl');
        $auth_uri->query_param(expiration => 'never');
        $code->($auth_uri);
    }, sub {
        $log->errorf("Failed to do oauth lookup - %s", join ',', @_);
        die @_;
    })->then(sub {
        my ($verify) = @_;
        my $uri = URI->new('https://trello.com/1/OAuthGetAccessToken');
        my $req = HTTP::Request->new(POST => "$uri");
        $req->protocol('HTTP/1.1');

        # $req->header(Authorization => 'Bearer ' . $self->req);
        my $hdr = $self->oauth->authorization_header(
            method => 'POST',
            uri    => $uri,
            parameters => {
                oauth_verifier => $verify
            }
        );
        $req->header('Authorization' => $hdr);
        $log->infof("Resulting auth header was %s", $hdr);

        $req->header('Host' => $uri->host);
        # $req->header('User-Agent' => 'OAuth gem v0.4.4');
        $req->header('Connection' => 'close');
        $req->header('Accept' => '*/*');
        $self->http->do_request(
            request => $req,
        )
    })->then(sub {
        my ($resp) = @_;
        $log->tracef("GetAccessToken response was %s", $resp->as_string("\n"));
        my $rslt = URI->new('http://localhost?' . $resp->decoded_content)->query_form_hash;
        $log->tracef("Extracted token [%s]", $rslt->{oauth_token});
        $self->configure(token => $rslt->{oauth_token});
        $log->tracef("Extracted secret [%s]", $rslt->{oauth_token_secret});
        $self->configure(token_secret => $rslt->{oauth_token_secret});
        Future->done(+{
            token        => $rslt->{oauth_token},
            token_secret => $rslt->{oauth_token_secret},
        })
    })
}

1;
