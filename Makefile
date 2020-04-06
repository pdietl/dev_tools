DOCKER_VER := 1
DOCKER_TAG := pdietl/ubuntu_fpm:$(DOCKER_VER)

vol_mnt    = -v$(1):$(1)
vol_mnt_ro = $(call vol_mnt,$(1)):ro
map        = $(foreach f,$(2),$(call $(1),$(f)))

DOCKER_ARGS := --rm -w$(CURDIR) $(call vol_mnt,$(CURDIR))
DOCKER_ARGS += $(call map,vol_mnt_ro,/etc/passwd /etc/group)
DOCKER_ARGS += $(call map,vol_mnt,/var/run/docker.sock)
ifeq ($(ROOT),)
    DOCKER_ARGS += -u$(shell id -u):$(shell id -g)
endif
DOCKER_ARGS += $(DOCKER_TAG)

PKG_VER  := 1.2
PKG_ARCH := all
PKG_NAME := pete-bootstrap

DEP_LIST := \
    aptitude \
    autoconf \
    autotools-dev \
    bison \
    build-essential \
    cmake \
    curl \
    ddd \
    docker.io \
    dos2unix \
    exuberant-ctags \
    gawk \
    htop \
    indent \
    libssl-dev \
    nasm \
    net-tools \
    ninja-build \
    openjdk-8-jdk \
    openjdk-8-jdk-headless \
    openssh-server \
    python3-pip \
    python-pip \
    p7zip-full \
    pv \
    shellcheck \
    tree \
    uuid \
    uuid-dev \
    valgrind \
    vim \
    virtualenv

DEB_NAME := $(PKG_NAME)_$(PKG_VER)_$(PKG_ARCH).deb

.PHONY: all build deb
all build deb: $(DEB_NAME)

$(DEB_NAME): Makefile post-install-script $(addprefix pkg_root/etc/pete-bootstrap/,cscope_maps.vim vimrc)
	fpm --input-type dir \
		--output-type deb \
		--maintainer 'Pete Dietl' \
		--name $(PKG_NAME) \
		--description 'Sets up a new Ubuntu box' \
		--version $(PKG_VER) \
		--license MIT \
		--url 'https://github.com/pdietl/dev_tools' \
		--architecture $(PKG_ARCH) \
		$(addprefix --depends ,$(DEP_LIST)) \
		--after-install post-install-script \
		--force \
		-C pkg_root

.PHONY: clean
clean:
	$(RM) $(PKG_NAME)_*

.PHONY: docker-shell
docker-shell:
	docker run -ti $(DOCKER_ARGS) /bin/bash

docker-%:
	docker run $(DOCKER_ARGS) $(MAKE) $* $(MAKEFLAGS)

.PHONY: docker-build-image
build-docker-image:
	docker build -t $(DOCKER_TAG) .
