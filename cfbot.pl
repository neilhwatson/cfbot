#!/usr/bin/perl

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
use Pod::Usage;
use Test::More tests => 26;
use Time::Piece;
use Web::Query;
use XML::Feed;
use feature 'say';

our $VERSION = 1.0;

# TODO remove $topics
my (
   $topics, $words_of_wisdom, $wisdom_trigger_words, $cfe_function_ref,
   %topic_index, %topic_keyword_index
);

my $hush = 0;

#
# CLI args and config
#
my $cli_arg_ref = _get_cli_args();

# Load config file
my $config_ref = Config::YAML->new( config => "$cli_arg_ref->{config}" );

if ( $cli_arg_ref->{debug} )
{
   $config_ref->{irc}{channels}[0] = '#bottest';
   $config_ref->{irc}{nick}        = 'cfbot_test';
   $config_ref->{wake_interval}    = 5;
   $config_ref->{newer_than}       = 1440;
}

#
# Support subs that you probably will not use.
#

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

# TODO remove?
# Test for words that should not be searched for.
sub _skip_words {
   my $word = shift;
   my @words = ( qw/
      a an the and or e promise is function functions query that on key of
      / );

   warn "_skip_words arg = [$word]" if $cli_arg_ref->{debug};

   for my $next_word ( @words ) { return 1 if $next_word eq lc($word) }
   return 0;
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

# Tests for new records from feeds.
sub time_cmp {
   # Expects newer_than to be in minutes.
   my ( $arg ) = @_;

   $arg->{time} =~ s/Z\Z//g;
   $arg->{time} = Time::Piece->strptime( $arg->{time}, "%Y-%m-%dT%H:%M:%S" );

   my $now  = Time::Piece->gmtime();
   $arg->{newer_than} = $now - $arg->{newer_than} * 60;

   return 1 if ( $arg->{time} > $arg->{newer_than} );
   return;
}

# TODO remove
# Load topics into ram.
sub load_topics
{
   my %args = @_;
   my %topics;

   open( my $fh, '<', $args{file} ) or warn "Cannot open $args{file}, $!";

   while (<$fh> )
   {
      chomp;
      ( my ( $topic, $description ) ) = m/\A([^=]+)=(.*)\Z/;
      $topics{$topic} = $description;
   }
   close $fh;

   return \%topics;
}

# Make index for topics for given keywords
sub index_topics {
   my $topics_file = shift;

   unless ( -f $topics_file and -r $topics_file  ) {
      warn "$topics_file is not readable or plain";
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
            push @{ $topic_keyword_index{$next_keyword} }, $i;
      }
      $i++;
   }
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
            =$config_ref->{cf_docs_url}
               ."/reference-functions-".$next_function.".html";
      }
   }
   return \%function;
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

   $hush = Time::Piece->localtime() + $config_ref->{hush_time} * 60;
   say $response;
   return $response;
}

