#!/usr/bin/env perl

package cfbot;

use strict;
use warnings;
use Carp;
use Config::YAML;
use YAML qw/ LoadFile /;
use Cwd;
use Data::Dumper;
use English;
use Getopt::Long;
use HTTP::Tiny;
use JSON;
use Cache::FastMmap;
use Pod::Usage;
use Test::More; 
use Time::Piece;
use XML::Feed;
use Mojo::UserAgent;
use Mojo::DOM;
use feature 'say';

our $VERSION = 1.0;

my (
   $words_of_wisdom, $wisdom_trigger_words, $cfe_function_ref,
   %topic_index, $topic_keyword_index,
);

# Data shared between parent and children.
my $keyword_time = Cache::FastMmap->new;

# Words of wisdom trigger words
$wisdom_trigger_words = 'wow|wisdom|speak|talk|words\s+of\s+wisdom';

my $hush = 0;

#
# CLI args and config
#
my $cli_arg_ref = _get_cli_args();

# Load config file
my $config = _load_config( $cli_arg_ref->{config} );

if ( $cli_arg_ref->{debug} )
{
   $config->{irc}{server}      = 'localhost';
   $config->{irc}{channels}    = [ '#bottest' ];
   $config->{irc}{username}    = 'cfbot';
   $config->{irc}{name}        = 'cfbot in debug mode';
   $config->{irc}{nick}        = 'cfbot';
   $config->{irc}{port}        = 6667;
   $config->{irc}{ssl}         = 0;
   $config->{wake_interval}    = 5;
   $config->{newer_than}       = 3500;
}

#
# Support subs that you probably will not use.
#

sub _load_config{
   my $file = shift;
   croak "[$file] does not exist" if ( ! -e $file );

   return Config::YAML->new(
      config => "$cli_arg_ref->{config}" );
}

# Process command line args.
sub _get_cli_args
{
   my $cwd = getcwd();

   # Set default CLI args here. Getopts will override.
   my $cli_arg_ref = {
      home      => $cwd,
      docs_repo => $cwd."/documentation",
      config    => $cwd."/cfbot.yml",
   };

   # Define ways to valid your arguments using anonymous subs or regexes.
   my $valid_arg_ref = {
      home      => {
         constraint => \&_valid_filename_in_cli_args,
         error      => "home arg is invalid",
      },
      docs_repo => {
         constraint => \&_valid_filename_in_cli_args,
         error      => "docs_repo arg is invalid",
      },
      config    => {
         constraint => \&_valid_filename_in_cli_args,
         error      => "config arg is invalid",
      },
   };

   # Read, process, and validate cli args
   GetOptions
   (
      $cli_arg_ref,
      'debug',
      'docs_repo:s',
      'home:s',
      'config:s',
      'test',

      'version'  => sub { say $VERSION; exit                            },
      'man'      => sub { pod2usage( -verbose => 2, -exitval => 0 )     },

      'dumpargs' => sub {
         say '$cli_arg_ref = '. Dumper( $cli_arg_ref ); exit
      },
      'help|?'   => sub {
         pod2usage( -sections => ['OPTIONS'],  -exitval => 0, -verbose => 99)
      },
      'usage'    => sub {
         pod2usage( -sections => ['SYNOPSIS'], -exitval => 0, -verbose => 99)
      },
      'examples' => sub {
         pod2usage( -sections => 'EXAMPLES',   -exitval => 0, -verbose => 99)
      },
   );

   # Futher, more complex cli arg validation
   _validate_cli_args({
         cli_inputs   => $cli_arg_ref,
         valid_inputs => $valid_arg_ref
   });

   return $cli_arg_ref;
}

