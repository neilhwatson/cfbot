#!/usr/bin/env perl

=pod

=head1 SYNOPSIS

This is used by the test suite. This bot will talk to cfbot and the
test suite will test for the correct replies.

=cut 

use Carp 'croak';
use strict;
use warnings;

my $bot = cfbot_tester->new(
   server   => 'localhost',
   port     => 6667,
   channels => [ '#bottest' ],
   username => 'cftester',
   name     => 'user to test cfbot',
   nick     => 'cftester',
);

if ( -e 'testing.log' ) {
   unlink 'testing.log' or croak "Cannot remove old log [$!]";
}
$bot->run;

package cfbot_tester;
use Carp;
use base 'Bot::BasicBot';
use strict;
use warnings;

sub log {
	my $self = shift;
	open my $log_fh, '>>', 'testing.log'
      or croak "Cannot open testing.log [$!]";
	for (@_) {
		my $log_entry = $_;
		print $log_fh $log_entry."\n";;
	}
	close $log_fh;
	return;
}

sub said {
   my $self = shift;
   my $msg  = shift;
   $self->log( $msg->{body} );
}

sub tick {
   my $self = shift;
   my @msgs = (
      'help', 
      'Test topic',
      'bug xxxxx','#484', '#999999', 
      'function data_expand',
      'function regcmp',
      'cfbot: hush',
   );

   for my $msg ( @msgs ) {
      $bot->say( body => $msg, channel => '#bottest' );
   }
   return 60;
}

1;
