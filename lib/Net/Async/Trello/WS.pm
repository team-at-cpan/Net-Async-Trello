package Net::Async::Trello::WS;

use strict;
use warnings;

use Syntax::Keyword::Try;

use parent qw(IO::Async::Notifier);

use JSON::MaybeXS;
use Net::Async::WebSocket::Client;

use JSON::MaybeUTF8 qw(:v1);
use Log::Any qw($log);

use constant PING_INTERVAL => 20;

sub configure {
	my ($self, %args) = @_;
	for my $k (grep exists $args{$_}, qw(token trello)) {
		$self->{$k} = delete $args{$k};
	}
	$self->SUPER::configure(%args);
}

sub connection {
    my ($self, %args) = @_;
    $self->{ws_connection} ||= do {
        my $uri = $self->trello->endpoint(
            'websockets',
            token => $self->token,
        );
        $self->{ws}->connect(
            url        => "$uri",
            host       => $uri->host,
            ($uri->scheme eq 'wss'
            ? (
                service      => 443,
                extensions   => [ qw(SSL) ],
                SSL_hostname => $uri->host,
            ) : (
                service    => 80,
            ))
        )->then(sub {
            my ($conn) = @_;
            $log->tracef("Connected");
            $conn->send_frame(
                buffer => encode_json_utf8({"type" => "ping", "reqid" => 0}),
                masked => 1
            )->transform(done => sub { $conn });
        })->on_fail(sub {
            $log->errorf('Failed to connect to WS - %s %s %s', $_[0], $_[1], $_[2]);
        });
    };
}

sub send {
    my ($self, $data, %args) = @_;
    $data = encode_json_utf8($data) if ref $data;
    $log->tracef('>> %s', $data);
    $self->{ws}->send_frame(
        buffer => $data,
        masked => 1
    )
}

my %model_for_type = (
    board  => 'Board',
    card   => 'Card',
    member => 'Member',
    list   => 'List',
);

sub subscribe {
    my ($self, %args) = @_;
    my $type = delete $args{type} // die 'need a type for subscription';
    my $id = delete $args{id} // die 'need an ID for subscription';
    my @tags = @{ delete $args{tags} || [qw(clientActions updates)] };
    $self->{update_channel}{$id} = {
        type   => $type,
        source => my $src = $self->ryu->source(
            label => join(':', $type => $id)
        )
    };
    $self->connection->then(sub {
        my ($conn) = @_;
        $log->tracef("Subscribing to %s %s for events %s", $type, $id, join ',', @tags);
        $conn->send_frame(
            buffer => encode_json_utf8({
                idModel          => $id,
                invitationTokens => [],
                modelType        => $model_for_type{$type},
                reqid            => 1,
                tags             => \@tags,
                type             => "subscribe",
            }),
            masked => 1
        );
    })->retain;
    $src
}

sub on_frame {
	my ($self, $ws, $bytes) = @_;

    $log->tracef('<< %s', $bytes);
    if(length $bytes) {
        try {
            my $data = decode_json_utf8($bytes);
            if(my $id = $data->{idModelChannel}) {
                $log->tracef("Notification for entity ID [%s] - %s", $id, $data);
                if(my $entry = $self->{update_channel}{$id}) {
                    $log->tracef("This is a %s, emitting event", $entry->{type});
                    $entry->{source}->emit($data->{notify});
                } else {
                    $log->errorf('Received an update for a source that does not exist: %s', $id);
                }
            } else {
                $log->warnf("No idea what %s is", $data);
            }
        } catch {
            $log->errorf("Exception in websocket raw frame handling: %s (original text %s)", $@, $bytes);
        }
    } else {
        # Empty frame is used for PING, send a response back
        $log->tracef('Empty frame received, sending one back (ping/pong)');
        $self->pong;
    }
}

sub pong {
    my ($self) = @_;
    $self->send('');
}

sub next_request_id {
    ++shift->{request_id}
}

sub _add_to_loop {
    my ($self, $loop) = @_;

    $self->add_child(
        $self->{ryu} = Ryu::Async->new
    );

    $self->add_child(
        $self->{ws} = Net::Async::WebSocket::Client->new(
            on_frame => $self->curry::weak::on_frame,
        )
    );
    $self->add_child(
        my $timer = IO::Async::Timer::Periodic->new(
            interval => 20,
            on_tick => $self->curry::weak::on_tick,
        )
    );
    Scalar::Util::weaken($self->{timer} = $timer);
}

sub on_tick {
    my ($self) = @_;
    my $ws = $self->connection;
    return unless $ws->is_ready;
    $self->pong;
}

sub trello { shift->{trello} }
sub token { shift->{token} }
sub timer { shift->{timer} }

sub ryu { shift->trello->ryu(@_) }

1;

