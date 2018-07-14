#!/usr/bin/env perl 

=pod

=head1 SYNOPSIS

Test cfbot bug lookup and feed functions

=cut

use lib '.';
use strict;
use warnings;
use Test::More tests => 4;
use Data::Dumper;
require cfbot;

my $config = cfbot::_load_config( 'cfbot.yml' );

_test_bug_exists( 484 );

_test_bug_not_found( 999999 );

_test_bug_number_invalid( 'xxxxx' );

_test_cfengine_bug_atom_feed({
   feed       => $config->{bug_feed},
   newer_than => 8500
});

#
# Subs
#

# Test that get_bug sub returns a bug entry.
sub _test_bug_exists {
   my $bug = shift;
   my $msg = cfbot::get_bug( 'self', $bug );

   subtest 'Lookup existing bug' => sub {
      like( $msg->[0], qr|\Q$config->{bug_tracker}$bug\E|
         , "Bug exists" );
      like( $msg->[0], qr|Variables not expanded inside array|i
         , "Subject correct" );
   };
   return;
}

# Test that get_bug sub handle an unkown bug properly.
sub _test_bug_not_found {
   my $bug = shift;
   my $msg = cfbot::get_bug( 'self', $bug );
   is( $msg->[0], "Bug [$bug] not found", "Bug not found" );
   return;
}

# Test that get_bug sub handles an invalid bug number.
sub _test_bug_number_invalid {
   my $bug = shift;
   my $msg = cfbot::get_bug( 'self', $bug );
   is( $msg->[0], "[$bug] is not a valid bug number", "Bug number invalid" );
   return;
}

# Test that bug feed returns at least one correct entry.
sub _test_cfengine_bug_atom_feed {
   my ( $arg ) = @_;
   my $bug_line_regex = qr/
      \ABug\sfeed: .*? CFE-\d{2,5} .+\Z
   /sixm;

   my $events = cfbot::atom_feed( 'self', {
      feed       => $arg->{feed},
      newer_than => $arg->{newer_than}
   });
   
   # e.g. commented ... CFE-7346 ... string_replace function
   like( $events->[0], $bug_line_regex, "Was a bug returned?" );

   for my $next_event ($events){
      if ( $next_event =~ m/MEN-/ ){
         die "Found MEN bug in bug feed";
      }
   }

   return;
}
