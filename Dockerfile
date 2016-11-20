FROM  perl:5.24
MAINTAINER  Neil Watson <neil@watson-wilson.ca>
LABEL site="cfbot"
LABEL version="1.0"

RUN cpanm Config::YAML JSON Bot::BasicBot Cache::FastMmap XML::Feed \
   Mojo::UserAgent Mojo::DOM Net::SSLeay IO::Socket::SSL LWP::Protocol::https \
   Git::Repository
# Force this install because of bug:
# https://rt.cpan.org/Public/Bug/Display.html?id=118548
RUN cpanm --force  POE::Component::SSLify

COPY . /var/lib/cfbot

# TODO have bot pull this down and keep it up to date
RUN cd /usr/src/ \
   && git clone https://github.com/cfengine/documentation.git \
   && ln -fs /usr/src/documentation /var/lib/cfbot/documentation

RUN useradd cfbot && chown -R cfbot:cfbot /var/lib/cfbot /usr/src/documentation
USER cfbot
WORKDIR /var/lib/cfbot

ENTRYPOINT [ "perl", "cfbot.pm"  ]

# Howto:

# Build with docker build -t cfbot .

# View with docker images

# Docker file
# docker run --cap-drop=all --detach --name cfbot -t cfbot

# Stop with
# docker stop $(docker ps |awk '$2 ~ /^cfbot/ { print $1 }')

# start with
# docker start $(docker ps |awk '$2 ~ /^cfbot/ { print $1 }')

# Delete container
# docker rm $(docker ps -a |awk '$2 ~ /^cfbot/ { print $1 }')

# Delete build image with 
# docker rmi $(docker images |awk '$1 ~ /^cfbot$/ { print $3 }')