# Calls a words of wisdom entry
sub say_words_of_wisdom
{
   my $arg_word = shift;
   $arg_word    = 'no' unless defined $arg_word;
   my $message  = q{};

   warn "wow arg_word = [$arg_word]" if $cli_arg_ref->{debug};

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

# TODO Remove
# Search topics file for a given keyword.
sub lookup_topics
{
   my $keyword = shift;

   my @found;
   for my $topic ( keys %{ $topics } )
   {
      push @found, "$topic: $topics->{$topic}" if ( $topic =~ m/$keyword/i )
   }

   push @found, "Topic [$keyword] not found" if ( scalar @found < 1 );

   say $_ foreach ( @found );
   return \@found;
}

# Search msg for keywords and return topics.
sub reply_with_topic {
   my $msg = shift;
   warn "my msg is [$msg]";
   my @replies;

# Count each keyword matching in msg
   my %possible_keyword;
   for my $next_word ( keys %topic_keyword_index ) {
      
      if ( $msg =~ m/\b$next_word\b/i ) {
         $possible_keyword{$next_word}++;
      }
   }

# Find the highest count of keyword matches and show related topics
   my $topic = '';
   my $previous_count = 0;
   for my $next_word  ( keys %possible_keyword ) {

      if ( $possible_keyword{$next_word} > $previous_count ) {
         $topic = $next_word;
      }
      $previous_count = $possible_keyword{$next_word};
   }

   if ( $topic ne '' ) {
      for my $next_topic ( @{ $topic_keyword_index{$topic} } ) {
         push @replies, $topic_index{ $next_topic };
      }
   }

   say $_ foreach  ( @replies );
   return \@replies;
}

sub reply_with_function{
   my $message = shift;
   my $reply = '';

   ( my @functions ) = $message =~ m/(\w*) \s* function \s* (\w*)/msx;

   for my $next_function ( @functions ){

      if ( exists $cfe_function_ref->{$next_function}{description} ) {

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
   my $url = "$config_ref->{bug_tracker}/$bug_number";

   unless ( $bug_number =~ m/\A\d{1,6}\Z/ )
   {
      push @return, "[$bug_number] is not a valid bug number";
   }
   else
   {
      my %responses = (
         200 => $url,
         403 => $url. " Not authorized to read bug $bug_number",
         404 => "Bug [$bug_number] not found",
         500 => "Web server error from $url"
      );

      my $client = HTTP::Tiny->new();
      my $response = $client->get( "$config_ref->{bug_tracker}/$bug_number" );
      for my $key (keys %responses)
      {
         $message = $responses{$key} if $response->{status} == $key;
      }

      if ( $response->{status} == 200 )
      {
         my $q = Web::Query->new_from_html( \$response->{content} );
         $message = $url .' '. $q->find( 'div.subject' )->text;
         $message =~ s/\A\s+|\s+\Z//g; # trim leading and trailing whitespace
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
   my $newer_than = exists $arg->{newer_than} ? $arg->{newer_than} : $config_ref->{newer_than};
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
      elsif ( $e->{type} eq 'PullRequestEvent' )
      {
         $msg = "Pull request $e->{payload}{action} in $owner:$repo ".
            "by $e->{payload}{pull_request}{user}{login}, ".
            "$e->{payload}{pull_request}{title}, ".
            "$e->{payload}{pull_request}{html_url}";
      }
      elsif ( $e->{type} eq 'IssuesEvent' )
      {
         $msg = "Issue in $owner:$repo $e->{payload}{action} ".
            "by $e->{payload}{issue}{user}{login}, $e->{payload}{issue}{title}, ".
            "$e->{payload}{issue}{html_url}";
      }

      if ( $msg )
      {
         push @events, $msg;
         say $msg;
      }
   }

   if ( scalar @events > 0 )
   {
      return \@events;
   }
   else
   {
      return 0;
   }
   return;
}

# Returns recent events from a Redmine atom feed.
sub atom_feed
{
   my ( $arg ) = @_;
   # Set defaults
   my $newer_than = exists $arg->{newer_than}
      ? $arg->{newer_than} : $config_ref->{newer_than};
   my $feed       = $arg->{feed};
   my @events;

   warn "Getting atom feed for [$feed] ".
      "records newer than [$newer_than]min" if $cli_arg_ref->{debug};

   my $xml = XML::Feed->parse( URI->new( $feed )) or
      die "Feed error with [$feed] ".XML::Feed->errstr;

   for my $e ( $xml->entries )
   {
      if ( $e->title =~ m/\A\w+ # Start with any word
         \s+
         \#\d{4,5} # bug number
         \s+
         \( (Open|Closed|Merged|Rejected|Unconfirmed) \) # Status of bug
         /imsx 

         and

         time_cmp({ time => $e->updated, newer_than => $newer_than }) )
      {
         push @events, $e->title .", ". $e->link;
      }
   }
   say $_ foreach ( @events );
   return \@events;
}

#
# TESTING
# New features should have tests to be run with the test suite.
#

# regex data for IRC message matching. We store the data here so that it can be
# tested and also use it in the bot's sub said dispatch table.
# Words of wisdom trigger words
$wisdom_trigger_words = 'wow|wisdom|speak|talk|words\s+of\s+wisdom';
my $prefix = qr/$config_ref->{irc}{nick}:?\s+/i;
my %irc_msg = (
   bug =>
   {
      regex => qr/(?:bug\s+ | \#) (\d{4,5}) /xi,
      input => [
         'bug 2333',
         "!$config_ref->{irc}{nick} bug 2333",
         "$config_ref->{irc}{nick}: bug 2333",
         "!$config_ref->{irc}{nick}: bug 2333",
         "#2333",
      ],
      capture => qr/\A2333\Z/,
   },
   function =>
   {
      regex => qr/(\w* \s* function \s* \w*)/xmsi,
      input  => [
         "!$config_ref->{irc}{nick}: function data_expand",
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
         "$config_ref->{irc}{nick} wow",
         "$config_ref->{irc}{nick} wisdom",
         "$config_ref->{irc}{nick} speak",
         "$config_ref->{irc}{nick} talk",
         "$config_ref->{irc}{nick} words of wisdom",
      ],
      capture => qr/$wisdom_trigger_words/i,
   },
);

#
# TESTING SUBS
#

# Calls testing subs via a dispatch table.
sub _run_tests
{
   # Test suite dispatch table.
   # Name your tests 't\d\d' to ensure order
   my %test = (
      t01 =>
      {
         name => \&_test_doc_help,
         arg  => [ '' ],
      },
      t02 =>
      {
         name => \&_test_topic_lookup,
         arg  => [ 'Test topic' ],
      },
      t04 =>
      {
         name => \&_test_bug_exists,
         arg  => [ '2333' ],
      },
      t05 =>
      {
         name => \&_test_bug_not_found,
         arg  => [ '999999' ],
      },
      t06 =>
      {
         name => \&_test_bug_number_invalid,
         arg  => [ 'xxxxx' ]
      },
      t07 =>
      {
         name => \&_test_function_search_data_expand,
         arg  => [ 'function data_expand' ]
      },
      t08 =>
      {
         name => \&_test_function_search_regcmp,
         arg  => [ 'function regcmp' ]
      },
      t09 =>
      {
         name => \&_test_cfengine_bug_atom_feed,
         arg => [{ 'feed' => "$config_ref->{bug_feed}" => "newer_than", 6000 }]
      },
      t10 =>
      {
         name => \&_test_git_feed,
         arg => [{
            'feed' => $config_ref->{git_feed}, 'owner' => 'cfengine',
            'repo' => 'core', 'newer_than' => '3000'
         }]
      },
      t11 =>
      {
         name => \&_test_words_of_wisdom,
         arg => [ 'wow' ],
      },
      t12 =>
      {
         name => \&_test_hush,
      },
      t13 =>
      {
         name => \&_test_body_regex,
         arg => [ \%irc_msg ]
      },
   );

   # Run tests in order
   for my $next_test ( sort keys %test )
   {
      $test{$next_test}->{name}->( @{ $test{$next_test}->{arg} } );
   }

   done_testing();

   return;
}

# Test help and usage.
sub _test_doc_help
{
   my $help = qx| $0 -? |;
   ok( $help =~ m/options:.+/mis,  "[$0] -h, for usage" );
   return;
}

# Test sub that looks up topics
sub _test_topic_lookup
{
   my $keyword = shift;
   my $topics = reply_with_topic( $keyword );

   is( $topics->[0],
      "This topic is for testing the cfbot. Do not remove.",
      "Testing a topic lookup"
   );
   return;
}

# Test that get_bug sub returns a bug entry.
sub _test_bug_exists
{
   my $bug = shift;
   my $msg = get_bug( $bug );

   subtest 'Lookup existing bug' => sub
   {
      ok( $msg->[0] =~ m|\A$config_ref->{bug_tracker}/$bug|, "URL correct?" );
      ok( $msg->[0] =~ m|Variables not expanded inside array\Z|, "Subject correct?" );
   };
   return;
}

# Test that get_bug sub handle an unkown bug properly.
sub _test_bug_not_found
{
   my $bug = shift;
   my $msg = get_bug( $bug );
   is( $msg->[0], "Bug [$bug] not found", "Bug not found" );
   return;
}

# Test that get_bug sub handles an invalid bug number.
sub _test_bug_number_invalid
{
   my $bug = shift;
   my $msg = get_bug( $bug );
   is( $msg->[0], "[$bug] is not a valid bug number", "Bug number invalid" );
   return;
}

# Test that function search returns a url and a description.
sub _test_function_search_data_expand
{
   my $keyword = shift;
   my $reply = reply_with_function( $keyword );
   subtest "Search for function $keyword" => sub
   {
      ok( $reply =~
         m{
            URL \s+ $config_ref->{cf_docs_url}/reference-functions-\w+\.html
         }mxsi,
         "Function URL"
      );
      ok( $reply =~
         m/Transforms a data container to expand all variable references/,
         "Function summary"
      );
   };
   return;
}
# Test that function search returns a url and a description.
sub _test_function_search_regcmp
{
   my $keyword = shift;
   my $reply = reply_with_function( $keyword );
   subtest "Search functioin $keyword" => sub
   {
      ok( $reply =~
         m{
            URL \s+ $config_ref->{cf_docs_url}/reference-functions-\w+\.html
         }mxsi,
         "Function URL"
      );
      ok( $reply =~ m/Returns whether the/, "Function summary"
      );
   };
   return;
}

# Test that bug feed returns at least one correct entry.
sub _test_cfengine_bug_atom_feed
{
   my ( $arg ) = @_;
   my $events = atom_feed( $arg );
   # e.g. Feature #7346 (Open): string_replace function
   warn $events->[0].
      ' =~ m/\A(Documentation|Cleanup|Bug|Feature) #\d{4,5}.+\Z/i' if $cli_arg_ref->{debug};
   ok( $events->[0] =~ m/\A(Documentation|Cleanup|Bug|Feature) #\d{4,5}.+\Z/i,
      "Was a bug returned?" );
   return;
}

# Test that git feed returns at least one correct entry.
sub _test_git_feed
{
   my ( $arg ) = @_;
   my $events = git_feed( $arg );
   ok( $events->[0] =~ m/\APull|Push/, 'Did an event return?' );
   return;
}

# Test that words of wisdom returns a string.
sub _test_words_of_wisdom
{
   my $random = shift;
   my $wow = say_words_of_wisdom( $random );
   ok( $wow =~ m/\w+/, 'Is a string returned?' );
   return;
}

# Test hushing function
sub _test_hush
{
   my $msg = hush();
   subtest 'hushing' => sub
   {
      ok( $msg =~ m/\S+/, "Hush returns a message" );
      ok( $hush, '$hush is now true' );
   };
   return;
}

# Test regexes used to trigger events from messages in the channel.
sub _test_body_regex
{
   my $irc_msg = shift;

   for my $next_msg ( sort keys %{ $irc_msg } )
   {
      for my $next_input ( @{ $irc_msg{$next_msg}->{input} } )
      {
         subtest 'Testing body matching regexes' => sub
         {

            # Debugging
            if ( $cli_arg_ref->{debug} ) {
               warn "Testing [$next_input] =~ $irc_msg{$next_msg}->{regex}";
            }

            ok( $next_input =~ $irc_msg{$next_msg}->{regex}
               , "Does regex match message body?" );
            warn" ok( $LAST_PAREN_MATCH =~ $irc_msg{$next_msg}->{capture}";
            ok( $LAST_PAREN_MATCH =~ $irc_msg{$next_msg}->{capture}
               , "Is the correct string captured?" );
         }
      }
   }
   return;
}

#
# Main matter
#

# Index topics file
my $topics_file = "$cli_arg_ref->{home}/topics.yml";
index_topics( $topics_file );

# Load words of wisdom
my $wow_file = "$cli_arg_ref->{home}/words_of_wisdom";
$words_of_wisdom = load_words_of_wisdom( file => $wow_file );

# Build index of cfe functions
$cfe_function_ref = index_cfe_functions({
   dir => "$cli_arg_ref->{docs_repo}/reference/functions"
});

if ( $cli_arg_ref->{test} ) { _run_tests(); exit }

# Start the bot
my $bot = Cfbot->new( %{ $config_ref->{irc} } )->run;

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

#
# Packages
#

package Cfbot;
use base 'Bot::BasicBot'; 
use English;
use Data::Dumper;
use POE::Kernel;

# Subs in this package override Bot::BasicBot's own subs.

# Reads channel messages and takes action if messages match regexes.
sub said
{
   my $self = shift;
   my $msg = shift;
   my $replies;

   my $now = Time::Piece->localtime();

   # Be quiet if bot has been hushed.
   return if ( $now < $hush );

   # Be quite if told to hush.
   if ( $msg->{raw_body} =~ m/$prefix (hush|(be\s+)?quiet|shut\s*up|silence) /ix )
   {
      push @{ $replies }, main::hush();
   }

   # Messages that will trigger action.
   my @dispatch = (
      {
         name  => 'bug match',
         regex => $irc_msg{bug}{regex},
         run   => \&main::get_bug,
      },
      {
         name  => 'function search',
         regex => $irc_msg{function}{regex},
         run   => \&main::reply_with_function,
      },
      {
         name  => 'wow',
         regex => $irc_msg{wow}{regex},
         run   => \&main::say_words_of_wisdom,
      },
      # This must be last
      {
         name  => 'topic search',
         regex => qr/(.*)/,
         run   => \&main::reply_with_topic,
      }
   );

   my $arg = 'undef';

   # Process each irc msg agains dispatch table
   for my $next_dispatch ( @dispatch )
   {
      # Debugging
      if ( $cli_arg_ref->{debug} ) {
         warn "Checking dispatch $next_dispatch->{name}";
         warn "$msg->{raw_body} =~ $next_dispatch->{regex}";
      }

      # If irc msg matches one in the dispatch table
      if ( $msg->{raw_body} =~ $next_dispatch->{regex} )
      {
         # Keep captured text from the irc msg
         if ( defined $LAST_PAREN_MATCH )
         {
            $arg = $LAST_PAREN_MATCH;

            # Debugging
            if ( $cli_arg_ref->{debug} ){
               warn "Calling dispatch $next_dispatch->{name}, arg [$arg]";
            }

            # Call sub from disptach table
            $self->forkit({
               run       => $next_dispatch->{run},
               arguments => [ $arg ],
               channel   => $config_ref->{irc}{channels}[0],
            });
            last;
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
   $wake_interval{seconds} = $config_ref->{wake_interval} * 60;
   
   my $now = Time::Piece->localtime();
   return 60 if ( $now < $hush );

   my @events = (
      {
         name => \&main::atom_feed,
         arg  => [{ 'feed' => "$config_ref->{bug_feed}" }]
      },
      {
         name => \&main::git_feed,
         arg  => [{
            'feed'  => $config_ref->{git_feed},
            'owner' => 'cfengine',
            'repo'  => 'core',
         }]
      },
      {
         name => \&main::git_feed,
         arg  => [{
            'feed'  => $config_ref->{git_feed},
            'owner' => 'cfengine',
            'repo'  => 'masterfiles',
         }]
      },
      {
         name => \&main::git_feed,
         arg  => [{
            'feed'  => $config_ref->{git_feed},
            'owner' => 'evolvethinking',
            'repo'  => 'evolve_cfengine_freelib',
         }]
      },
      {
         name => \&main::git_feed,
         arg  => [{
            'feed'  => $config_ref->{git_feed},
            'owner' => 'evolvethinking',
            'repo'  => 'delta_reporting',
         }]
      },
      {
         name => \&main::git_feed,
         arg  => [{
            'feed'  => $config_ref->{git_feed},
            'owner' => 'neilhwatson',
            'repo'  => 'vim_cf3',
         }]
      },
      {
         name => \&main::git_feed,
         arg  => [{
            'feed'  => $config_ref->{git_feed},
            'owner' => 'neilhwatson',
            'repo'  => 'cfbot',
         }]
      },
      {
         name => \&main::say_words_of_wisdom,
         arg  => [ '' ],
      },
      {
         name => \&main::index_cfe_functions,
         arg  => [ '' ],
      },
   );

   for my $e ( @events )
   {
      $self->forkit({
         run       => $e->{name},
         arguments => $e->{arg},
         channel   => $config_ref->{irc}{channels}[0],
      });
   }
   return $wake_interval{seconds};
}

# When someone says help to the bot this sub is run
sub help
{
   my $self = shift;
   $self->forkit({
      run       => \&main::lookup_topics,
      arguments => [ 'help' ],
      channel   => $config_ref->{irc}{channels}[0],
   });
   return;
}

1;
