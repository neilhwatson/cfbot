#!/usr/bin/env perl

=pod

=head1 SYNOPSIS

Test cfbot mgs body trigger regular expressions.

=cut

use lib '.';
use strict;
use warnings;
use English;
use Test::More; # tests => 1;
require cfbot;

my $irc_regex = cfbot::_get_msg_regexes();

_test_body_regex( $irc_regex );

done_testing;

#
# Subs
#

# Test regexes used to trigger events from messages in the channel.
sub _test_body_regex {
   my $irc_regex = shift;

   for my $next_msg ( sort keys %{ $irc_regex } ) {
      for my $next_input ( @{ $irc_regex->{$next_msg}->{input} } ) {
         subtest "Testing body matching regexes for [$next_msg]" => sub {

            # warn "Input test: [$next_input]";
            ok( $next_input =~ $irc_regex->{$next_msg}->{regex}
               , "Does regex match message body?" );

             #warn "captured [$LAST_PAREN_MATCH]";

            ok( $LAST_PAREN_MATCH =~ $irc_regex->{$next_msg}->{capture}
               , "Is the correct string captured? "
               ."Expecting [$irc_regex->{$next_msg}->{capture}]" );
         }
      }
   }
   return;
}
