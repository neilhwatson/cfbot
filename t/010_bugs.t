#!/usr/bin/env perl 

=pod

=head1 SYNOPSIS

Test cfbot bug lookup and feed functions

=cut

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
   my $msg = cfbot::get_bug( $bug );

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
   my $msg = cfbot::get_bug( $bug );
   is( $msg->[0], "Bug [$bug] not found", "Bug not found" );
   return;
}

# Test that get_bug sub handles an invalid bug number.
sub _test_bug_number_invalid {
   my $bug = shift;
   my $msg = cfbot::get_bug( $bug );
   is( $msg->[0], "[$bug] is not a valid bug number", "Bug number invalid" );
   return;
}

# Test that bug feed returns at least one correct entry.
sub _test_cfengine_bug_atom_feed {
   my ( $arg ) = @_;
   my $bug_line_regex = qr/
      (commented|Created|Changed|Started) .* CFE-\d{2,5} .+\Z
   /ixms;

   my $events = cfbot::atom_feed({
      feed       => $arg->{feed},
      newer_than => $arg->{newer_than}
   });
   warn "Bug events: ".Dumper( \$events->[0] );
   my $bug = q{Bug feed: Ole Herman Schumacher Elgesem changed the Assignee to 'Ole Herman Schumacher Elgesem' on CFE-953 - Bootstrap to different tcp port};
   if ( $bug =~ $bug_line_regex ){
      warn ">> Match";
   }
   else {
      warn ">> No match";
   }
   
   # e.g. Feature #7346 (Open): string_replace function
   like( $events->[0], $bug_line_regex, "Was a bug returned?" );
   return;
}


