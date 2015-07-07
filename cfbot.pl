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
}

#
# Support subs that you probably will not use.
#
sub _get_cli_args
{
   use Getopt::Long qw/GetOptionsFromArray/;
   use Cwd;

   my $cwd = getcwd();
   # Set default CLI args here. Getopts will override.
   my %arg = (
      home => $cwd,
      docs_repo => $cwd."/documentation",
   );

   my @args = @_;

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
   or eval
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

sub _test_for_writable
{
   my $file = shift;
   my @f    = stat( $file ) or die "Cannot open file [$file]";
   my $mode = $f[2] & 0777;

   if ( $mode & 022 )
   {
      return undef;
   }
   return 1;
}
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
}

sub _skip_words
# Do not search for these words
{
   my $word = shift;
   my @words = ( qw/ a an the and or e promise is / );

   warn "_skip_words arg = [$word]" if $args->{debug};

   foreach ( @words ) { return 1 if lc($word) eq $_ }
   return 0;
}

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

sub time_cmp
{
   # Expects newer_than to be in minutes.
   my %args = @_;

   $args{time} =~ s/Z\Z//g;
   $args{time} = Time::Piece->strptime( $args{time}, "%Y-%m-%dT%H:%M:%S" );

   my $now  = Time::Piece->gmtime();
   $args{newer_than} = $now - $args{newer_than} * 60;

   return 1 if (  $args{time} > $args{newer_than} );
   return 0;
}

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

#
# Main subs that can be called by the bot
#
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

sub words_of_wisdom
{
   my $wow = '';

   my $random = shift;
   $random = 'no' unless defined $random;

   warn "wow random = [$random]" if $args->{debug};
   ;
   srand;
   my $d = int( rand( 6 ));
   $d = 0 if $args->{test};

   if ( $random =~ m/\A$wow_words\Z/ or $d == 5 )
   {
      $wow = $words_of_wisdom->[rand @{ $words_of_wisdom }];
   }
   say $wow;
   return $wow
}

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

sub find_matches
# Find keyword matches in CFEngine documentation
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

    open my $refd, '<', $location or say "Couldn't open $location: $!";

    say "Opened file at $location" if $args->{debug};

 readdesc: while (<$refd>)
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
         while (<$refd>)
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

sub git_feed
{
   my %args = ( newer_than => $c->{newer_than}, @_);
   
   my @events;
   my $client = HTTP::Tiny->new();
   my $response = $client->get( "$args{feed}/$args{owner}/$args{repo}/events" );

   my $j = JSON->new->pretty->allow_nonref;
   my $events = $j->decode( $response->{content} );

   for my $e ( @{ $events } )
   {
      next unless time_cmp ( time => $e->{created_at}, newer_than => $args{newer_than} );

      my $msg;
      if ( $e->{type} eq 'PushEvent' and $args{owner} !~ m/\Acfengine\Z/i )
      {
         my $message = substr( $e->{payload}{commits}->[0]{message}, 0, 60 );
         $msg = "Push in $args{owner}:$args{repo} by $e->{actor}{login}, $message ..., ".
            "https://github.com/$args{owner}/$args{repo}/commit/$e->{payload}{head}";
      }
      elsif ( $e->{type} eq 'PullRequestEvent' )
      {
         $msg = "Pull request $e->{payload}{action} in $args{owner}:$args{repo} ".
            "by $e->{payload}{pull_request}{user}{login}, ".
            "$e->{payload}{pull_request}{title}, ".
            "$e->{payload}{pull_request}{url}";
      }
      elsif ( $e->{type} eq 'IssuesEvent' )
      {
         $msg = "Issue in $args{owner}:$args{repo} $e->{payload}{action} ".
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
}

sub atom_feed
{
   my %args = ( newer_than => $c->{newer_than}, @_ );
   my @events;

   my $feed = XML::Feed->parse( URI->new( $args{feed} )) or
      die "Feed error with [$args{feed}] ".XML::Feed->errstr;

   for my $e ( $feed->entries )
   {
      if ( $e->title =~ m/\A\w+ #\d{4,5} \((Open|Closed|Merged|Rejected)\)/ 
         and
         time_cmp( time => $e->updated, newer_than => $args{newer_than} ) )
      {
         push @events, $e->title .", ". $e->link;
      }
   }
   say $_ foreach ( @events );
   return \@events;
}

#
# Testing subs
#

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
      regex => qr/(?: (?:search|function) \s+ (\w+)) |
         (?: (\w+) \s+ function\b ) 
         /xi,
      input  => [
         "!$c->{irc}{nick} search data_expand",
         "$c->{irc}{nick}: search data_expand",
         "!$c->{irc}{nick}: search data_expand",
         "function data_expand",
         "the data_expand function",
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
      ],
      capture => qr/\Aefl\Z/i,
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
         arg  => [ 'Test topic' ],
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
         arg => [ 'feed', "$c->{bug_feed}", "newer_than", 3000 ]
      },
      t10 =>
      {
         name => \&_test_git_feed,
         arg => [
            'feed', $c->{git_feed},
            'owner', 'cfengine',
            'repo', 'core',
            'newer_than', '3000'
            ]
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
}

sub _test_doc_help
{
   my $help = qx| $0 -? |;
   ok( $help =~ m/Usage:.*?Requirements/ms,  "[$0] -h, for usage" );
}

# We test what the subs that return test from queries. IRC connection not
# required.
sub _test_topic_lookup
{
   my $keyword = shift;
   my $topics = lookup_topics( $keyword );

   is( $topics->[0],
      "Test topic: This topic is for testing the cfbot. Do not remove.",
      "Testing a topic lookup"
   );
}

sub _test_topic_not_found
{
   my $keyword = shift;
   my $topics = lookup_topics( $keyword );

   is( $topics->[0],
      "Topic [$keyword] not found",
      "Testing an uknown topic lookup"
   );
}

sub _test_bug_exists
{
   my $bug = shift;
   my $msg = get_bug( $bug );

   subtest 'Lookup existing bug' => sub
   {
      ok( $msg->[0] =~ m|\A$c->{bug_tracker}/$bug|, "URL correct?" );
      ok( $msg->[0] =~ m|Variables not expanded inside array\Z|, "Subject correct?" );
   }
}

sub _test_bug_not_found
{
   my $bug = shift;
   my $msg = get_bug( $bug );
   is( $msg->[0], "Bug [$bug] not found", "Bug not found" );
}

sub _test_bug_number_invalid
{
   my $bug = shift;
   my $msg = get_bug( $bug );
   is( $msg->[0], "[$bug] is not a valid bug number", "Bug number invalid" );
}

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
         m/Transforms a data container to expand all variable references\. \(Was introduced in version 3\.7\.0 \(2015\)\)\Z/,
         "Function summary"
      );
   }
}

