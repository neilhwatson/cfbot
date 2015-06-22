#!/usr/bin/perl

use strict;
use warnings;
use HTTP::Tiny;
use Data::Dumper;
use JSON;
use POSIX qw/strftime/;
use Time::Piece;
use feature 'say';

my $bugs = get_bug_activity( newer_than => 560 );

if  ( $bugs )
{
   say "notice $target $_"  for( @{ $bugs } ) 
}

sub is_newer
{
   my %args = (
      threshold => 15,
      date => gmtime,
      @_
   );

   $args{date} =~ s/Z\Z//g;
   my $date = Time::Piece->strptime( $args{date}, "%Y-%m-%dT%H:%M:%S" );
   my $now = gmtime;

   my $diff = $now - $date;
   return 1 if int $diff->minutes < $args{threshold};
   return 0
}

sub get_bug_activity
{
   my %args = (
      newer_than => 15,
      @_
   );
   
   my $cf_bug_tracker = 'https://dev.cfengine.com/issues.json?project_id=1';
   my $timestamp = strftime "%Y-%m-%dT%H:%M:%SZ", gmtime( time - $args{newer_than}*60) ;
   my @bugs;

   my $client = HTTP::Tiny->new();
   my $response = $client->get( "$cf_bug_tracker&updated_on=>=$timestamp" );
   my $j = JSON->new->pretty->allow_nonref;
   my $bugs = $j->decode( $response->{content} );

   for my $b ( @{ $bugs->{issues} } )
   {
      my $url = "https://dev.cfengine.com/issues/$b->{id}";
      my ( $prefix, $msg );

      if ( is_newer( date => $b->{created_on}, threshold => $args{newer_than} ) )
      {
         $prefix = "New bug:";
      }
      elsif ( $b->{status} =~ m/\Aclosed|rejected\Z/i )
      {
         $prefix = "closed bug:";
      }
      else
      {
         $prefix = "updated bug:";
      }

      $b->{description} = clean_string( $b->{description} );
      $b->{subject}     = clean_string( $b->{subject} );

      $msg = "$prefix '$b->{subject}' ";
      $msg .= "by $b->{author}{name}. $b->{description}... $url";

      push @bugs, $msg;
   }

   if ( scalar @bugs > 0 )
   {
      return \@bugs;
   }
   else
   {
      return 0;
   }
}

sub clean_string
{
   my $string = shift;

   $string =~ s/\s/ /gms;
   $string =~ s/\\//gms;
   $string =  substr( $string, 0, 100);

   return $string;
}
