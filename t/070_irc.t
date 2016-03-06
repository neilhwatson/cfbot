#!/usr/bin/env perl

use strict;
use warnings;
use Carp;

my ( $arg ) = @_;
my $cfbot_pid        = fork();
my $cfbot_tester_pid = fork();

# Child 1
if ( $cfbot_pid == 0 ){
   exec( './cfbot.pm --debug' )
      or croak "Cannot start [./cfbot.pm --debug] [$!]";
}
# Child 2
elsif ( $cfbot_tester_pid == 0 ){
   exec( './cfbot_tester.pm' )
      or croak "Cannot start [./cfbot_tester] [$!]";
}
# Parent
else{
   sleep 60;
   kill 1, $cfbot_pid        or croak "Cannot kill pid [$cfbot_pid]";
   kill 1, $cfbot_tester_pid or croak "Cannot kill pid [$cfbot_tester_pid]";
}

# Can't do that?
#waitpid $cfbot_pid, 0;
#waitpid $cfbot_tester_pid, 0;
