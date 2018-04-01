package Net::Async::Trello::Board;

use strict;
use warnings;

use parent qw(Net::Async::Trello::Generated::Board);

use JSON::MaybeUTF8 qw(:v1);
use Log::Any qw($log);

=head2 subscribe

=cut

sub subscribe {
	my ($self, %args) = @_;
    my $trello = $self->trello;
    my $board_id = $self->id;
    $trello->websocket->subscribe(
        type => 'board',
        id => $board_id
    )
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

=head2 create_card

Creates a new card on this board.

=cut

sub create_card {
	my ($self, %args) = @_;
    my %body = (
        name      => $args{name},
        desc      => $args{description},
        pos       => $args{position} // 'bottom',
    );
    $body{idList} = ref($args{list}) ? $args{list}->id : $args{list};
    $body{idMembers} = join(',', map $_->id, @{$args{members}});
	$self->trello->http_post(
		uri => URI->new($self->trello->base_uri . 'cards'),
        body => \%body,
	)->transform(
        done => sub {
            Net::Async::Trello::Card->new(
                %{ $_[0] },
                board => $self,
                trello => $self->trello,
            )
        }
    )
}

1;

