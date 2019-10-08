#!/usr/bin/env perl 
use strict;
use warnings;
use feature qw(say);

use IO::Async::Loop;
use Net::Async::Trello;

use JSON::MaybeXS;
# use Log::Any::Adapter qw(Stdout);

binmode STDOUT, ':encoding(UTF-8)';

my ($key, $secret, $token, $token_secret, $search_term) = @ARGV;
die "need oauth app info" unless $key and $secret;
die "need oauth token" unless $token and $token_secret;
die "need a search term" unless $search_term;

my $loop = IO::Async::Loop->new;
$loop->add(
	my $trello = Net::Async::Trello->new(
		key          => $key,
		secret       => $secret,
		token        => $token,
		token_secret => $token_secret,
	)
);

$trello->search(card_fields =>['name','url','dateLastActivity'], query =>$search_term)->
      then(
        sub {
            my (%result) = @_;
            #print the url of the first card returned.
            printf "Card %s url\n", $result{cards}->[0]->url;
            Future->done;
        }
    )->get;




