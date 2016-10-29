#!/usr/bin/env perl

=pod

=head1 SYNOPSIS

Test cfbot CFEngine function lookup.

=cut

use strict;
use warnings;
use Test::More tests => 3;
require cfbot;

my $config = cfbot::_load_config( 'cfbot.yml' );

_test_function_search_data_expand( 'function data_expand' );

_test_function_search_regcmp( 'function regcmp' );

#
# Subs
#

# Test that function search returns a url and a description.
sub _test_function_search_data_expand {
   my $keyword = shift;
   subtest "Search for function $keyword" => sub {
      my $reply = cfbot::reply_with_function( $keyword );
      ok( $reply =~
         m{
            URL \s+ $config->{cf_docs_url}/reference-functions-\w+\.html
         }mxsi,
         "Function URL"
      );
      ok( $reply =~
         m/Transforms a data container to expand all variable references/,
         "Function summary"
      );
   };

   # Now test anti-spam
   my $reply = cfbot::reply_with_function( $keyword );
   is( $reply, '', "Does not return function a second time" );
   return;
}

# Test that function search returns a url and a description.
sub _test_function_search_regcmp {
   my $keyword = shift;
   my $reply = cfbot::reply_with_function( $keyword );
   subtest "Search functioin $keyword" => sub {
      ok( $reply =~
         m{
            URL \s+ $config->{cf_docs_url}/reference-functions-\w+\.html
         }mxsi,
         "Function URL"
      );
      ok( $reply =~ m/Returns whether the/, "Function summary"
      );
   };
   return;
}
