#!/usr/bin/perl

use strict;
use warnings;
use English;
use Data::Dumper;
use feature 'say';
use Pod::Usage;
use Config::YAML;
use Web::Query;
use HTTP::Tiny;
use Test::More;
use Time::Piece;
use XML::Feed;
use JSON;

our $VERSION = 1.0;

my ( $c, $topics, $args, $words_of_wisdom, $wow_words );
my $hush = 0;

=pod

=head1 SYNOPSIS

C<< cfbot [-h|--home] <basedire> [-t|--test] [-do|--docs_repo] <dir> [-de|--debug] [-he|-?|--help] >>
Is an IRC chat bot for CFEngine channels on freenode. Run this
script by hand for testing a hacking. Use the daemon.pl script to
run cfbot.pl is regular service.

=head2 OPTIONS

=over 3

=item

C<< -h <basedir> >> Directory to find configuration file, CFEngine
documentation file, and topic file. Defaults to the current directory.

=item

C<< -do <dir> >> points to an on disk clone of the CFEngine documentation repository
(L<https://github.com/cfengine/documentation>. Defaults to the current directory.

=item

C<< -t|--test >> Run developer test suite.

=item

C<< -de | --debug >> Run in debug mode. This will print more informationa and
return more events from feeds.

=back

=head2 REQUIREMENTS

Also needs POE::Component::SSLify, and POE::Component::Client::DNS.
Known as libbot-basicbot-perl, libpoe-component-sslify-perl, and
libpoe-component-client-dns-perl on Debian.

=head2 HACKING

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
# CLI args and config
#
$args = _get_cli_args( @ARGV );

# Load config file
$c = Config::YAML->new( config => "$args->{home}/cfbot.yml" );

if ( $args->{debug} )
{
   $c->{irc}{channels}[0] = '#bottest';
   $c->{irc}{nick}        = 'cfbot_test';
   $c->{wake_interval}    = 5;
   $c->{newer_than}       = 1440;
}

=head2 SUPPORT SUBS
Support subs that you probably will not use.

=head3 _get_cli_args
Process command line args.
=cut
sub _get_cli_args
{
   my @args = @_;

   use Getopt::Long qw/GetOptionsFromArray/;
   use Cwd;

   my $cwd = getcwd();
   # Set default CLI args here. Getopts will override.
   my %arg = (
      home => $cwd,
      docs_repo => $cwd."/documentation",
   );

   GetOptionsFromArray
   (
      \@args,
      \%arg,
      'help|?',
      'version',
      'test',
      'debug',
      'docs_repo:s',
      'home:s',
   )
   or do
   {
      usage( 'USAGE' );
      exit 1;
   };

# Protect input.
   for my $a ( qw/ home docs_repo / )
   {
      unless ( $arg{$a} =~ m|\A[a-z0-9_./-]+\Z|i )
      {
         usage( "Tainted $a argument. Expecting safely named directories." );
         exit 2;
      }
   }

   for my $file ( "$arg{home}/.", "$arg{docs_repo}/.", "$arg{home}/cfbot.yml" )
   {
     unless ( -O $file )
     {
        usage( "[$file] must be owned by running user" );
        exit 3;
     }
     unless ( _test_for_writable( $file ) )
     {
        usage( "File [$file] must not be group or world writable" );
        exit 4;
     }
   }
   return \%arg;
}

=head3 _test_for_writable
Test for group or world writable files.
=cut
sub _test_for_writable
{
   my $file = shift;
   my @f    = stat( $file ) or croak "Cannot open file [$file]";
   my $mode = $f[2] & oct(777);

   if ( $mode & oct(22) )
   {
      return;
   }
   return 1;
}

=head3 usage
Print usage message.
=cut
sub usage
{
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

=head3 _skip_words
Test for words that should not be searched for.
=cut
sub _skip_words
{
   my $word = shift;
   my @words = ( qw/ a an the and or e promise is / );

   warn "_skip_words arg = [$word]" if $args->{debug};

   foreach ( @words ) { return 1 if lc($word) eq $_ }
   return 0;
}

=head3 load_words_of_wisdom
Load words of wisdom file into ram.
=cut
sub load_words_of_wisdom
{
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

=head3 time_tmp
Tests for new records from feeds.
=cut
sub time_cmp
{
   # Expects newer_than to be in minutes.
   my ( $arg ) = @_;

   $arg->{time} =~ s/Z\Z//g;
   $arg->{time} = Time::Piece->strptime( $arg->{time}, "%Y-%m-%dT%H:%M:%S" );

   my $now  = Time::Piece->gmtime();
   $arg->{newer_than} = $now - $arg->{newer_than} * 60;

   return 1 if ( $arg->{time} > $arg->{newer_than} );
   return;
}

=head3 load_topics
Load topics into ram.
=cut
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

   say 'Topics: '. Dumper( \%topics ) if $args->{debug};

   return \%topics;
}

=head2 MAIN SUBS
Main subs that can be called by the bot

=head3 hush
Controls the hushing of the bot
=cut
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

   $hush = Time::Piece->localtime() + $c->{hush_time} * 60;
   say $response;
   return $response;
}

=head3 words_of_wisdom
Calls a words of wisdom entry
=cut
sub words_of_wisdom
{
   my $random = shift;
   $random = 'no' unless defined $random;

   my $wow = '';

   warn "wow random = [$random]" if $args->{debug};
   ;
   srand;
   my $d = int( rand( 6 ));
   $d = 0 if $args->{test};

   # TODO random wow or topic
   if ( $random =~ m/\A$wow_words\Z/ or $d == 5 )
   {
      $wow = $words_of_wisdom->[rand @{ $words_of_wisdom }];
   }
   say $wow;
   return $wow
}

=head3 lookup_topics
Search topics file for a given keyword.
=cut
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

=head3 find_matchs
Searched CFEngine function documentation for a  given keyword.
=cut
sub find_matches
{
   my $word = shift;
   say "word [$word]" if $args->{debug};
   return ([]) if _skip_words( $word );

   my $documentation_checkout = $args->{docs_repo};
   unless (chdir $documentation_checkout)
   {
       warn "Couldn't change into '$documentation_checkout': $!";
       return;
   }

   my $matches = `/usr/bin/git grep '$word' | /bin/grep 'reference/functions/'`;

   my @matches = map { { data => $_ } } split "\n", $matches;

   my %seen;

   my @processed_matches;
   foreach my $match (@matches)
   {
    my ($location, $data) = split ':', $match->{data}, 2;
    next if exists $seen{$location};

    my $published = 0;

    $match->{url} = "[URL unknown]";
    $match->{summary} = "[Summary not found]";

    warn "Opening file at $location" if $args->{debug};
    open my $refd, '<', $location or warn "Couldn't open $location: $!";
    my @lines = <$refd>;
    close $refd or warn "Couldn't close $location: $!";;

    readdesc: for (@lines)
    {
     chomp;
     if (m/^title:\s+(.+)/)
     {
      my $title = $1;
      $title =~ s/[]|"[]//g;
      $match->{url} = "$c->{cf_docs_url}/reference-functions-$title.html";
     }
     elsif ($match->{summary} && m/^.+History:\W+\s+(.+)/)
     {
      $match->{summary} .= " ($1)";
     }
     elsif (m/^published: true/)
     {
      $published = 1;
     }
     elsif (m/^.+Description:\W+\s+(.+)/)
     {
         $match->{summary} = $1;
         for (@lines) 
         {
             chomp;
             next readdesc unless m/.+/;
             $match->{summary} .= ' ' . $_;
         }
     }
    }

    next unless $published;
    $seen{$location}++;
    push @processed_matches, "$match->{url} $match->{summary}";
   }

   if ( scalar @processed_matches < $c->{max_records} )
   {
      say $_ foreach ( @processed_matches);
      return \@processed_matches;
   }

   my $count = scalar @processed_matches;
   splice @processed_matches, $c->{max_records} - 1;
   push @processed_matches, "... $count matches found, but only showing $c->{max_records} matches";

   say $_ foreach ( @processed_matches);
   return \@processed_matches;
}

=head3 get_bug
Looks up a CFEngine bug from a given number.
=cut
sub get_bug
{
   my $bug_number = shift;
   my @return;
   my $message = "Unexpected error in retreiving bug $bug_number";
   my $url = "$c->{bug_tracker}/$bug_number";

   unless ( $bug_number =~ m/\A\d{1,6}\Z/ )
   {
      push @return, "[$bug_number] is not a valid bug number";
   }
   else
   {
      my %responses = (
         200 => $url,
         404 => "Bug [$bug_number] not found",
         500 => "Web server error from $url"
      );

      my $client = HTTP::Tiny->new();
      my $response = $client->get( "$c->{bug_tracker}/$bug_number" );
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

=head3 git_feed
Returns recent events from a github repository.
=cut
sub git_feed
{
   my ( $arg ) = @_;
   # Set defaults
   #                If option given              Use option            Else default
   my $newer_than = exists $arg->{newer_than} ? $arg->{newer_than} : $c->{newer_than};
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
            "$e->{payload}{pull_request}{url}";
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

=head3 atom_feed
Returns recent events from a Redmine atom feed.
=cut
sub atom_feed
{
   my ( $arg ) = @_;
   # Set defaults
   #                If option given              Use option            Else default
   my $newer_than = exists $arg->{newer_than} ? $arg->{newer_than} : $c->{newer_than};
   my $feed       = $arg->{feed};
   my @events;

   warn "Getting atom feed for [$feed] ".
      "records newer than [$newer_than]min" if $args->{debug};

   my $xml = XML::Feed->parse( URI->new( $feed )) or
      die "Feed error with [$feed] ".XML::Feed->errstr;

   for my $e ( $xml->entries )
   {
      warn "Got bug title [$e->{title}]" if $args->{debug};

      if ( $e->title =~ m/\A\w+ # Start with any word
         \s+
         \#\d{4,5} # bug number
         \s+
         \( (Open|Closed|Merged|Rejected|Unconfirmed) \) # Status of bug
         /ix 

         and

         time_cmp({ time => $e->updated, newer_than => $newer_than }) )
      {
         push @events, $e->title .", ". $e->link;
      }
   }
   say $_ foreach ( @events );
   return \@events;
}


=head2 TESTING

New features should have tests to be run with the test suite.

=cut

# regex data for IRC message matching. We store the data here so that it can be
# tested and also use it in the bot's sub said dispatch table.

# Words of wisdom trigger words
$wow_words = 'wow|wisdom|speak|talk|words\s+of\s+wisdom';
my $prefix = qr/$c->{irc}{nick}:?\s+/i;
my %regex = (
   bug =>
   {
      regex => qr/(?:bug\s+ | \#) (\d{4,5}) /xi,
      input => [
         'bug 2333',
         "!$c->{irc}{nick} bug 2333",
         "$c->{irc}{nick}: bug 2333",
         "!$c->{irc}{nick}: bug 2333",
         "#2333",
      ],
      capture => qr/\A2333\Z/,
   },
   search =>
   {
      regex => qr/(?: (?:search|function) \s+ (\w+)) /xi,
      input  => [
         "!$c->{irc}{nick} search data_expand",
         "$c->{irc}{nick}: search data_expand",
         "!$c->{irc}{nick}: function data_expand",
         "function data_expand",
         "the function data_expand",
      ],
      capture => qr/\Adata_expand\Z/,
   },
   topic =>
   {
         regex => qr/$prefix topic \s+ (\w+) /ix,
         input => [
         "!$c->{irc}{nick} topic efl",
         "$c->{irc}{nick}: topic efl",
         "!$c->{irc}{nick}: topic efl",
         "!$c->{irc}{nick}: topic delta",
      ],
      capture => qr/\A (efl|delta) \Z/ix,
   },
   wow =>
   {
      regex => qr/$prefix ($wow_words) /ix, 
      input => [
         "$c->{irc}{nick} wow",
         "$c->{irc}{nick} wisdom",
         "$c->{irc}{nick} speak",
         "$c->{irc}{nick} talk",
         "$c->{irc}{nick} words of wisdom",
      ],
      capture => qr/$wow_words/i,
   },
);

=head2 TESTING SUBS

=head3 _run_tests
Calls testing subs via a dispatch table.
=cut
sub _run_tests
{
   # Test suite dispatch table.
   # Name your tests 't\d\d' to ensure order
   my %tests = (
      t01 =>
      {
         name => \&_test_doc_help,
         arg  => [ '' ],
      },
      t02 =>
      {
         name => \&_test_topic_lookup,
         arg  => [ 'Test' ],
      },
      t03 =>
      {
         name => \&_test_topic_not_found,
         arg  => [ 'xxxxxxx' ],
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
         name => \&_test_function_search,
         arg  => [ 'data_expand' ]
      },
      t08 =>
      {
         name => \&_test_function_search_limit,
         arg  => [ 'files' ]
      },
      t09 =>
      {
         name => \&_test_cfengine_bug_atom_feed,
         arg => [{ 'feed' => "$c->{bug_feed}" => "newer_than", 6000 }]
      },
      t10 =>
      {
         name => \&_test_git_feed,
         arg => [{
            'feed' => $c->{git_feed}, 'owner' => 'cfengine',
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
         arg => [ \%regex ]
      },
   );

   # Run tests in order
   for my $test ( sort keys %tests )
   {
      $tests{$test}->{name}->( @{ $tests{$test}->{arg} } );
   }
   my $number_of_tests = keys %tests;
   done_testing ( $number_of_tests );
   return;
}

=head3 _test_doc_help
Test help and usage.
=cut
sub _test_doc_help
{
   my $help = qx| $0 -? |;
   ok( $help =~ m/Usage:.*?Requirements/ms,  "[$0] -h, for usage" );
   return;
}

=head3 _test_topic_lookup
Test sub that looks up topics
=cut
sub _test_topic_lookup
{
   my $keyword = shift;
   my $topics = lookup_topics( $keyword );

   is( $topics->[0],
      "Test topic: This topic is for testing the cfbot. Do not remove.",
      "Testing a topic lookup"
   );
   return;
}

=head3 _test_topic_not_found
Test topic lookup sub when topic is not found.
=cut
sub _test_topic_not_found
{
   my $keyword = shift;
   my $topics = lookup_topics( $keyword );

   is( $topics->[0],
      "Topic [$keyword] not found",
      "Testing an uknown topic lookup"
   );
   return;
}

=head3 _test_bug_exists
Test that get_bug sub returns a bug entry.
=cut
sub _test_bug_exists
{
   my $bug = shift;
   my $msg = get_bug( $bug );

   subtest 'Lookup existing bug' => sub
   {
      ok( $msg->[0] =~ m|\A$c->{bug_tracker}/$bug|, "URL correct?" );
      ok( $msg->[0] =~ m|Variables not expanded inside array\Z|, "Subject correct?" );
   };
   return;
}

=head3 _test_bug_not_found
Test that get_bug sub handle an unkown bug properly.
=cut
sub _test_bug_not_found
{
   my $bug = shift;
   my $msg = get_bug( $bug );
   is( $msg->[0], "Bug [$bug] not found", "Bug not found" );
   return;
}

=head3 _test_bug_number_invalid
Test that get_bug sub handles an invalid bug number.
=cut
sub _test_bug_number_invalid
{
   my $bug = shift;
   my $msg = get_bug( $bug );
   is( $msg->[0], "[$bug] is not a valid bug number", "Bug number invalid" );
   return;
}

=head3 _test_function_search
Test that fucntion search returns a url and a description.
=cut
sub _test_function_search
{
   my $keyword = shift;
   my $matches = find_matches( $keyword );
   subtest 'Search CFEngine documentation' => sub
   {
      ok( $matches->[0] =~
         m|\A$c->{cf_docs_url}/reference-functions-$keyword.html|,
         "Function URL"
      );
      ok( $matches->[0] =~
         m/Transforms a data container to expand all variable references/,
         "Function summary"
      );
   };
   return;
}

=head3 _test_function_search_limit
Test that fucntion search returns a limited number of entries.
=cut
sub _test_function_search_limit
{
   my $keyword = shift;
   my $matches = find_matches( $keyword );
   ok( scalar @{ $matches } <= $c->{max_records}, "Limit number of returned records" );
   return;
}
 
=head3 _test_cfengine_bug_atom_feed
Test that bug feed returns at least one correct entry.
=cut
sub _test_cfengine_bug_atom_feed
{
   my ( $arg ) = @_;
   my $events = atom_feed( $arg );
   # e.g. Feature #7346 (Open): string_replace function
   warn $events->[0].
      ' =~ m/\A(Documentation|Cleanup|Bug|Feature) #\d{4,5}.+\Z/i' if $args->{debug};
   ok( $events->[0] =~ m/\A(Documentation|Cleanup|Bug|Feature) #\d{4,5}.+\Z/i,
      "Was a bug returned?" );
   return;
}

=head3 _test_git_feed
Test that git feed returns at least one correct entry.
=cut
sub _test_git_feed
{
   my ( $arg ) = @_;
   my $events = git_feed( $arg );
   ok( $events->[0] =~ m/\APull|Push/, 'Did an event return?' );
   return;
}

=head3 _test_words_of_wisdom
Test that words of wisdom returns a string.
=cut
sub _test_words_of_wisdom
{
   my $random = shift;
   my $wow = words_of_wisdom( $random );
   ok( $wow =~ m/\w+/, 'Is a string returned?' );
   return;
}

=head3 _test_hush
Test hushing function
=cut
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

=head3 _test_body_regex
Test regexes used to trigger events from messages in the channel.
=cut
sub _test_body_regex
{
   my $regex = shift;

   for my $r ( sort keys %{ $regex } )
   {
      for my $i ( @{ $regex{$r}->{input} } )
      {
         subtest 'Testing body matching regexes' => sub
         {
            warn "Testing [$i] =~ $regex{$r}->{regex}" if $args->{debug};
            ok( $i =~ $regex{$r}->{regex}, "Does regex match message body?" );
            ok( $LAST_PAREN_MATCH =~ $regex{$r}->{capture}, "Is the correct string captured?" );
         }
      }
   }
   return;
}

#
# Main matter
#

if ( $args->{help} )
{
   usage( 'HELP' );
   exit;
}
elsif ( $args->{version} )
{
   say $VERSION;
   exit;
}

# Load topics file
my $topics_file = "$args->{home}/topics";
$topics = load_topics( file => $topics_file );

# Load words of wisdom
my $wow_file = "$args->{home}/words_of_wisdom";
$words_of_wisdom = load_words_of_wisdom( file => $wow_file );

# Run test suite
if ( $args->{test} )
{
   _run_tests;
   exit;
}

# Start the bot
my $bot = Cfbot->new( %{ $c->{irc} } )->run;

package Cfbot;
use base 'Bot::BasicBot'; 
use English;
use Data::Dumper;
use POE::Kernel;

=head1 PACKAGE Cfbot

=head2 SYNOPSIS

Subs in this package override Bot::BasicBot's own subs.

=head2 SUBS

=head3 said
Reads channel messages and takes action if messages match regexes.
=cut
sub said
{
   my $self = shift;
   my $msg = shift;
   my $replies;

   my $now = Time::Piece->localtime();
   return if ( $now < $hush );

   if ( $msg->{raw_body} =~ m/$prefix (hush|(be\s+)?quiet|shut\s*up|silence) /ix )
   {
      push @{ $replies }, main::hush();
   }

   my @dispatch = (
      {
         name  => 'bug match',
         regex => $regex{bug}{regex},
         run   => \&main::get_bug,
      },
      {
         name  => 'doc search',
         regex => $regex{search}{regex},
         run   => \&main::find_matches,
      },
      {
         name  => 'wow',
         regex => $regex{wow}{regex},
         run   => \&main::words_of_wisdom,
      },
      {
         name  => 'topic search',
         regex => $regex{topic}{regex},
         run   => \&main::lookup_topics,
      }
   );
   my $arg = 'undef';

   for my $d ( @dispatch )
   {
      warn "Checking dispatch $d->{name}" if $args->{debug};
      warn "$msg->{raw_body} =~ $d->{regex}";

      if ( $msg->{raw_body} =~ $d->{regex} )
      {
         if ( defined $LAST_PAREN_MATCH )
         {
            $arg = $LAST_PAREN_MATCH;
            warn "Calling dispatch $d->{name}, arg [$arg]" if $args->{debug};
            $self->forkit({
               run       => $d->{run},
               arguments => [ $arg ],
               channel   => $c->{irc}{channels}[0],
            });
            last;
         }
      }
   }
   $self->reply( $msg, $_ ) foreach ( @{ $replies } );
   return;
}

=head3 forkit
Forks any function provided to this sub via arguments. All output from the
called sub bound for STDOUT will go to the channel.
=cut
sub forkit {
# Overriding this one because the original has a bug.
   my ( $self, $args ) = @_;

   return if !$args->{run};

   $args->{handler}   = $args->{handler}   || "_fork_said";
   $args->{arguments} = $args->{arguments} || [];

# Install a new handler in the POE kernel pointing to
# $self->{$args{handler}}
   $poe_kernel->state( $args->{handler}, $args->{callback} || $self  );

   my $run;
   if (ref($args->{run}) =~ /^CODE/) {
     $run = sub {
         # Remove body from args, possible bug in orginal.
         $args->{run}->( @{ $args->{arguments} })
     };
   }
   else {
     $run = $args->{run};
   }
   my $wheel = POE::Wheel::Run->new(
     Program      => $run,
     StdoutFilter => POE::Filter::Line->new(),
     StderrFilter => POE::Filter::Line->new(),
     StdoutEvent  => "$args->{handler}",
     StderrEvent  => "fork_error",
     CloseEvent   => "fork_close"
   );

# Use a signal handler to reap dead processes
   $poe_kernel->sig_child($wheel->PID, "got_sigchld");

# Store the wheel object in our bot, so we can retrieve/delete easily.
   $self->{forks}{ $wheel->ID } = {
     wheel => $wheel,
     args  => {
         channel => $args->{channel},
         who     => $args->{who},
         address => $args->{address}
     }
   };
   return;
}

=head3 tick
This sub is called automtically by the bot at the interval defined by the
return statement at the end.
=cut
sub tick
{
   my $self=shift;
   my %wake_interval;
   $wake_interval{seconds} = $c->{wake_interval} * 60;
   
   my $now = Time::Piece->localtime();
   return 60 if ( $now < $hush );

   my @events = (
      {
         name => \&main::atom_feed,
         arg  => [{ 'feed' => "$c->{bug_feed}" }]
      },
      {
         name => \&main::git_feed,
         arg  => [{
            'feed'  => $c->{git_feed},
            'owner' => 'cfengine',
            'repo'  => 'core',
         }]
      },
      {
         name => \&main::git_feed,
         arg  => [{
            'feed'  => $c->{git_feed},
            'owner' => 'cfengine',
            'repo'  => 'masterfiles',
         }]
      },
      {
         name => \&main::git_feed,
         arg  => [{
            'feed'  => $c->{git_feed},
            'owner' => 'evolvethinking',
            'repo'  => 'evolve_cfengine_freelib',
         }]
      },
      {
         name => \&main::git_feed,
         arg  => [{
            'feed'  => $c->{git_feed},
            'owner' => 'evolvethinking',
            'repo'  => 'delta_reporting',
         }]
      },
      {
         name => \&main::git_feed,
         arg  => [{
            'feed'  => $c->{git_feed},
            'owner' => 'neilhwatson',
            'repo'  => 'vim_cf3',
         }]
      },
      {
         name => \&main::git_feed,
         arg  => [{
            'feed'  => $c->{git_feed},
            'owner' => 'neilhwatson',
            'repo'  => 'cfbot',
         }]
      },
      {
         name => \&main::words_of_wisdom,
         arg  => [ '' ],
      },
   );

   for my $e ( @events )
   {
      $self->forkit({
         run       => $e->{name},
         arguments => $e->{arg},
         channel   => $c->{irc}{channels}[0],
      });
   }
   return $wake_interval{seconds};
}

=head3 help
When someone says help to the bot this sub is run
=cut
sub help
{
   my $self = shift;
   $self->forkit({
      run       => \&main::lookup_topics,
      arguments => [ 'help' ],
      channel   => $c->{irc}{channels}[0],
   });
   return;
}