sub _test_function_search_limit
{
   my $keyword = shift;
   my $matches = find_matches( $keyword );
   ok( scalar @{ $matches } <= $c->{max_records}, "Limit number of returned records" );
}
 
sub _test_cfengine_bug_atom_feed
{
   my %args = @_;
   my $events = atom_feed(
      feed       => $args{feed},
      newer_than => $args{newer_than}
   );
   # e.g. Feature #7346 (Open): string_replace function
   ok( $events->[0] =~ m/\A(Bug|Feature) #\d{4,5}.+\Z/i, "Was a bug returned?" );
}

sub _test_git_feed
{
   my %args = @_;
   my $events = git_feed(
      feed => $args{feed},
      owner => $args{owner},
      repo => $args{repo},
      newer_than => $args{newer_than}
   );
   ok( $events->[0] =~ m/\APull|Push/, 'Did an event return?' );
}

sub _test_words_of_wisdom
{
   my $random = shift;
   my $wow = words_of_wisdom( $random );
   ok( $wow =~ m/\w+/, 'Is a string returned?' );
}

sub _test_hush
{
   my $msg = hush();
   subtest 'hushing' => sub
   {
      ok( $msg =~ m/\S+/, "Hush returns a message" );
      ok( $hush, '$hush is now true' );
   }
}

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

my @kids;
#
# Subs that override Bot::BasicBot's own subs.
#
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
            $self->forkit(
               run       => $d->{run},
               arguments => [ $arg ],
               channel   => $c->{irc}{channels}[0],
            );
            last;
         }
      }
   }
   $self->reply( $msg, $_ ) foreach ( @{ $replies } );
}

sub forkit {
# Overriding this one because the original has a bug.
   my $self = shift;
   my $args;

   if (ref($_[0])) {
     $args = shift;
   }
   else {
     my %args = @_;
     $args = \%args;
   }

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
         arg  => [ 'feed', "$c->{bug_feed}" ]
      },
      {
         name => \&main::git_feed,
         arg  => [
            'feed', $c->{git_feed},
            'owner', 'cfengine',
            'repo', 'core',
         ]
      },
      {
         name => \&main::git_feed,
         arg  => [
            'feed', $c->{git_feed},
            'owner', 'cfengine',
            'repo', 'masterfiles',
         ]
      },
      {
         name => \&main::git_feed,
         arg  => [
            'feed', $c->{git_feed},
            'owner', 'evolvethinking',
            'repo', 'evolve_cfengine_freelib',
         ]
      },
      {
         name => \&main::git_feed,
         arg  => [
            'feed', $c->{git_feed},
            'owner', 'evolvethinking',
            'repo', 'delta_reporting',
         ]
      },
      {
         name => \&main::git_feed,
         arg  => [
            'feed', $c->{git_feed},
            'owner', 'neilhwatson',
            'repo', 'vim_cf3',
         ]
      },
      {
         name => \&main::git_feed,
         arg  => [
            'feed', $c->{git_feed},
            'owner', 'neilhwatson',
            'repo', 'cfbot',
         ]
      },
      {
         name => \&main::words_of_wisdom,
         arg  => [ '' ],
      },
   );

   my $sleep_interval = $wake_interval{seconds} / scalar @events;

   for my $e ( @events )
   {
      $self->forkit(
         run       => $e->{name},
         arguments => $e->{arg},
         channel   => $c->{irc}{channels}[0],
      );
      #sleep $sleep_interval;
   }
   return $wake_interval{seconds};
}

sub help
{
   my $self = shift;
   $self->forkit(
      run       => \&main::lookup_topics,
      arguments => [ 'help' ],
      channel   => $c->{irc}{channels}[0],
   );
}
