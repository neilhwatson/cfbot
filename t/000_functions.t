#!/usr/bin/env perl

=pod

=head1 SYNOPSIS

Test cfbot functions

=cut

use lib '.';
use strict;
use warnings;
use Test::More tests => 2;
require cfbot;

_test_doc_help( 'cfbot.pm' );
_test_topic_lookup( 'Test topic' );

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

