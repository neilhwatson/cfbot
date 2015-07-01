#!/usr/bin/perl

use strict;
use warnings;
use HTTP::Tiny;
use Time::Piece;
use JSON;
use Data::Dumper;
use feature 'say';

my $c = { newer_than => 15 };

git_feed( 
   feed => 'https://api.github.com/repos',
   owner => 'cfengine',
   repo => 'core',
   newer_than => 5000 
);

sub git_feed
{
   my %args = ( newer_than => $c->{newer_than}, @_);
   
   my @events;
   my $client = HTTP::Tiny->new();
   my $response = $client->get( "$args{feed}/$args{owner}/$args{repo}/events" );

   my $j = JSON->new->pretty->allow_nonref;
   my $events = $j->decode( $response->{content} );

   my $l = scalar @{ $events };
   say "events length before splice = $l";
   splice @{ $events }, 2;
   $l = scalar @{ $events };
   say "events length after splice [2] = $l";

   for my $e ( @{ $events } )
   {
      next unless entry_new ( updated => $e->{created_at}, newer_than => $args{newer_than} );

      my $msg;
      if ( $e->{type} eq 'PushEvent' )
      {
         my $message = substr( $e->{payload}{commits}->[0]{message}, 0, 60 );
         $msg = "Push in $args{owner}:$args{repo} by $e->{actor}{login}, $message ..., ".
            "https://github.com/$args{owner}/$args{repo}/commit/$e->{payload}{head}";
      }
      elsif ( $e->{type} eq 'PullRequestEvent' )
      {
         $msg = "Pull request $e->{payload}{action} in $args{owner}:$args{repo} ".
            "by $e->{payload}{pull_request}{user}{login}, ".
            "$e->{payload}{pull_request}{title}, ".
            "$e->{payload}{pull_request}{url}";
      }
      elsif ( $e->{type} eq 'IssuesEvent' )
      {
         $msg = "Issue in $args{owner}:$args{repo} $e->{payload}{action} ".
            "by $e->{payload}{issue}{user}{login}, $e->{payload}{issue}{title}, ".
            "$e->{payload}{issue}{html_url}";
      }

      if ( $msg )
      {
         push @events, $msg;
         say $msg;
      }
   }

   if ( scalar @events > 0 )
   {
      return \@events;
   }
   else
   {
      return 0;
   }
}

sub atom_feed
{
   my %args = ( newer_than => $c->{newer_than}, @_ );
   my @events;

   my $feed = XML::Feed->parse( URI->new( $args{feed} )) or
      die "Feed error with [$args{feed}] ".XML::Feed->errstr;

   for my $e ( $feed->entries )
   {
      if ( entry_new( updated => $e->updated, newer_than => $args{newer_than} ) )
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


