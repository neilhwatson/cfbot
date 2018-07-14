#!/usr/bin/env perl

=pod

=head1 SYNOPSIS

Test cfbot functions

=cut

use lib '.';
use strict;
use warnings;
use Test::More tests => 3;
require cfbot;

_test_doc_help( 'cfbot.pm' );
_test_topic_lookup( 'Test topic' );
_test_canonify();

#
# Subs
#

# Test help and usage.
sub _test_doc_help {
   my $prog = shift;
   my $help = qx| ./$prog -? |;
   ok( $help =~ m/options:.+/mis,  "[$prog] -h, for usage" );
   return;
}
# Test sub that looks up topics
sub _test_topic_lookup {
   my $keyword = shift;

   subtest "Lookup topic and test for anti-spam" => sub {
      my $topics = cfbot::reply_with_topic( 'self', $keyword );
      is( $topics->[0],
         "This topic is for testing the cfbot. Do not remove.",
         "Testing a topic lookup"
      );
      $topics = cfbot::reply_with_topic( 'self', $keyword );
         ok( ! defined $topics->[0],
            "Does not return test topic the second time"
         );
   };
   return;
}

sub _test_canonify{

   my $string = "this is a 45 *.()string";
   my $result = "this_is_a_45_____string";
   
   print $result;
   print cfbot::canonify('self', $string);
   is( cfbot::canonify('self', $string), $result, "Was string canonified" );
}
