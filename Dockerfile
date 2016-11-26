# Use this file to run the test suite.

FROM  perl:5.24
MAINTAINER  Neil Watson <neil@watson-wilson.ca>
LABEL site="cfbot"

COPY . /var/lib/cfbot

RUN /var/lib/cfbot/install.sh

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
