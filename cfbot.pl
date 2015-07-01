#!/usr/bin/perl

use strict;
use warnings;
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
use File::Basename;

our $VERSION = 1.0;

my ( $c, $topics, $args, $words_of_wisdom );
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
   return \%arg;
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

sub words_of_wisdom
{
   my $wow = '';

   my $random = shift;
   $random = 'no' unless defined $random;

   srand;
   my $d4 = int( rand( 4 ));

   if ( $random eq 'now' or $d4 == 3 )
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

sub get_docbase
{
 return 'https://docs.cfengine.com/latest'; # or 'latest'
}

{
    my $rev;
    my $titles;

    sub get_titles
    {
        my $documentation_checkout = $args->{docs_repo};
        unless (chdir $documentation_checkout)
        {
            warn "Couldn't change into '$documentation_checkout': $!";
            return;
        }

        my $newrev = `git rev-parse HEAD`;
        if (defined $rev &&
            $newrev eq $rev &&
            defined $titles)
        {
            # do nothing
        }
        else
        {
            my $new_title_text = `git grep '^title:' reference`;
            my %titles = ($new_title_text =~ m/^(.+\.markdown):title: "?([^"]+?)"?$/mg);

            $rev = $newrev;
            $titles = \%titles;
        }

        return $titles;
    }
}

sub reference_type
{
 my $location = shift;

 my $docbase = get_docbase();
 my @common = (location => $location);

 return undef if $location !~ m,(reference/(.+)\.markdown)[-=:](.+),;

 my $file = $1;
 my $node = $2;
 my $text = $3;

 return undef if $node eq 'standard-library';
 return undef if $node eq 'functions';
 return undef if $node =~ m/(all-types|common-attributes|design-center|enterprise)/;

 push @common, (file => $file, node => $node, text => $text, basenode => dirname($node));

 my $titles = get_titles();

 push @common, (title => exists $titles->{$file} ? $titles->{$file} : 'Title Unknown');

 return { @common, type => 'class' } if $node eq 'classes';
 return { @common, type => 'macros' } if $node eq 'macros';

 if ($node =~ s,standard-library/(.+),standard-library-$1,)
 {
  return { @common, node => $node, type => "stdlib:$1", url => "$docbase/reference-NODE.html" };
 }

 return { @common, type => 'special-variables' } if $node eq 'special-variables';
 return { @common, type => "special-variable:$1" } if $node =~ m,special-variables/(.+),;

 return { @common, type => 'promise-types' } if $node eq 'promise-types';
 return { @common, type => "edit_line", url => "$docbase/reference-promise-types-edit_line.html" } if $node =~ m,edit_line,;
 return { @common, type => "edit_xml", url => "$docbase/reference-promise-types-edit_xml.html" } if $node =~ m,edit_xml,;
 return { @common, type => "promise-type:$1" } if $node =~ m,promise-types/(.+),;

 return { @common, type => "function:$1" } if $node =~ m,functions/(.+),;

 return { @common, type => 'components' } if $node eq 'components';
 return { @common, type => "file_control", url => "$docbase/reference-components-file_control_promises.html" } if $node eq 'components/file_control_promises';

 return { @common, type => "component:$1" } if $node =~ m,components/(.+),;

 warn "Sorry, I can't parse location: $location";
 return undef;
}

