#!/usr/bin/perl

use strict;
use warnings;
use feature 'say';
use Data::Dumper;

my $cfe_doc_url = "https://docs.cfengine.com/docs/master/";
my $function_ref = _index_cfe_functions({
      dir => "$ENV{HOME}/src/cfengine/documentation/reference/functions" });

warn "function accumulated: [$function_ref->{accumulated}{description}]";

my @messages = (
   "the function or",
   "and function nill",
   "ago function",
   "function concat",
   "function accumulated",
);

for my $next_message ( @messages ){

   # Test if function
   if ( $next_message =~ m/(\w* \s* function \s* \w*)/msx ) {
      message_function( $1 );
   }
}

# Match function name from message
sub message_function {
   my $message = shift;
   my $reply = '';

   ( my @functions ) = $message =~ m/(\w*) \s* function \s* (\w*)/msx;

   for my $next_function ( @functions ){

      if ( exists  $function_ref->{$next_function}{description} ) {

         $reply .= <<END_REPLY;
FUNCTION $next_function
$function_ref->{$next_function}{description}
URL $function_ref->{$next_function}{url}
END_REPLY
      }
   }
   say $reply if $reply ne '';
}



# Build an index of function names and descriptions.
sub _index_cfe_functions {
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
         \Q**Description:**\E \s+ ([^\n]+)\n   # First description line.
         ^\s*$       # Blank line
         ([^\*]+)    # Another paragraph of the description but not **heading.
         ^\s*$       # Stop at first blank line.
         /msx 
      ){
         $function{$next_function}{description} = defined $2 ? $1." ".$2 : $1;
         # remove trailing whitespace
         $function{$next_function}{description} =~ s/\s+$//ms;
         # replace newlines with a space 
         $function{$next_function}{description} =~ s/\n/ /gms;

         $function{$next_function}{url}
            = $cfe_doc_url."/reference-functions-".$next_function.".html";
      }
   }
   return \%function;
}

