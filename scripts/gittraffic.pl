#!/usr/bin/perl

use strict;
use warnings;
use HTTP::Tiny;
use Data::Dumper;
use POSIX qw/strftime/;
use Time::Piece;
use JSON;

my $events =  get_new_github_repo_events( 
   owner => 'neilhwatson',
   repo => 'cfbot',
   newer_than => 1800 
);

print Dumper( $events ) if $events;

sub is_newer_than
{
   my %args = (
      newer_than => gmtime,
      date => gmtime,
      @_
   );

   $args{newer_than} =~ s/Z\Z//g;
   $args{date} =~ s/Z\Z//g;
   my $newer_than = Time::Piece->strptime( $args{newer_than}, "%Y-%m-%dT%H:%M:%S" );
   my $date = Time::Piece->strptime( $args{date}, "%Y-%m-%dT%H:%M:%S" );

   return 1 if $date > $newer_than;
   return 0
}

sub get_new_github_repo_events
{
   my %args = (
      newer_than => 15,
      @_
   );
   
   my $github = "https://api.github.com/repos/$args{owner}/$args{repo}/events";

   my $timestamp = strftime "%Y-%m-%dT%H:%M:%SZ", gmtime( time - $args{newer_than}*60) ;

   my ( %events, $id, @sorted_events );
   my $client = HTTP::Tiny->new();
   my $response = $client->get( $github );

   my $j = JSON->new->pretty->allow_nonref;
   my $events = $j->decode( $response->{content} );

   for my $e ( @{ $events } )
   {
      next unless is_newer_than ( date => $e->{created_at}, newer_than => $timestamp );

      my ( $url, $msg );
      if ( $e->{type} eq 'PushEvent' )
      {
         $url = "https://github.com/$args{owner}/$args{repo}/commit/$e->{payload}{head}";
         $msg = "Push in $args{owner}:$args{repo} by $e->{actor}{login}, $url";
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

      $events{$e->{id}} = $msg if $msg;
   }

   for $id ( sort keys %events )
   {
      push @sorted_events, $events{$id}
   }

   if ( scalar @sorted_events > 0 )
   {
      return \@sorted_events;
   }
   else
   {
      return 0;
   }
}
