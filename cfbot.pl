#!/usr/bin/perl

use strict;
use warnings;
use Data::Dumper;
use feature 'say';
use Pod::Usage;
use Config::YAML;
use Web::Query;
use HTTP::Tiny;
use Test::More;
use POE

our $VERSION = 0.01;

my ( $c, $topics );

=pod

=head1 SYNOPSIS

Is an IRC chat bot for CFEngine channels on freenode.

=head2 REQUIREMENTS

Also needs POE::Component::SSLify, and POE::Component::Client::DNS.
Known as libbot-basicbot-perl, libpoe-component-sslify-perl, and
libpoe-component-client-dns-perl on Debian.

=head1 AUTHOR

Neil H. Watson, http://watson-wilson.ca, C<< <neil@watson-wilson.ca> >>

=head1 COPYRIGHT

Copyright (C) 2015 Neil H. Watson

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.

=cut

sub _get_cli_args
{
   use Getopt::Long qw/GetOptionsFromArray/;
   use Cwd;

   my $cwd = getcwd();
   # Set default CLI args here. Getopts will override.
   my %arg = (
      home => $cwd,
   );

   my @args = @_;

   GetOptionsFromArray
   (
      \@args,
      \%arg,
      'help|?',
      'version',
      'test',
      'home:s'
   )
   or eval
   {
      usage( 'USAGE' );
      exit 1;
   };
   return \%arg;
}

sub usage
{
   my $msg = shift;
   my $section;
   if ( $msg =~ m/\AEXAMPLES\Z/ )
   {
      $section = $msg;
   }
   else
   {
      $section = "SYNOPSIS";
   }
   pod2usage(
      -verbose  => 99,
      -sections => "$section",
      -msg      => $msg
   );
}

sub load_topics
{
   my %args = @_;
   my %topics;

   open( my $fh, '<', $args{file} ) or warn "Cannot open $args{file}, $!";

   while (<$fh> )
   {
      chomp;
      ( my ( $topic, $description ) ) = m/\A([^=]+)=(.*)\Z/;
      $topics{$topic} = $description;
   }
   close $fh;

   return \%topics;
}

sub lookup_topics
{
   my %args = @_;
   my @found;
   for my $topic ( keys %{ $topics } )
   {
      push @found, "$topic: $topics->{$topic}" if ( $topic =~ m/$args{keyword}/i )
   }

   push @found, "Topic [$args{keyword}] not found" if ( scalar @found < 1 );

   return \@found;
}

sub get_bug
{
   my $bug_number = shift;
   my %return = (
      subject  => "",
      response => "Unexpected error"
   );
   my $url = "$c->{bug_tracker}/$bug_number";

   unless ( $bug_number =~ m/\A\d{1,6}\Z/ )
   {
      $return{response} = "[$bug_number] is not a valid bug number";
   }
   else
   {
      my %responses = (
         200 => $url,
         404 => "Bug $bug_number not found"
      );

      my $client = HTTP::Tiny->new();
      my $response = $client->get( "$c->{bug_tracker}/$bug_number" );
      for my $key (keys %responses)
      {
         $return{response} = $responses{$key} if $response->{status} == $key;
      }

      if ( $response->{status} == 200 )
      {
         my $q = Web::Query->new_from_html( \$response->{content} );
         $return{subject} = $q->find( 'div.subject' )->text;
         $return{subject} =~ s/\A\s+|\s+\Z//g; # trim leading and trailing whitespace
      }
   }
   return \%return;
}
#
# Testing subs
#
sub _run_tests
{
   my %tests = (
      # Name test 't\d\d' to ensure order
      t01 =>
      {
         name => \&_test_doc_help,
         arg  => '',
      },
      t02 =>
      {
         name => \&_test_topic_lookup,
         arg  => "Test topic",
      },
      t03 =>
      {
         name => \&_test_topic_not_found,
         arg  => "xxxxxxx",
      },
      t04 =>
      {
         name => \&_test_bug_exists,
         arg  => {
            bug => '2333',
            subject => "Variables not expanded inside array"
         }
      },
      t05 =>
      {
         name => \&_test_bug_not_found,
         arg  => '999999',
      },
      t06 =>
      {
         name => \&_test_bug_number_invalid,
         arg  => 'xxxxx'
      },
   );

   # Run tests in order
   for my $test ( sort keys %tests )
   {
      $tests{$test}->{name}->( $tests{$test}->{arg} );
   }
   my $number_of_tests = keys %tests;
   done_testing ( $number_of_tests );
}

sub _test_doc_help
{
   my $help = qx/ $0 -? /;
   like( $help, qr/Usage:.*?Requirements/ms,  "[$0] -h, for usage" );
}

# Why test the actual traffic? Why not test the subs that return test from
# queries?
sub _test_topic_lookup
{
   my $keyword = shift;
   my $topics = lookup_topics( keyword => $keyword );

   is( $topics->[0],
      "Test topic: This topic is for testing the cfbot. Do not remove it.",
      "Testing a topic lookup"
   );
}

sub _test_topic_not_found
{
   my $keyword = shift;
   my $topics = lookup_topics( keyword => $keyword );

   is( $topics->[0],
      "Topic [$keyword] not found",
      "Testing an uknown topic lookup"
   );
}

sub _test_bug_exists
{
   my $args = shift;
   my $bug = get_bug( $args->{bug} );

   subtest 'Lookup existing bug' => sub
   {
      is( $bug->{response}, "$c->{bug_tracker}/$args->{bug}", "URL correct?" );
      is( $bug->{subject}, "Variables not expanded inside array", "Subject correct?" );
   }
}

sub _test_bug_not_found
{
   my $bug_number = shift;
   my $bug = get_bug( $bug_number );

   subtest 'Lookup a none existing bug' => sub
   {
      is( $bug->{response}, "Bug $bug_number not found", "Bug not found" );
      is( $bug->{subject}, "", "No subject because bug not found" );
   }
}


sub _test_bug_number_invalid
{
   my $bug_number = shift;
   my $bug = get_bug( $bug_number );

   subtest 'Lookup a bug with an invalid number' => sub
   {
      is( $bug->{response}, "[$bug_number] is not a valid bug number", "Bug number invalid" );
      is( $bug->{subject}, "", "No subject because bug invalid" );
   }
}

#
# Main matter
#

# Process CLI args
my $args = _get_cli_args( @ARGV );

if ( $args->{help} )
{
   usage( 'HELP' );
   exit;
}
elsif ( $args->{version} )
{
   say $VERSION;
   exit;
}

# Load config file
$c = Config::YAML->new( config => "$args->{home}/cfbot.yml" );

# Load topics file
my $topics_file = "$args->{home}/cfbot";
$topics = load_topics( file => $topics_file );

# Run test suite
if ( $args->{test} )
{
   _run_tests;
   exit;
}

# Start the bot
Cfbot->new( %{ $c->{irc} } )->run;

package Cfbot;
use base 'Bot::BasicBot'; 

#
# Subs that override Bot::BasicBot's own subs
#
sub said
{
   my $self = shift;
   my $msg = shift;

   if ( $msg->{body} =~ m/\A!cfbot\s+(.*)\Z/ )
   {
      my $reply = "I recieved your command $1";
      $self->reply( $msg, $reply );
   }
}
