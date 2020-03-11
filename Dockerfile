FROM ubuntu:latest

RUN DEBIAN_FRONTEND=noninteractive apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        build-essential \
        ruby-dev \
        rubygems \
        sudo

RUN gem install --no-ri --no-rdoc \
    fpm

RUN sed -i 's/^%sudo.*/%sudo ALL=NOPASSWD: ALL/' /etc/sudoers
