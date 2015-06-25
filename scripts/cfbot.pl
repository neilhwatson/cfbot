=pod

=head1 LICENSE
cfbot based on the original irssi script 'doc.pl' by Author FoxMaSk
C<<foxmask@phpfr.org>>

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.

=head1 SYNOPSIS
This script manage a list of keywords
with their definition...
The file, named "doc", is composed as follow :
keyword=definition

Also, returns CFEngine bugs, and documentation. See the help line in the file
'cfbot'

=head2 AUTHOR

Neil H. Watson C<< <neil@watson-wilson.ca> >>
L<< https://github.com/neilhwatson/cfbot >>

=cut

use Irssi::Irc;
use Irssi;
use strict;
use warnings;
use Web::Query;
use HTTP::Tiny;
use File::Basename;
use Text::LineNumber;
use Data::Dumper;

#name of the channel where this feature will be used
my $channel   = "#cfengine";

# Command prefix for all commands
my $cmd_query = "!cfbot";

#file name to store data
my $doc_file = Irssi::get_irssi_dir()."/cfbot";

my $documentation_checkout = '/home/cfbot/documentation'; # check out documentation.git here
my $docbase = 'https://docs.cfengine.com/latest'; # or 'latest'

#==========================END OF PARMS======================================

#init array
my @doc = ();
my $x = 0;

#The main function
sub doc_find {
    my ($server, $msg, $nick, $address, $target) = @_;

    my $keyword="";
    my $new_definition="";
    my $definition="";

    #flag if keyword is found
    my $find="";

    #*action* to do
    my $cmd="";
    #the string behind *action*
    my $line="";

    #to display /msg
    my $info="";

    #split the *action* and the rest of the line
    ($cmd,$line) = split / /,$msg,2;

    if ($target eq $channel) {

        #to query
        if ($cmd eq $cmd_query) {
            $keyword = $line;

           ($find,$definition) = exist_doc($keyword);

            if ($find ne '') {
                my $newmsg = join("=",$keyword,$definition);
                $server->command("notice $target $newmsg");
            }

            # List available topics
            elsif ( $keyword eq 'topics' ) {
                my $topics = list_topics();
                my $newmsg = 'Available topics: '.join( ', ', @$topics );
                $server->command("notice $target $newmsg");
            }

            # Return bug URL if available
            elsif ( $keyword =~ m/\Abug (\d+)/ ) {
               my $bug_number = $1;
               my $bug = get_bug( $bug_number );
               $server->command("notice $target $bug->{response} $bug->{subject}");
            }

           # search docs if available
            elsif ( $keyword =~ m/\Asearch ([-\w ]+)/i ) {
               my $word = $1;
               $server->command("notice $target Match: $_->{url} $_->{summary}")
                foreach find_matches($word, 20);
            }

            #definition not found ; so we tell it to $nick
            else {
                $info="$nick $keyword does not exist";
                info_doc($server,$info);
            }
        }
    }
}

sub list_topics {
   my @topics;
   for my $line ( @doc ) {
      ( my $topic ) = $line =~ m/\A([^=]+)=/;
      push @topics, $topic;
   }
   return \@topics;
}

