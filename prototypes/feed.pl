#!/usr/bin/perl

use strict;
use warnings;
use feature 'say';
use XML::Feed; #libxml-feed-perl
use Data::Dumper;
use Time::Piece;

my $newer_than = shift;

# https://github.com/neilhwatson/cfbot/commits/master.atom
# TODO github feed needs work.
my $redmine = "https://dev.cfengine.com/projects/core/activity.atom";

redmine_atom_feed ( $redmine );

sub redmine_atom_feed
{
   my @events;
   my $feed = shift;
   $feed = XML::Feed->parse( URI->new( $feed )) or
      die "Feed error with [$feed] ".XML::Feed->errstr;

   for my $e ( $feed->entries )
   {
      if ( entry_new( updated => $e->updated, newer_than => $newer_than ) )
      {
         push @events, $e->title .", ". $e->link;
      }
   }
   say $_ foreach ( @events );
   return \@events;
}

sub entry_new
{
   # Expects newer_than to be in minutes.
   my %args = @_;

   $args{updated} =~ s/Z\Z//g;
   $args{updated} = Time::Piece->strptime( $args{updated}, "%Y-%m-%dT%H:%M:%S" );

   my $now  = Time::Piece->gmtime();
   $args{newer_than} = $now - $args{newer_than} * 60;

   return 1 if (  $args{updated} > $args{newer_than} );
   return 0;
}
