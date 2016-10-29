FROM  perl:5.24
MAINTAINER  Neil Watson <neil@watson-wilson.ca>
LABEL site="cfbot"
LABEL version="1.0"

RUN cpanm POE::Component::SSLify || cat /root/.cpanm/work/*/build.log
#RUN cpanm Config::YAML JSON Bot::BasicBot Cache::FastMmap XML::Feed \
#   Mojo::UserAgent Mojo::DOM Net::SSLeay POE::Component::SSLify \
#   || cat /root/.cpanm/work/*/build.log

#COPY . /var/lib/cfbot
#RUN cd /usr/src/ \
   #&& git clone https://github.com/cfengine/documentation.git \
   #&& ln -fs /usr/src/documentation /var/lib/cfbot/documentation

WORKDIR /var/lib/cfbot
#CMD [ "perl", "cfbot.pm", "--debug" ]

# Howto:

# Build with docker build -t cfbot .

# View with docker images

# Docker file
# docker run --cap-drop=all --cap-add=chown --cap-add=net_bind_service --cap-add=setgid --cap-add=setuid --detach --name cfbot -t cfbot

# Stop with
# docker stop $(docker ps |awk '$2 ~ /^cfbot/ { print $1 }')

# start with
# docker start $(docker ps |awk '$2 ~ /^cfbot/ { print $1 }')

# Delete container
# docker rm $(docker ps -a |awk '$2 ~ /^cfbot/ { print $1 }')

# Delete build image with 
# docker rmi $(docker images |awk '$1 ~ /^cfbot$/ { print $3 }')