# Validate select cli args
sub _validate_cli_args {
   my ( $arg )     = @_;
   my $cli         = $arg->{cli_inputs};
   my $valid_input = $arg->{valid_inputs};
   my $errors      = q{};

   # Process cli args and test against the given contraint
   for my $arg ( keys %{ $cli }) {
      if ( defined $valid_input->{$arg} ) {
         my $constraint = $valid_input->{$arg}->{constraint};
         my $error      = $valid_input->{$arg}->{error};
         my $ref        = ref $constraint;

         # Test when constraint is a code reference.
         if ( $ref eq 'CODE' ) {
            $errors
               .= "\n" . $error unless ( ${constraint}->( $cli->{$arg} ) );
         }

         # Test when contraint is a regular expression.
         elsif ( $ref eq 'Regexp' ) {
            $errors .= "\n" . $error unless ( $cli->{$arg} =~ $constraint );
         }
      }
   }

   # Report any invalid cli args 
   pod2usage( -msg => $errors, -exitval => 2 ) if length $errors > 0;

   return 1;
}

# Test file names give via cli args
sub _valid_filename_in_cli_args {
      my $file_name = shift;
      
      unless ( $file_name =~ m|\A[a-z0-9_./-]+\Z|i ) {
         warn "[$file_name] not valid";
         return;
      }
      unless ( _user_owns( $file_name ) ) {
         warn "User must own [$file_name]";
         return;
      }
      unless ( _file_not_gw_writable( $file_name ) ) {
         warn "[$file_name] must not be group or world writable";
         return;
      }

      return 1;
   };


# Test that running user owns a file
sub _user_owns {
   my $file_name = shift;

   return unless -O $file_name;
   return 1;
}

# Test for group or world writable files.
sub _file_not_gw_writable {
   my $file_name = shift;
   my @f         = stat( $file_name )
      or croak "Cannot open file [$file_name]";
   my $mode = $f[2] & oct(777);

   if ( $mode & oct(22) )
   {
      return;
   }
   return 1;
}

# Test if keyword has been recently checked. Used to prevent cfbot from
# spamming the channel. Returns true if keyword has been used recently.
sub recent_keyword {
   my $keyword = shift;
   $keyword = lc $keyword;

   # If keyword was seen less than x minutes ago then do not lookup.
   my $newer_than = 10;
   my $now  = Time::Piece->gmtime();

   my $last_reply = $keyword_time->get( $keyword );
   if ( defined $last_reply ) {

      # Test if too new to send another messege.
      $newer_than = $now - $newer_than * 60;
      return 1 if ( $last_reply > $newer_than );
   }

   # If not defined then start new time
   $keyword_time->set( $keyword, $now );
   return 0;
}

# Tests for new records from feeds.
sub time_cmp {
   # Expects newer_than to be in minutes.
   my ( $arg ) = @_;

   $arg->{time} =~ s/ (?: \.\d{1,3} )? Z\Z//ixg;
   $arg->{time} = Time::Piece->strptime( $arg->{time}, "%Y-%m-%dT%H:%M:%S" );

   if ( $arg->{newer_than} !~ m/\A\d+\Z/ ) {
      warn "Newer_than arg expects a number";
      return;
   }

   my $now  = Time::Piece->gmtime();
   $arg->{newer_than} = $now - $arg->{newer_than} * 60;

   return 1 if ( $arg->{time} > $arg->{newer_than} );
   return;
}

# Make index for topics for given keywords
sub index_topics {
   my $topics_file = shift;
   my %keyword_index;

   unless ( -f $topics_file and -r $topics_file  ) {
      carp "$topics_file is not readable or plain";
      return;
   }

   my $topics_yml = LoadFile( $topics_file )
      or die "Cannot load topics.yml $!";
   my $i = 0;

# Build a fast index for keyword searches
   for my $next_topic ( @{ $topics_yml } ) {

      # Store topic in index.
      $topic_index{$i} = $next_topic->{topic};

      for my $next_keyword ( @{ $next_topic->{keywords} } ) {

            # Store keyworkd in index.
            push @{ $keyword_index{$next_keyword} }, $i;
      }
      $i++;
   }
   return \%keyword_index;
}

