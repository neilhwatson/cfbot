#!/usr/bin/env perl

=pod

=head1 SYNOPSIS

Test cfbot CFEngine words of wisdom.

=cut

use lib '.';
use strict;
use warnings;
use Test::More tests => 1;
require cfbot;

my $config = cfbot::_load_config( 'cfbot.yml' );

_test_words_of_wisdom( 'wow' );

#
# Subs
#

# Test that words of wisdom returns a string.
sub _test_words_of_wisdom {
   my $random = shift;
   my $wow = cfbot::say_words_of_wisdom( 'self', $random );
   ok( $wow =~ m/\w+/, 'Is a string returned?' );
   return;
}


