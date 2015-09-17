#!/usr/bin/perl

use strict;
use warnings;
use feature 'say';
use Data::Dumper;
use YAML qw/ LoadFile /;

my $topics_yml = LoadFile( "topics.yml" ) or die "Cannot load topics.yml $!";
my $msg = join ' ', @ARGV;

say "msg is ". $msg;

my %topic;
my %keyword;
my $i = 0;

# Build a fast index for keyword searches
for my $next_topic ( @{ $topics_yml } ) {

   # Store topic in index.
   $topic{$i} = $next_topic->{topic};

   for my $next_keyword ( @{ $next_topic->{keywords} } ) {

         # Store keyworkd in index.
         push @{ $keyword{$next_keyword} }, $i;
   }
   $i++;
}

# Count each keyword matching in msg
my %possible_keyword;
for my $next_word ( keys %keyword ) {
   
   if ( $msg =~ m/\b$next_word\b/i ) {
      $possible_keyword{$next_word}++;
   }
}

# Find the highest count of keyword matches and show related topics
my $topic;
my $previous_count = 0;
for my $next_word  ( keys %possible_keyword ) {

   if ( $possible_keyword{$next_word} > $previous_count ) {
      $topic = $next_word;
   }
   $previous_count = $possible_keyword{$next_word};
}

if ( defined $topic ) {
   for my $next_topic ( @{ $keyword{$topic} } ) {
      say $topic{ $next_topic };
   }
}
else {
   say 'No topic defined'
}