sub find_matches
{
   my $word = shift;
   my $max = shift || 100;

   my $docbase = get_docbase();
   my $documentation_checkout = $args->{docs_repo};
   unless (chdir $documentation_checkout)
   {
       warn "Couldn't change into '$documentation_checkout': $!";
       return;
   }

   my $matches = `git grep --show-function --function-context '$word' reference`;

   my @matches = grep { defined } map { reference_type($_) } split("\n", $matches);

   my %parsed;

   foreach my $match (@matches)
   {
    unless (exists $match->{url})
    {
     $match->{url} = ($match->{type} =~ m/:/) ? "$docbase/reference-BASENODE-TITLE.html" : "$docbase/reference-NODE.html";
    }

    warn "uh-oh: I can't construct the URL here " . Dumper $match unless $match->{url};

    $match->{url} =~ s/TITLE/$match->{title}/g;
    $match->{url} =~ s/BASENODE/$match->{basenode}/g;
    $match->{url} =~ s/NODE/$match->{node}/g;

    push @{$parsed{$match->{url}}}, $match;
   }

   my @processed_matches;

   foreach my $url (sort keys %parsed)
   {
    push @processed_matches, { url => $url, summary => join("\n", map { $_->{text} } @{$parsed{$url}}) };

    my $count = scalar keys @processed_matches;
    if ($count >= $max)
    {
     push @processed_matches, { url => "...", summary => "$count matches found, but only showing $max matches" };
     last;
    }
   }

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
   splice @{ $events }, $c->{git_feed_limit};

   for my $e ( @{ $events } )
   {
      next unless time_cmp ( time => $e->{created_at}, newer_than => $args{newer_than} );

      my $msg;
      if ( $e->{type} eq 'PushEvent' )
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
      if ( time_cmp( time => $e->updated, newer_than => $args{newer_than} ) )
      {
         push @events, $e->title .", ". $e->link;
      }
   }
   say $_ foreach ( @events );
   return \@events;
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

#
# Testing subs
#
sub _run_tests
{
   my %tests = (
      # Name your tests 't\d\d' to ensure order
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
         arg  => [ 'the' ]
      },
      t09 =>
      {
         name => \&_test_cfengine_bug_atom_feed,
         arg => [ 'feed', "$c->{bug_feed}", "newer_than", 3000 ]
      },
      t09 =>
      {
         name => \&_test_git_feed,
         arg => [
            'feed', $c->{git_feed},
            'owner', 'cfengine',
            'repo', 'core',
            'newer_than', '3000'
            ]
      },
      t10 =>
      {
         name => \&_test_words_of_wisdom,
         arg => [ 'now' ],
      },
      t11 =>
      {
         name => \&_test_hush,
      }

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
   my $help = qx/ $0 -? /;
   like( $help, qr/Usage:.*?Requirements/ms,  "[$0] -h, for usage" );
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
      like( $msg->[0], qr|\A$c->{bug_tracker}/$bug|, "URL correct?" );
      like( $msg->[0], qr|Variables not expanded inside array\Z|, "Subject correct?" );
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
      like( $matches->[0],
         qr|\A$c->{cf_docs_url}/reference-functions-$keyword.html|,
         "Function URL"
      );
      like( $matches->[0],
         qr/Transforms a data container to expand all variable references\. \(Was introduced in version 3\.7\.0 \(2015\)\)\Z/,
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
   like( $events->[0], qr/\ABug #\d+:.+\Z/, "Was a bug returned?" );
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
   like( $events->[0], qr/\APull|Push/, 'Did an event return?' );
}

sub _test_words_of_wisdom
{
   my $random = shift;
   my $wow = words_of_wisdom( $random );
   like( $wow, qr/\w+/, 'Is a string returned?' );
}

sub _test_hush
{
   my $msg = hush();
   subtest 'hushing' => sub
   {
      like( $msg, qr/\S+/, "Hush returns a message" );
      ok( $hush, '$hush is now true' );
   }
}
#
# Main matter
#

# Process CLI args
$args = _get_cli_args( @ARGV );

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

# Load config file
$c = Config::YAML->new( config => "$args->{home}/cfbot.yml" );

if ( $args->{debug} )
{
   $c->{irc}{channels}[0] = '#bottest';
   $c->{irc}{nick}        = 'cfbot_test';
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
   my $prefix = qr/$c->{irc}{nick}:?\s+/i;

   my $now = Time::Piece->localtime();
   return if ( $now < $hush );

   if ( $msg->{raw_body} =~ m/$prefix (hush|(be\s+)?quiet|shut\s*up|silence) /ix )
   {
      push @{ $replies }, main::hush();
   }
   my @dispatch = (
      {
         regex => qr/bug \s+ (\d{4,5}) /ix,
         run   => \&main::get_bug,
      },
      {
         regex => qr/$prefix search \s+ (\w+) /ix,
         run   => \&main::find_matches,
      },
      {
         regex => qr/$prefix (wow|wisdom|speak|talk|words\s+of\s+wisdom) /ix,
         run   => \&main::words_of_wisdom,
      },
      {
         regex => qr/$prefix topic \s+ (\w+) /ix,
         run   => \&main::lookup_topics,
      }
   );
   my $arg = 'undef';

   for my $d ( @dispatch )
   {
      if ( $msg->{raw_body} =~ $d->{regex} )
      {
         $arg = $1;
         warn "Dispatching with arg [$arg]" if $args->{debug};
         $self->forkit(
            run       => $d->{run},
            arguments => [ $arg ],
            channel   => $c->{irc}{channels}[0],
         );
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
