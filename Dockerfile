# Use this file to run the test suite.

FROM  perl:5.24
MAINTAINER  Neil Watson <neil@watson-wilson.ca>
LABEL site="cfbot"
LABEL version="1.0"

# For testing only
RUN cpanm AnyEvent Perl6::Slurp
#

RUN cpanm Config::YAML JSON Bot::BasicBot Cache::FastMmap XML::Feed \
   Mojo::UserAgent Mojo::DOM Net::SSLeay IO::Socket::SSL LWP::Protocol::https \
   Git::Repository
# Force this install because of bug:
# https://rt.cpan.org/Public/Bug/Display.html?id=118548
RUN cpanm --force  POE::Component::SSLify

COPY . /var/lib/cfbot

# For testing only
RUN apt-get update && apt-get -y install ngircd
#

RUN useradd cfbot -d /var/lib/cfbot \
   && chown -R cfbot:cfbot /var/lib/cfbot \
   && chmod -R g-w,o-w /var/lib/cfbot
USER cfbot
WORKDIR /var/lib/cfbot

ENTRYPOINT [ "perl", "cfbot.pm"  ]
#

# Howto:

# Build with docker build -t cfbot .

# View with docker images

# Docker file
# docker run --cap-drop=all --restart=unless-stopped --detach --name cfbot -t cfbot

# Stop with
# docker stop $(docker ps |awk '$2 ~ /^cfbot/ { print $1 }')

# start with
# docker start $(docker ps |awk '$2 ~ /^cfbot/ { print $1 }')

# Delete container
# docker rm $(docker ps -a |awk '$2 ~ /^cfbot/ { print $1 }')

# Delete build image with 
# docker rmi $(docker images |awk '$1 ~ /^cfbot$/ { print $3 }')
