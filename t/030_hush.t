#!/usr/bin/env perl

=pod

=head1 SYNOPSIS

Test cfbot hush feature.

=cut

use strict;
use warnings;
use Test::More tests => 2;
require cfbot;

_test_hush();

#
# Subs
#

# Test hushing function
sub _test_hush {
   ok( ! cfbot::_get_hush(), '$hush is false' );

   my $msg = cfbot::hush();
   subtest 'hushing' => sub {
      ok( $msg =~ m/\S+/      , 'Hush returns a message' );
      ok( cfbot::_get_hush()  , '$hush is now true' );
   };
   return;
}
