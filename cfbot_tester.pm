#!/usr/bin/env perl

use strict;
use warnings;

my $channel = '#bottest';

my $bot = cfbot_tester->new(
   server   => 'irc.freenode.net',
   port     => 6697,
   ssl      => 1,
   channels => [ $channel ],
   username => 'cfbot_tester',
   name     => 'cfbot_tester',
   nick     => 'cfbot_tester',
);
$bot->run;

package cfbot_tester;
use base 'Bot::BasicBot';


sub tick {
   $bot->say( body => 'help', channel => $channel );
   return 30;
}
