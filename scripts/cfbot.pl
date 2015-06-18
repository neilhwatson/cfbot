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

#name of the channel where this feature will be used
my $channel   = "#cfengine";

# Command prefix for all commands
my $cmd_query = "!cfbot";

#file name to store data
my $doc_file = Irssi::get_irssi_dir()."/cfbot";

my $documentation_checkout = '/home/cfbot/documentation'; # check out documentation.git here

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

sub find_matches
{
   my $word = shift;
   my $max = shift;
   unless (chdir $documentation_checkout)
   {
       warn "Couldn't change into '$documentation_checkout': $!";
       return;
   }

   my $matches = `git grep '$word' | grep 'reference/functions/'`;

   my @matches = map { { data => $_ } } split "\n", $matches;

   my %seen;

   my @processed_matches;
   foreach my $match (@matches)
   {
    my ($location, $data) = split ':', $match->{data}, 2;
    next if exists $seen{$location};

    my $published = 0;
    $match->{location} = $location;
    $match->{url} = $location;

    $match->{url} = "[URL unknown]";
    open my $refd, '<', $location or warn "Couldn't open $location: $!";
 readdesc: while (<$refd>)
    {
     chomp;
     if (m/^title:\s+(.+)/)
     {
      my $title = $1;
      $title =~ s/[]|"[]//g;
      $match->{url} = "https://docs.cfengine.com/docs/master/reference-functions-$title.html";
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
    push @processed_matches, $match;
   }

   return @processed_matches if scalar @processed_matches < $max;

   my $count = scalar @processed_matches;
   splice @processed_matches, $max;
   push @processed_matches, { url => "...", summary => "$count matches found, but only showing $max matches" };
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
