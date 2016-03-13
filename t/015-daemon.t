#!/usr/bin/env perl

use strict;
use warnings;
use POSIX qw/ WIFEXITED  /;
use Test::More tests => 4;

my $user = getlogin;
my $group = (getpwuid( $< ))[0];

ok( ! WIFEXITED( system( './daemon.pl -u root' ) >> 8 )
   ,'Daemon tool exits when user is root' );
ok( ! WIFEXITED( system( './daemon.pl -g root' ) >> 8 )
   ,'Daemon tool exits when group is root' );
ok( WIFEXITED( system( "./daemon.pl -u $user -g $group --di . --start" ) >> 8)
   ,'Cfbot starts' );
ok( WIFEXITED( system( "./daemon.pl -u $user -g $group --di . --stop" ) >> 8)
   ,'Cfbot stops' );

