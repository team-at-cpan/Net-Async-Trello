package Net::Async::Trello::Board;

use strict;
use warnings;

use parent qw(Net::Async::Trello::Generated::Board);

use JSON::MaybeXS;
use Log::Any qw($log);

my $json = JSON::MaybeXS->new;

=head2 subscribe

=cut

sub subscribe {
    use Variable::Disposition qw(retain_future);
    use namespace::clean qw(retain_future);
	my ($self, %args) = @_;
    my $trello = $self->trello;
    my $board_id = $self->id;
    $log->tracef("Attempting to subscribe to board %s", $board_id);
    $self->{subscribed} ||= {};
    unless($self->{subscribed}{board}{$board_id}) {
        $self->{subscribed}{board}{$board_id} = my $src = $trello->ryu->source(
            label => "board:$board_id"
        );
        retain_future(
            $trello->websocket->then(sub {
                my $req_id = $trello->next_request_id;
                my $txt = $json->encode({
                    type             => "subscribe",
                    modelType        => "Board",
                    idModel          => $board_id,
                    tags             => [qw(clientActions updates)],
                    invitationTokens => [],
                    reqid            => $req_id,
                });
            # $txt = '3:::{"sFxn":"ping","rgarg":[],"reqid":' . $req_id . ',"token":"' . $trello->token . '"}';
                $log->tracef(">> %s", $txt);
                $trello->loop->delay_future(after => 1.1)->then(sub {
                    $trello->{ws}->send_frame(
                        buffer => $txt,
                        masked => 1,
                    )
                })
            })
        );
        $self->{updated_channel} ||= {};
        $self->{update_channel}{$board_id} = $src;
    }
    $self->{subscribed}{board}{$board_id}
}

=head2 lists

=cut

sub lists {
	my ($self, %args) = @_;
    $self->trello->api_get_list(
		uri => 'boards/' . $self->id . '/lists',
        class => 'Net::Async::Trello::List',
        extra => {
            board  => $self,
        },
    )
}

=head2 cards

=cut

sub cards {
	my ($self, %args) = @_;
    $self->trello->api_get_list(
		uri => 'boards/' . $self->id . '/cards',
        class => 'Net::Async::Trello::Card',
        extra => {
            board  => $self,
        },
    )
}

1;

