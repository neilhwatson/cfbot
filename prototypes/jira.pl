#!/usr/bin/env perl

use strict;
use warnings;
use feature 'say';
use Data::Dumper;
use Mojo::UserAgent;
use Mojo::DOM;
use XML::Feed;

my $ua = Mojo::UserAgent->new;
my $url;
my $reply;

#
# Return bug
# 
say '# Return bug summary';
$url = 'https://tracker.mender.io/rest/api/2/issue/CFE-2323';

# Get as JSON
$reply = $ua->get( $url )->res->json;

# Get summary
my $summary = $reply->{fields}{summary};
say $summary;

exit;
#
# Return error on non existent bug
#
say '# non existent bug';
$url = 'https://tracker.mender.io/rest/api/2/issue/CFE-99999';

# Get as JSON
$reply = $ua->get( $url )->res->json;

if ( $reply->{errorMessages} ){
   say $reply->{errorMessages}[0];
   say "Bug 99999 does not exist";
}

#
# Feed
#
say '# FEED';
$url = 'https://tracker.mender.io/activity';

=begin
$reply = $ua->get( $url )->res->body;
my $dom = Mojo::DOM->new->parse( $reply );
say 'reply'.Dumper( $dom );
=cut

my $xml = XML::Feed->parse( URI->new( $url ));

for my $e ( $xml->entries ){

   say 'raw title '  .$e->title;
   my $title = Mojo::DOM->new->parse( $e->title )->all_text;
   say 'title '  .$title;
   say 'updated '.$e->updated;
   say 'link '   .$e->link;
}

