#!/usr/bin/env perl

use lib '.';
use AnyEvent;
use AnyEvent::Util;
use Test::More tests => 12;
use Perl6::Slurp;
use Carp qw/ croak carp/;
use POSIX qw/ WIFEXITED /;
use strict;
use warnings;

=pod

=head1 SYNOPSIS

This program logs cfbot with another test bot in Freenode. The test bot says
things that cfbot should give expected results for. Cfbot's answers are logged
then testes for the right responses.

=cut

#
# Subs
#
sub fork_bot {
   my $arg = shift;
   my $pid;

   my $cv = AnyEvent::Util::run_cmd(
      $arg->{bot},
      '$$' => \$pid,
   ) or croak $!;

   my $w;
   $w = AE::timer(
      $arg->{runtime},
      0,
      sub {
         warn "Killing $arg->{runtime} - timeout\n";
         kill 1, $pid;
         $w = undef;
      }
   );
   $cv;
}

#
# Main matter
#

carp "Starting the bot for testing. This will take some time...";

# The log of the test bot interaction
my $log = 'testing.log';

# Start irc server for testing
my $runtime         = 300;
my $irc_server      = '/usr/sbin/ngircd';
my $server_pid_file = '/tmp/ngircd.pid';

if ( -e $log ) {
   unlink $log or croak "Cannot remove old $log [$!]";
}
unlink $server_pid_file if -e $server_pid_file;
ok( -x $irc_server, "Test irc server exists" );
ok( WIFEXITED( system( "$irc_server -f ./ngircd/ngircd.conf" ) >> 8 )
   , 'IRC server started' );

# Run  cfbot
my $bot1 = fork_bot({ bot => [qw{perl cfbot.pm --test}], runtime => $runtime });
# Run test bot that will chat to cfbot
my $bot2 = fork_bot({ bot => [qw{perl cfbot_tester.pm}], runtime => $runtime });

# Kill bots after child finishes
$bot1->recv;
$bot2->recv;

# Kill server from pid
if ( -e $server_pid_file ) {
   my $server_pid = slurp $server_pid_file;
   kill 'TERM', $server_pid;
}
else {
   carp "Could not kill test irc server ngircd";
}

# Slurp log file for examination
my $chat_log = slurp $log or croak "Cannot open $log, [$!]";

# Tests
like( $chat_log, qr/\n Pull|Push /msx
   ,'Cfbot Github feed' );

like( $chat_log, qr/\nBug feed: \w+ .* https:/ms
   ,'Cfbot bug feed' ); 

like( $chat_log, qr/\nUsing Cfbot: Function lookup: /ms
   ,'Cfbot help topic' );

like( $chat_log, qr/\nThis topic is for testing the cfbot/ms
   ,'Cfbot test topic' );

like( $chat_log, qr{ \n
   \Qhttps://tracker.mender.io/browse/CFE-484\E
   ,\s
   \QVariables not expanded inside array\E
   }msx
   ,'Lookup but 484' );

like( $chat_log, qr/ \n \QBug [99999] not found\E /msx
   ,'Reports when a bug is not found' );

unlike( $chat_log, qr/ \n \QBug [xxxxx]\E /msx
   ,'Does not report on bug xxxxx' );

subtest 'function data_expand' => sub {
   like( $chat_log, qr{ \n \QFUNCTION data_expand\E }mxs
      ,'Returns function name' );
   like( $chat_log, qr{ \n Transforms }mxs
      ,'Returns function blurb' );
   like( $chat_log, qr{ \n URL \s+ 
   \Qhttps://docs.cfengine.com/latest/reference-functions-data_expand.html\E
   }mxs
      , 'Returns function URL' );
};

subtest 'function regcmp' => sub {
   like( $chat_log, qr{ \n \QFUNCTION regcmp\E }mxs
      , 'Returns function name' );
   like( $chat_log, qr{ \n \QReturns whether the\E }mxs 
      , 'Returns function blurb' );
   like( $chat_log, qr{ \n URL \s+
   \Qhttps://docs.cfengine.com/latest/reference-functions-regcmp.html\E }msx
      , 'Returns function URL' );
};

like( $chat_log, qr% \n
   (?:
      \QI'll be good.\E
      | Hushing
      | Hrumph
      | \Q>:[\E | \Q:-(\E | \Q:(\E | \Q:-c\E | \Q:c\E | \Q:-<\E | \Q:<\E
      | \Q:-[\E | \Q:[\E  | \Q:{\E | \Q:-|\E | \Q:@\E | \Q>:(\E | \Q:'-(\E
      | \Q:'(\E
      | \QShutting up now.\E
      | \QBut, but...\E
      | \QI'll be quiet.\E
   )
   %msx,
   'Returned hushing message' );
