# Use this file to run the test suite.

FROM  perl:5.24
MAINTAINER  Neil Watson <neil@watson-wilson.ca>
LABEL site="cfbot"

RUN apt-get update && apt-get -y install ngircd && apt-get clean

RUN cpanm --configure-timeout 3600 --build-timeout 3600 --test-timeout 3600 \
   Config::YAML JSON Bot::BasicBot Cache::FastMmap XML::Feed \
   Mojo::UserAgent Mojo::DOM Net::SSLeay IO::Socket::SSL \
   LWP::Protocol::https Git::Repository \
   Perl6::Slurp

RUN cpanm --configure-timeout 3600 --build-timeout 3600 --notest \
   POE::Component::SSLify

RUN cpanm --configure-timeout 3600 --build-timeout 3600 --test-timeout 3600 \
   AnyEvent

COPY . /var/lib/cfbot
RUN useradd cfbot -d /var/lib/cfbot && chown -R cfbot:cfbot /var/lib/cfbot \
   && chmod -R g-w,o-w /var/lib/cfbot
USER cfbot
WORKDIR /var/lib/cfbot

ENTRYPOINT [ "perl", "cfbot.pm"  ]

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
