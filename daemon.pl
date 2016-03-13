#!/usr/bin/env perl

use strict;
use warnings;
use Proc::Daemon;
use Cwd;
use Pod::Usage;
use Carp;
use Perl6::Slurp;

=pod

=head1 SYNOPSIS

C<< daemon [-di|--dir <working directory> [-u|--user <user>] [-g|--group <group> [-stat|-stop|-restart] [-d|--debug] >>

This script starts cfbot.pl as a daemon for normal use.

=head1 AUTHOR

Neil H. Watson, http://watson-wilson.ca, C<< <neil@watson-wilson.ca> >>

=head1 LICENSE AND COPYRIGHT

Copyright (C) 2015 Neil H. Watson

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.

=cut

sub _get_cli_args {
   my @args = @_;

   use Getopt::Long qw/GetOptionsFromArray/;
   use Cwd;

   # Set default CLI args here. Getopts will override.
   my %arg = (
      dir => '/home/cfbot/cfbot',
      user => 'cfbot',
      group => 'cfbot',
   );

   GetOptionsFromArray
   (
      \@args,
      \%arg,
      'help|?',
      'version',
      'start',
      'stop',
      'restart',
      'debug',
      'dir:s',
      'user:s',
      'group:s',
   )
   or eval
   {
      usage( 'USAGE' );
      exit 1;
   };

# Protect input.
   unless ( $arg{dir} =~ m|\A[a-z0-9_./-]+\Z|i ) {
      usage( "Tainted dir argument" );
      exit 1;
   }
   return \%arg;
}

sub usage {
   my $msg = shift;
   my $section;
   if ( $msg =~ m/\AEXAMPLES\Z/ )
   {
      $section = $msg;
   }
   else
   {
      $section = "SYNOPSIS";
   }
   pod2usage(
      -verbose  => 99,
      -sections => "$section",
      -msg      => $msg
   );
   return;
}

my $args = _get_cli_args( @ARGV );

if ( $args->{help} ) {
   usage( 'HELP' );
   exit;
}
=pod
elsif ( $args->{version} ) {
   say $VERSION;
   exit;
}
=cut

# Protect input
if ( $args->{user} eq 'root' ) {
   croak "User cannot be root";
}
if ( $args->{group} eq 'root' ) {
   croak "Group cannot be root";
}

#my $args->{dir} = getcwd();
my $pid_file = $args->{dir}."/cfbot.pid";
my $uid = getpwnam( $args->{user} );
my $gid = getgrnam( $args->{group} );
my $exec_command = $args->{dir}."/cfbot.pm";

if ( $args->{debug} ){
   $exec_command .= ' --debug';
}
my $d = Proc::Daemon->new(
   work_dir     => $args->{dir},
   pid_file     => $pid_file,
   exec_command => $exec_command,
   setuid       => $uid,
   setgid       => $gid,
);

my $exit = 0;

if ( $args->{start} ) {
   $exit += start();
}
elsif ( $args->{stop} ) {
   $exit += stop();
}
elsif ( $args->{restart} ) {
   stop();
   $exit += start();
}
else {
   usage( 'USAGE' );
   exit 1;
}

sub start {
   my $pid = $d->Init();
   return kill 0, $pid;
}

sub stop {
   my $pid = slurp $pid_file;
   unlink $pid_file;
   return kill 'TERM', $pid;
} 

sub status {
   my $file = shift;
   
   if ( -e $file ){
      my $pid = slurp $pid_file;
      return kill 0, $pid;
   }
   return 0;
}

# TODO figure out return status
exit 0 if $exit > 0;
exit $exit;
