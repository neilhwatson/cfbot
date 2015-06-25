#!/usr/bin/perl

use strict;
use warnings;
use feature 'say';
use XML::Feed; #libxml-feed-perl
use Data::Dumper;

# TODO github feed needs work.
my @feeds = qw{
   https://dev.cfengine.com/projects/core/activity.atom
   https://github.com/neilhwatson/cfbot/commits/master.atom
};

for my $feed ( @feeds )
{
   my $feed = XML::Feed->parse( URI->new( $feed )) or
      die "Feed error with [$feed] ".XML::Feed->errstr;

   for my $e ( $feed->entries )
   {
      say $e->title;
      say $e->link;
   }
}

