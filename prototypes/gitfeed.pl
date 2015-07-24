#!/usr/bin/perl

use strict;
use warnings;
use HTTP::Tiny;
use Time::Piece;
use JSON;
use Data::Dumper;
use feature 'say';

my $config_ref = { newer_than => 15 };

git_feed({ 
   feed => 'https://api.github.com/repos',
   owner => 'cfengine',
   repo => 'core',
   newer_than => 5000 
});

# Returns recent events from a github repository.
sub git_feed {
   my ( $arg ) = @_;
   # Set defaults
   #                If option given              Use option            Else default
   my $newer_than = exists $arg->{newer_than} ? $arg->{newer_than} : $config_ref->{newer_than};
   my $owner      = $arg->{owner};
   my $repo       = $arg->{repo};
   my $feed       = $arg->{feed};
   
   my @events;
   my $client = HTTP::Tiny->new();
   my $response = $client->get( "$feed/$owner/$repo/events" );

   my $j = JSON->new->pretty->allow_nonref;
   my $events = $j->decode( $response->{content} );

   for my $e ( @{ $events } )
   {
      next unless time_cmp({ time => $e->{created_at}, newer_than => $newer_than });

      my $msg;
      if ( $e->{type} eq 'PushEvent' and $owner !~ m/\Acfengine\Z/i )
      {
         my $message = substr( $e->{payload}{commits}->[0]{message}, 0, 60 );
         $msg = "Push in $owner:$repo by $e->{actor}{login}, $message..., ".
            "https://github.com/$owner/$repo/commit/$e->{payload}{head}";
      }
      elsif ( $e->{type} eq 'PullRequestEvent' )
      {
         $msg = "Pull request $e->{payload}{action} in $owner:$repo ".
            "by $e->{payload}{pull_request}{user}{login}, ".
            "$e->{payload}{pull_request}{title}, ".
            "$e->{payload}{pull_request}{html_url}";
      }
      elsif ( $e->{type} eq 'IssuesEvent' )
      {
         $msg = "Issue in $owner:$repo $e->{payload}{action} ".
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
   return;
}


sub atom_feed
{
   my %args = ( newer_than => $config_ref->{newer_than}, @_ );
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

# Tests for new records from feeds.
sub time_cmp {
   # Expects newer_than to be in minutes.
   my ( $arg ) = @_;

   $arg->{time} =~ s/Z\Z//g;
   $arg->{time} = Time::Piece->strptime( $arg->{time}, "%Y-%m-%dT%H:%M:%S" );

   my $now  = Time::Piece->gmtime();
   $arg->{newer_than} = $now - $arg->{newer_than} * 60;

   return 1 if ( $arg->{time} > $arg->{newer_than} );
   return;
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


