#!/usr/bin/env perl

=pod

=head1 SYNOPSIS

Test cfbot git feed.

=cut

use strict;
use warnings;
use Test::More tests => 1;
require cfbot;

my $config = cfbot::_load_config( 'cfbot.yml' );

_test_git_feed({
   'feed' => $config->{git_feed}, 'owner' => 'cfengine',
   'repo' => 'core', 'newer_than' => 15000
});

#
# Subs
#

# Test that git feed returns at least one correct entry.
sub _test_git_feed {
   my ( $arg ) = @_;
   my $events = cfbot::git_feed( $arg );
   ok( $events->[0] =~ m/\APull|Push/, 'Did an event return?' );
   return;
}
