package Net::Async::Trello::Card;

use strict;
use warnings;

# VERSION

use parent qw(Net::Async::Trello::Generated::Card);

use Unicode::UTF8 ();
use Log::Any qw($log);

=head1 NAME

Net::Async::Trello::Card

=head1 DESCRIPTION

Card interaction.

=cut

sub history {
    my ($self, %args) = @_;
    my $trello = $self->trello;
    my $filter = delete $args{filter};
    my $uri = URI->new(
        $trello->base_uri . '/cards/' . $self->id . '/actions?member=false'
    );
    if(ref $filter) {
        $uri->query_param(filter => @$filter)
    } elsif($filter) {
        $uri->query_param(filter => $filter)
    } else {
        $uri->query_param(filter => 'all')
    }
    $uri->query_param($_ => $args{$_}) for keys %args;
    $trello->api_get_list(
        uri   => $uri,
        class => 'Net::Async::Trello::CardAction',
        extra => {
            card => $self
        }
    )
}

sub update {
    my ($self, %args) = @_;
    my $trello = $self->trello;
    $trello->http_put(
        uri => URI->new(
            $trello->base_uri . 'cards/' . $self->id
        ),
        body => \%args
    )
}

=head2 add_comment

Helper method to add a comment to a card as the current user.

Takes a single C<$comment> parameter, this should be the text to add (in
standard Trello Markdown format).

=cut

sub add_comment {
    my ($self, $comment) = @_;
    my $trello = $self->trello;
    $trello->http_post(
        uri => URI->new(
            $trello->base_uri . 'cards/' . $self->id . '/actions/comments?text=' . Unicode::UTF8::encode_utf8($comment)
        ),
        body => { }
    )
}

1;

=head1 AUTHOR

Tom Molesworth <TEAM@cpan.org> with contributions from C<@felipe-binary>

=head1 LICENSE

Copyright Tom Molesworth 2014-2020. Licensed under the same terms as Perl itself.