# Searched CFEngine function documentation for a given keyword.
sub index_cfe_functions {
   my ( $arg_ref ) = @_;
   my @functions;
   my %function;

   # Check that the source dir is valid.
   my $doc_dir = defined $arg_ref->{dir} ? $arg_ref->{dir} : 'not provided';

   if ($doc_dir eq 'not provided' ){
      warn "Doc_dir [$doc_dir] was not provided";
      return;
   }

   if (
      -d $doc_dir and 
      -r $doc_dir and
      -x $doc_dir
   ){

   # Read dir and collection function names.
      opendir( my $ls_doc_dir, $doc_dir) or die "Cannot read $doc_dir $!";
      while ( my $next_file = readdir($ls_doc_dir) ){
         
         # Get function names from *.markdown files.
         if ( $next_file =~ m/\A(.*?)\.markdown\Z/ ){
            my $function_name = $1;
            push @functions, $function_name;
         }
      }
      closedir $ls_doc_dir;
   }
   else {
      warn "Doc_dir [$doc_dir] is not readable, executable, ".
         "or is not a directory";
      return;
   }

   # Read each function file and get the function description.
   for my $next_function ( @functions ) {

      # Get file contents and skip reading if there's a problem.
      my $file_name = $doc_dir."/".$next_function.".markdown";
      open my $function_file, "<", $file_name or next;
      my $file_contents = do { local $/; <$function_file> };
      close $function_file;

      # Now read contents at get description;
      if ( $file_contents=~ m/
         \Q**Description:**\E \s+ (.*?) # First description paragraph.
         ^\s*$                          # Blank line

         # Optional second paragraph
         (?:
            (.+?)                       # Get next paragraph if it's not
            (?:
               (?: ^\s*$ )              # A blank line
               |
               (?: ^\*\* )              # Begins with **
               |
               (?: ^\Q[%CFEngine\E )    # Beings with [%CFEngine
            )
         )?
         /msx 
      ){
         $function{$next_function}{description} = defined $2 ? $1." ".$2 : $1;
         # remove trailing whitespace
         $function{$next_function}{description} =~ s/\s+$//ms;
         # replace newlines with a space 
         $function{$next_function}{description} =~ s/\n/ /gms;

         $function{$next_function}{url}
            =$config->{cf_docs_url}
               ."/reference-functions-".$next_function.".html";
      }
   }
   return \%function;
}

# Hack to shar with testing and package below
sub _get_prefix {
   return qr/$config->{irc}{nick}:?\s+/i;
}

# regex data for IRC message matching. We store the data here so that it can be
# tested and also use it in the bot's sub said dispatch table.

sub _get_msg_regexes {
   # TODO must share prefix with this sub and bot package below
   my $prefix = _get_prefix();
   my %irc_regex = (
      bug =>
      {
         regex => qr/(?:bug\s+ | \#) (\d{3,5}) /xi,
         input => [
            'bug 484',
            "!$config->{irc}{nick} bug 484",
            "$config->{irc}{nick}: bug 484",
            "!$config->{irc}{nick}: bug 484",
            "#484",
         ],
         capture => qr/\A484\Z/,
      },
      function =>
      {
         regex => qr/(\w* \s* function \s* \w*)/xmsi,
         input  => [
            "!$config->{irc}{nick}: function data_expand",
            "function data_expand",
            "the function data_expand",
            "data_expand function",
            "use the function regcmp",
         ],
         capture => qr/\A
            (?: data_expand \s+ function )
            |
            (?: function \s+ data_expand|regcmp )
         \Z/msxi,
      },
      wow =>
      {
         regex => qr/$prefix ($wisdom_trigger_words) /ix, 
         input => [
            "$config->{irc}{nick} wow",
            "$config->{irc}{nick} wisdom",
            "$config->{irc}{nick} speak",
            "$config->{irc}{nick} talk",
            "$config->{irc}{nick} words of wisdom",
         ],
         capture => qr/$wisdom_trigger_words/i,
      },
   );

   return \%irc_regex;
}

#
# Main subs that can be called by the bot
#

# Controls the hushing of the bot
sub hush
{
   my @responses = (
      "I'll be good.",
      "Hushing",
      "Hrumph",
      qw/>:[ :-( :( :-c :c :-< :< :-[ :[ :{ :-|| :@ >:( :'-( :'(/,
      "Shutting up now.",
      "But, but...",
      "I'll be quiet."
   );

   srand();
   my $response = $responses[ rand @responses ];

   $hush = Time::Piece->localtime() + $config->{hush_time} * 60;
   say $response;
   return $response;
}

# Used for testing the hush flag variable
sub _get_hush{
   return $hush;
}

# Load words of wisdom file into ram.
sub load_words_of_wisdom {
   my %args = @_;
   my @words_of_wisdom;

   open( my $fh, '<', $args{file} ) or warn "Cannot open $args{file}, $!";

   while (<$fh> )
   {
      next if m/\A\s*#/;
      chomp;
      push @words_of_wisdom, $_;
   }
   close $fh;

   return \@words_of_wisdom;
}

# Calls a words of wisdom entry
sub say_words_of_wisdom
{
   my $arg_word = shift;
   $arg_word    = 'no' unless defined $arg_word;
   my $message  = q{};

   # Load words of wisdom
   if ( ! $words_of_wisdom ){
      my $wow_file = "$cli_arg_ref->{home}/words_of_wisdom";
      $words_of_wisdom = load_words_of_wisdom( file => $wow_file );
   }

   srand;
   my $dice_size = 10;
   my $dice_roll = int( rand( $dice_size ));
   $dice_roll    = 0 if $cli_arg_ref->{test};

   # TODO arg_word wow or topic
   if ( $arg_word =~ m/\A$wisdom_trigger_words\Z/ or $dice_roll == 5 ) {
      $message = $words_of_wisdom->[rand @{ $words_of_wisdom }];
   }
   say $message;
   return $message
}

# Search msg for keywords and return topics.
sub reply_with_topic {
   my $msg = shift;
   my @replies;

   # Build topic keyword index if required.
   if ( ! $topic_keyword_index ){
      my $topics_file = "$cli_arg_ref->{home}/topics.yml";
      $topic_keyword_index = index_topics( $topics_file );
   }

   # Count each keyword matching in msg
   my %possible_keyword;
   for my $next_word ( keys %{ $topic_keyword_index } ) {
      
      if ( $msg =~ m/\b$next_word\b/i ) {
         $possible_keyword{$next_word}++;
      }
   }

   # Find the highest count of keyword matches and show related topics
   my $topic = '';
   my $previous_count = 0;
   for my $next_word  ( keys %possible_keyword ) {

      # Exclude word if count is too low or if has been replied to recently.
      if ( $possible_keyword{$next_word} > $previous_count
            and ! recent_keyword( $next_word ) ){
         $topic = $next_word;
      }
      $previous_count = $possible_keyword{$next_word};
   }

   if ( $topic ne '' ) {
      for my $next_topic ( @{ $topic_keyword_index->{$topic} } ) {
         push @replies, $topic_index{ $next_topic };
      }
   }

   say $_ foreach  ( @replies );
   return \@replies;
}

sub reply_with_function{
   my $message = shift;
   my $reply = '';

   # Build index of cfe functions if required.
   if ( ! $cfe_function_ref ){
      $cfe_function_ref = index_cfe_functions({
         dir => "$cli_arg_ref->{docs_repo}/reference/functions"
      });
   }

   ( my @functions ) = $message =~ m/(\w*) \s* function \s* (\w*)/msxi;

   for my $next_function ( @functions ){

      if ( exists $cfe_function_ref->{$next_function}{description} 
         and ! recent_keyword( $next_function ) ) {

         $reply .= <<END_REPLY;
FUNCTION $next_function
$cfe_function_ref->{$next_function}{description}
URL $cfe_function_ref->{$next_function}{url}
END_REPLY
      }
   }
   say $reply if $reply ne '';
   return $reply;
}

# Looks up a CFEngine bug from a given number.
sub get_bug
{
   my $bug_number = shift;
   my @return;
   my $message = "Unexpected error in retreiving bug $bug_number";
   my $url = $config->{bug_tracker_rest}.$bug_number;

   unless ( $bug_number =~ m/\A\d{1,6}\Z/ ) {
      push @return, "[$bug_number] is not a valid bug number";
   }
   else {
      my $ua = Mojo::UserAgent->new();
      my $reply = $ua->get( $url )->res->json;
      if ( $reply->{fields}{summary} ) {
            $message = $config->{bug_tracker}.$bug_number
            .', '
            .$reply->{fields}{summary};
      }
      else {
         $message = "Bug [$bug_number] not found";
      }
   }
   push @return, $message;
   say $_ foreach ( @return );
   return \@return;
}

# Returns recent events from a github repository.
sub git_feed {
   my ( $arg ) = @_;
   # Set defaults
   #                If option given              Use option            Else default
   my $newer_than = exists $arg->{newer_than} ? $arg->{newer_than} : $config->{newer_than};
   my $owner      = $arg->{owner};
   my $repo       = $arg->{repo};
   my $feed       = $arg->{feed};
   
   my @events;
   my $client = HTTP::Tiny->new();
   my $response = $client->get( "$feed/$owner/$repo/events" );

   my $j = JSON->new->pretty->allow_nonref;
   my $events = $j->decode( $response->{content} );

   for my $e ( @{ $events } )
   {
      next unless time_cmp({ time => $e->{created_at}, newer_than => $newer_than });

      my $msg;
      if ( $e->{type} eq 'PushEvent' and $owner !~ m/\Acfengine\Z/i )
      {
         my $message = substr( $e->{payload}{commits}->[0]{message}, 0, 60 );
         $msg = "Push in $owner:$repo by $e->{actor}{login}, $message..., ".
            "https://github.com/$owner/$repo/commit/$e->{payload}{head}";
      }
      elsif ( $e->{type} eq 'PullRequestEvent' ) {
         $msg = "Pull request $e->{payload}{action} in $owner:$repo ".
            "by $e->{payload}{pull_request}{user}{login}, ".
            "$e->{payload}{pull_request}{title}, ".
            "$e->{payload}{pull_request}{html_url}";
      }
      elsif ( $e->{type} eq 'IssuesEvent' ) {
         $msg = "Issue in $owner:$repo $e->{payload}{action} ".
            "by $e->{payload}{issue}{user}{login}, $e->{payload}{issue}{title}, ".
            "$e->{payload}{issue}{html_url}";
      }

      if ( $msg ) {
         push @events, $msg;
         say $msg;
      }
   }

   if ( scalar @events > 0 ) {
      return \@events;
   }
   else {
      return 0;
   }
   return;
}

# Returns recent events from a Redmine atom feed.
sub atom_feed {
   my ( $arg ) = @_;
   # Set defaults
   my $newer_than = exists $arg->{newer_than}
      ? $arg->{newer_than} : $config->{newer_than};
   my $feed       = $arg->{feed};
   my @events;

   my $xml = XML::Feed->parse( URI->new( $feed )) or
      croak "Feed error with [$feed] ".XML::Feed->errstr;

   for my $e ( $xml->entries ) {
      if ( time_cmp({ time => $e->updated, newer_than => $newer_than }) ) {
         my $title = Mojo::DOM->new->parse( $e->title )->all_text;
         push @events, 'Bug feed: '.$title .", ". $e->link;
      }
   }
   say $_ foreach ( @events );
   return \@events;
}

#
# Main matter. Runs as modulino to allow separate testing.
#

sub run{
   my $bot = Cfbot->new( %{ $config->{irc} } )->run;
}

# Start the bot
run() unless caller;

#
# Main POD
#
=pod

=head1 SYNOPSIS

C<< cfbot [-h|--home] <basedire> [-c|--config] [-t|--test] [-do|--docs_repo] <dir> [-de|--debug] [-he|-?|--help] >>
Is an IRC chat bot for CFEngine channels on freenode. Run this
script by hand for testing a hacking. Use the daemon.pl script to
run cfbot.pl is regular service.

=head1 OPTIONS

=over 3

=item

C<< -h <basedir> >> Directory to find configuration file, CFEngine
documentation file, and topic file. Defaults to the current directory.

=item

C<< -c <config file> >> YAML config file, defualts to <basedir>/cfbot.yml.

=item

C<< -do <dir> >> points to an on disk clone of the CFEngine documentation repository
(L<https://github.com/cfengine/documentation>. Defaults to the current directory.

=item

C<< -t|--test >> Run developer test suite.

=item

C<< -de | --debug >> Run in debug mode. This will print more informationa and
return more events from feeds.

=back

=head1 REQUIREMENTS

Also needs POE::Component::SSLify, and POE::Component::Client::DNS.
Known as libbot-basicbot-perl, libpoe-component-sslify-perl, and
libpoe-component-client-dns-perl on Debian.

=head1 HACKING

=over 3

=item

To add new topics, edit the F<cfbot> file using the format of existing entries.

=item

The configuration file is F<cfbot.yml>.

=item

Use the test suite whenever possible. Add new tests with new features.

=item

Generally, bot responses come out of a dispatch table. All such response subs
require the same input and output. A single string for input while output takes
two forms. The first is to send the message or messages to STDOUT in the sub.
The second is to return an array reference containing the output. The former
will go the the IRC channel, the latter is used by the test suite.

=back

=head1 AUTHOR

Neil H. Watson, http://watson-wilson.ca, C<< <neil@watson-wilson.ca> >>

=head1 COPYRIGHT

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

1;

#
# Packages
#

package Cfbot;
use base 'Bot::BasicBot'; 
use English;
use Data::Dumper;
use POE::Session;
use POE::Kernel;

# Subs in this package override Bot::BasicBot's own subs.

# Reads channel messages and takes action if messages match regexes.
sub said
{
   my $self = shift;
   my $msg = shift;
   my $replies;
   my $irc_regex = cfbot::_get_msg_regexes();
   my $prefix = cfbot::_get_prefix();

   my $now = Time::Piece->localtime();

   # Be quiet if bot has been hushed.
   return if ( $now < $hush );

   # Be quite if told to hush.
   if ( $msg->{raw_body}
      =~ m/$prefix (hush|(be\s+)?quiet|shut\s*up|silence) /ix )
   {
      push @{ $replies }, cfbot::hush();
   }

   # Messages that will trigger action.
   my @dispatch = (
      {
         name  => 'bug match',
         regex => $irc_regex->{bug}{regex},
         run   => \&cfbot::get_bug,
      },
      {
         name  => 'function search',
         regex => $irc_regex->{function}{regex},
         run   => \&cfbot::reply_with_function,
      },
      {
         name  => 'wow',
         regex => $irc_regex->{wow}{regex},
         run   => \&cfbot::say_words_of_wisdom,
      },
      # This must be last
      {
         name  => 'topic search',
         regex => qr/(.*)/,
         run   => \&cfbot::reply_with_topic,
      }
   );

   my $arg = 'undef';

   # Process each irc msg agains dispatch table
   DISPATCH: for my $next_dispatch ( @dispatch ) {

      # If irc msg matches one in the dispatch table
      if ( $msg->{raw_body} =~ $next_dispatch->{regex} ) {
         # Keep captured text from the irc msg
         if ( defined $LAST_PAREN_MATCH ) {
            $arg = $LAST_PAREN_MATCH;

            # Call sub from disptach table
            $self->forkit({
               run       => $next_dispatch->{run},
               arguments => [ $arg ],
               channel   => $config->{irc}{channels}[0],
            });
            last DISPATCH;
         }
      }
   }

   # Send a reply if there are any
   $self->reply( $msg, $_ ) foreach ( @{ $replies } );

   return;
}

# Forks any function provided to this sub via arguments. All output from the
# called sub bound for STDOUT will go to the channel.
sub forkit {
# Overriding this one because the original has a bug.
   my ( $self, $arg_ref ) = @_;

   return if !$arg_ref->{run};

   $arg_ref->{handler}   = $arg_ref->{handler}   || "_fork_said";
   $arg_ref->{arguments} = $arg_ref->{arguments} || [];

# Install a new handler in the POE kernel pointing to
# $self->{$args{handler}}
   $poe_kernel->state( $arg_ref->{handler}, $arg_ref->{callback} || $self  );

   my $run;
   if (ref($arg_ref->{run}) =~ /^CODE/) {
     $run = sub {
         # Remove body from args, possible bug in orginal.
         $arg_ref->{run}->( @{ $arg_ref->{arguments} })
     };
   }
   else {
     $run = $arg_ref->{run};
   }
   my $wheel = POE::Wheel::Run->new(
     Program      => $run,
     StdoutFilter => POE::Filter::Line->new(),
     StderrFilter => POE::Filter::Line->new(),
     StdoutEvent  => "$arg_ref->{handler}",
     StderrEvent  => "fork_error",
     CloseEvent   => "fork_close"
   );

# Use a signal handler to reap dead processes
   $poe_kernel->sig_child($wheel->PID, "got_sigchld");

# Store the wheel object in our bot, so we can retrieve/delete easily.
   $self->{forks}{ $wheel->ID } = {
     wheel => $wheel,
     args  => {
         channel => $arg_ref->{channel},
         who     => $arg_ref->{who},
         address => $arg_ref->{address}
     }
   };
   return;
}

# This sub is called automtically by the bot at the interval defined by the
# return statement at the end.
sub tick
{
   my $self=shift;
   my %wake_interval;
   $wake_interval{seconds} = $config->{wake_interval} * 60;
   
   my $now = Time::Piece->localtime();
   return 60 if ( $now < $hush );

   my @events = (
      {
         name => \&cfbot::atom_feed,
         arg  => [{ 'feed' => "$config->{bug_feed}" }]
      },
      {
         name => \&cfbot::git_feed,
         arg  => [{
            'feed'  => $config->{git_feed},
            'owner' => 'cfengine',
            'repo'  => 'core',
         }]
      },
      {
         name => \&cfbot::git_feed,
         arg  => [{
            'feed'  => $config->{git_feed},
            'owner' => 'cfengine',
            'repo'  => 'masterfiles',
         }]
      },
      {
         name => \&cfbot::git_feed,
         arg  => [{
            'feed'  => $config->{git_feed},
            'owner' => 'evolvethinking',
            'repo'  => 'evolve_cfengine_freelib',
         }]
      },
      {
         name => \&cfbot::git_feed,
         arg  => [{
            'feed'  => $config->{git_feed},
            'owner' => 'evolvethinking',
            'repo'  => 'delta_reporting',
         }]
      },
      {
         name => \&cfbot::git_feed,
         arg  => [{
            'feed'  => $config->{git_feed},
            'owner' => 'neilhwatson',
            'repo'  => 'vim_cf3',
         }]
      },
      {
         name => \&cfbot::git_feed,
         arg  => [{
            'feed'  => $config->{git_feed},
            'owner' => 'neilhwatson',
            'repo'  => 'cfbot',
         }]
      },
      {
         name => \&cfbot::say_words_of_wisdom,
         arg  => [ '' ],
      },
      {
         name => \&cfbot::index_cfe_functions,
         arg  => [ '' ],
      },
   );

   # TODO put these as 'notice'
   for my $e ( @events )
   {
      $self->forkit({
         run       => $e->{name},
         arguments => $e->{arg},
         channel   => $config->{irc}{channels}[0],
         handler   => '_fork_notice',
      });
   }
   return $wake_interval{seconds};
}

sub _fork_notice {
    my ($self, $body, $wheel_id) = @_[OBJECT, ARG0, ARG1];
    chomp $body;    # remove newline necessary to move data;

    # pick up the default arguments we squirreled away earlier
    my $args = $self->{forks}{$wheel_id}{args};
    $args->{body} = $body;

    $self->notice($args);
    return;
}

# When someone says help to the bot this sub is run
sub help
{
   my $self = shift;
   $self->forkit({
      run       => \&cfbot::reply_with_topic ,
      arguments => [ 'help' ],
      channel   => $config->{irc}{channels}[0],
   });
   return;
}

1;