sub reference_type
{
 my $location = shift;

 my @common = (location => $location);

 return undef if $location !~ m,reference/(.+)\.markdown$,;

 my $node = $1;

 return undef if $node eq 'standard-library';
 return undef if $node eq 'functions';
 return undef if $node =~ m/(all-types|common-attributes|design-center|enterprise)/;

 push @common, (node => $node, basenode => dirname($node));

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

sub add_markdown_match
{
 my ($arr, $header, $level, $offset) = @_;

 push @$arr, { header => $header, level => $level, offset => $offset };
}

sub parse_markdown
{
 my $word = shift;
 my $text = shift @_;
 my $tln = Text::LineNumber->new($text);

 my %ret;

 $ret{published} = ($text =~ m/^published:\s+true/m);

 $ret{title} = $1 if $text =~ m/^title:\s+(.+)/m;
 $ret{title} =~ s/[]|"[]//g;

 my $temp = $text;

 while ($temp =~ s{ $word }
                  {
                   # line number -> number of matches
                   $ret{matches}->{scalar $tln->off2lnr($-[0])}++;
                   '';
                  }egmx)
 {
 }

 $ret{headers} = [];

 $temp = $text;
 $temp =~ s{ ^(.+)[ \t]*\n=+[ \t]*\n+ }
           {
            add_markdown_match($ret{headers}, $1, 1, $-[0]);
           }egmx;

 $temp = $text;
 $temp =~ s{ ^(.+)[ \t]*\n-+[ \t]*\n+ }
           {
            add_markdown_match($ret{headers}, $1, 2, $-[0]);
           }egmx;

 $temp = $text;
 $temp =~ s{
            ^(\#{1,6})  # $1 = string of #'s
            [ \t]*
            (.+?)       # $2 = Header text
            [ \t]*
            \#*         # optional closing #'s (not counted)
            \n+
        }{
            my $h_level = length($1);
            add_markdown_match($ret{headers}, $2, $h_level, $-[0]);
            '';
        }egmx;

 # sort the headers by position
 @{$ret{sections}} = sort { $a->{offset} <=> $b->{offset} } @{$ret{headers}};

 my @sections = @{$ret{sections}};

 while (@sections)
 {
  my $current = shift @sections;

  my $end = length($text)-1;
  if (scalar @sections)
  {
   my $next = $sections[0];
   # end of this section is just before the next one begins
   $end = $tln->lnr2off($tln->off2lnr($next->{offset})) - 1;
  }

  $current->{start_line} = scalar $tln->off2lnr($current->{offset});
  $current->{end_line} = $tln->off2lnr($end);
  $current->{end} = $end;

  my $section_body_start = $current->{offset};
  my $section_text = substr $text, $section_body_start, $end - $section_body_start;

  if ($section_text =~ m/\n.+Description:\W+\s+(.+?)\n\n/s)
  {
   $current->{summary} = $1 if $section_text =~ m/\n.+Description:\W+\s+(.+?)\n\n/s;
   $current->{summary} .= " ($1)" if $section_text =~ m/^.+History:\W+\s+(.+)/m;
  }
  else
  {
   $current->{summary} = $section_text;
  }
 }

 delete $ret{headers};

 return \%ret;
}

sub find_matches
{
   my $word = shift;
   my $max = shift || 100;
   unless (chdir $documentation_checkout)
   {
       warn "Couldn't change into '$documentation_checkout': $!";
       return;
   }

   my $matches = `git grep -l '$word' reference`;

   my @matches = grep { defined } map { reference_type($_) } split("\n", $matches);

   my @processed_matches;

   my %parsed;

   foreach my $match (@matches)
   {
    unless (exists $match->{url})
    {
     $match->{url} = ($match->{type} =~ m/:/) ? "$docbase/reference-BASENODE-TITLE.html" : "$docbase/reference-NODE.html";
    }

    warn "uh-oh: I can't construct the URL here " . Dumper $match unless $match->{url};

    open my $refd, '<', $match->{location} or warn "Couldn't open $match->{location}: $!";

    my $parse = exists $match->{parse} ? $match->{parse} : parse_markdown($word, join '', <$refd>);
    $match->{parse} = $parse;

    next unless $parse->{published};

    foreach my $text_match_line (keys %{$parse->{matches}})
    {
     foreach my $section (@{$parse->{sections}})
     {
      if ($text_match_line >= $section->{start_line} &&
          $text_match_line <= $section->{end_line})
      {
       $parse->{matches}->{$text_match_line} = $section;
      }
     }
    }

    $match->{url} =~ s/TITLE/$parse->{title}/g;
    $match->{url} =~ s/BASENODE/$match->{basenode}/g;
    $match->{url} =~ s/NODE/$match->{node}/g;

    foreach my $text_match_key (sort { $a <=> $b } keys %{$parse->{matches}})
    {
     my $text_match = $parse->{matches}->{$text_match_key};
     next unless ref $text_match eq 'HASH';
     push @processed_matches, { url => $match->{url}, summary => $text_match->{summary}, info => $text_match, match => $match };
    }

    my $count = scalar @processed_matches;
    if ($count >= $max)
    {
     push @processed_matches, { url => "...", summary => "$count matches found, but only showing $max matches", info => undef, match => undef };
     last;
    }
   }

   return @processed_matches;
}

sub get_bug
{
   my $bug_number = shift;
   my $cf_bug_tracker = 'https://dev.cfengine.com/issues';
   my %return = (
      subject  => "",
      response => "Unexpected error"
   );
   my $url = "$cf_bug_tracker/$bug_number";

   unless ( $bug_number =~ m/\A\d{1,6}\Z/ )
   {
      $return{response} = "Not a valid bug number";
   }
   else
   {
      my %responses = (
         200 => $url,
         404 => "Bug $bug_number not found"
      );

      my $client = HTTP::Tiny->new();
      my $response = $client->get( "$cf_bug_tracker/$bug_number" );
      for my $key (keys %responses)
      {
         $return{response} = $responses{$key} if $response->{status} == $key;
      }

      if ( $response->{status} == 200 )
      {
         my $q = Web::Query->new_from_html( \$response->{content} );
         $return{subject} = $q->find( 'div.subject' )->text;
         $return{subject} =~ s/\A\s+|\s+\Z//g; # trim leading and trailing whitespace
      }
   }
   return \%return;
}

#load datas
sub load_doc {
    my $doc_line="";
    if (-e $doc_file) {
        @doc = ();
        Irssi::print("Loading doc from $doc_file");
        local *DOC;
        open(DOC,"$doc_file");
        local $/ = "\n";
        while (<DOC>) {
            chop();
            $doc_line = $_;
            push(@doc,$doc_line);
        }
        close DOC;
        Irssi::print("Loaded " . scalar(@doc) . " record(s)");
    } else {
        Irssi::print("Cannot load $doc_file");
    }
}

#search if keyword already exists or not
sub exist_doc {
    my ($keyword) = @_;
    my $key="";
    my $def="";
    my $find="";
    for ($x=0;$x < @doc;$x++) {
        ($key,$def) = split /=/,$doc[$x],2;
        if ($key =~ m/\A$keyword\Z/i) {
            $find = "*";
            last;
        }
    }
    return $find,$def;
}

#display /msg to $nick
sub info_doc {
    my ($server,$string) = @_;
    $server->command("/msg $string");
    Irssi::signal_stop();
}

load_doc();

Irssi::signal_add_last('message public', 'doc_find');
Irssi::print("Doc Management loaded!");
