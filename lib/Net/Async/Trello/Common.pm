package Net::Async::Trello::Common;

use strict;
use warnings;

# VERSION

=head2 new

Instantiates.

=cut

sub new {
	my $self = bless { @_[1..$#_] }, $_[0];
	die "no ->trello provided" unless $self->trello;
	$self
}

sub trello { shift->{trello} }

1;

