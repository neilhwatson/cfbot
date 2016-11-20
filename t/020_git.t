#!/usr/bin/env perl

=pod

=head1 SYNOPSIS

Test cfbot git feed.

=cut

use Test::More tests => 5;
use File::Fetch;
use Digest::file qw{ digest_file_hex };
use Data::Dumper;
require cfbot;
use strict;
use warnings;

my $config = cfbot::_load_config( 'cfbot.yml' );

test_git_feed({
   feed => $config->{git_feed}, 'owner' => 'cfengine',
   repo => 'core', 'newer_than' => 15000
});

#
# Test documentation creation, updates, and recovery
#
# No repo
rmdir 'documentation';
# Clone or update repo
cfbot::git_repo( 'self', {
   repo_url => $config->{documentation},
   dir      => 'documentation',
});
test_git_repository({
   name => 'No repo exists',
   file => 'README.md',
   url  => 'http://raw.githubusercontent.com/cfengine/documentation/master/',
   dir  => 'documentation',
});

# Missing file
unlink 'documentation/README.md';
# Clone or update repo
cfbot::git_repo( 'self', {
   repo_url => $config->{documentation},
   dir      => 'documentation',
});
test_git_repository({
   name => 'Repo is missing a file',
   file => 'README.md',
   url  => 'http://raw.githubusercontent.com/cfengine/documentation/master/',
   dir  => 'documentation',
});

# Missing .git
rmdir 'documentation/.git';
# Clone or update repo
cfbot::git_repo( 'self', {
   repo_url => $config->{documentation},
   dir      => 'documentation',
});
test_git_repository({
   name => 'Repo is missing .git',
   file => 'README.md',
   url  => 'http://raw.githubusercontent.com/cfengine/documentation/master/',
   dir  => 'documentation',
});

# Working dir is a file
rmdir 'documentation';
system( 'touch documentation' );
# Clone or update repo
cfbot::git_repo( 'self', {
   repo_url => $config->{documentation},
   dir      => 'documentation',
});
test_git_repository({
   name => 'Repo is a file',
   file => 'README.md',
   url  => 'http://raw.githubusercontent.com/cfengine/documentation/master/',
   dir  => 'documentation',
});


#
# Subs
#

# Test that git feed returns at least one correct entry.
sub test_git_feed {
   my ( $arg ) = @_;
   my $events = cfbot::git_feed( 'self', $arg );
   ok( $events->[0] =~ m/\APull|Push/, 'Did an event return?' );
   return;
}

sub test_git_repository {
   my ( $arg ) = @_;

   # Clean up downloaded file
   unlink( "/tmp/$arg->{file}" );

   # Downlaod file
   my $ff = File::Fetch->new( uri => "$arg->{url}/$arg->{file}" );
   $ff->fetch( to  => '/tmp' ) or die "$!, $ff->error";

   # Get hashes of downloaded file and repo file
   my $test_digest = digest_file_hex( '/tmp/'.$arg->{file}, 'MD5' );
   my $repo_digest = digest_file_hex( $arg->{dir}.'/'.$arg->{file}, 'MD5' );

   is( $test_digest, $repo_digest, $arg->{name} );

   # Clean up downloaded file
   unlink( "/tmp/$arg->{file}" );
}




