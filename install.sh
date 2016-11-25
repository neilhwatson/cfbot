#!/bin/bash

# Set these timeouts because travis-ci env is slower than my laptop.
timeout=3600
cpanm="cpanm --configure-timeout $timeout --build-timeout $timeout --test-timeout $timeout"

perl_packages="Config::YAML JSON Bot::BasicBot Cache::FastMmap XML::Feed \
   Mojo::UserAgent Mojo::DOM Net::SSLeay IO::Socket::SSL \
   LWP::Protocol::https Git::Repository \
   Perl6::Slurp"

for next_p in $perl_packages
do
   { TEST_JOBS=2 $cpanm ${next_p}; } &
done

{ apt-get update && apt-get -y install ngircd && apt-get clean; } &

{ useradd cfbot -d /var/lib/cfbot && chown -R cfbot:cfbot /var/lib/cfbot && chmod -R g-w,o-w /var/lib/cfbot; } &

echo ************ waiting 
wait
echo ************ background tasks completed 

# Note cpanm force used because of this bug: 
# https://rt.cpan.org/Public/Bug/Display.html?id=118548 
TEST_JOBS=2 $cpanm --notest POE::Component::SSLify

# Troubles with this one, but works of last
TEST_JOBS=2 $cpanm AnyEvent && rm -fr /root/.cpan*
