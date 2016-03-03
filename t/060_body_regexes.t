#!/usr/bin/env perl

=pod

=head1 SYNOPSIS

Test cfbot mgs body trigger regular expressions.

=cut

use strict;
use warnings;
use English;
use Test::More; # tests => 1;
require cfbot;

my $irc_regex = cfbot::_get_msg_regexes();

_test_body_regex( $irc_msg );

done_testing;

#
# Subs
#

# Test regexes used to trigger events from messages in the channel.
sub _test_body_regex {
   my $irc_msg = shift;

   for my $next_msg ( sort keys %{ $irc_msg } ) {
      for my $next_input ( @{ $irc_msg{$next_msg}->{input} } ) {
         subtest 'Testing body matching regexes' => sub {
            # Debugging
            # warn "Testing [$next_input] =~ $irc_msg{$next_msg}->{regex}";

            ok( $next_input =~ $irc_msg{$next_msg}->{regex}
               , "Does regex match message body?" );
            warn" ok( $LAST_PAREN_MATCH =~ $irc_msg{$next_msg}->{capture}";
            ok( $LAST_PAREN_MATCH =~ $irc_msg{$next_msg}->{capture}
               , "Is the correct string captured?" );
         }
      }
   }
   return;
}
