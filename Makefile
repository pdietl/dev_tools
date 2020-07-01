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
	asciinema \
	autoconf \
	autopoint \
	autossh \
	autotools-dev \
	aws-shell \
	bison \
	build-essential \
	ccache \
	clang-format \
	cmake \
	cppcheck \
	cpuinfo \
	cscope \
	curl \
	ddd \
	docker.io \
	dos2unix \
	exuberant-ctags \
	flex \
	gawk \
	gparted \
	graphviz \
	htop \
	hub \
	hwinfo \
	indent \
	jq \
	libssl-dev \
	libvirt-dev \
	nasm \
	net-tools \
	ninja-build \
	openjdk-8-jdk \
	openjdk-8-jdk-headless \
	openssh-server \
	openssh-server \
	p7zip-full \
	packer \
	pv \
	python3-pip \
	python3-stestr \
	python3-venv \
	qemu \
	qemu-kvm \
	qemu-system-x86 \
	remake \
	rlwrap \
	ronn \
	rpm \
	ruby \
	ruby-dev \
	shellcheck \
	sshfs \
	texinfo \
	tmate \
	tmux \
	tree \
	uuid \
	uuid-dev \
	valgrind \
	vim \
	virtualenv \
	zlib1g-dev

ifneq ($(AUTOSSH),)
    $(shell cat post-install-script install_autossh > post-install-script-final)
else
    $(shell cp post-install-script post-install-script-final)
endif

DEB_NAME := $(PKG_NAME)_$(PKG_VER)_$(PKG_ARCH).deb

.PHONY: all build deb
all build deb: $(DEB_NAME)

$(DEB_NAME): Makefile post-install-script install_autossh $(addprefix pkg_root/etc/pete-bootstrap/,cscope_maps.vim vimrc autossh.service autossh2.service tmux.conf)
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
		--after-install post-install-script-final \
		--force \
		-C pkg_root

.PHONY: clean
clean:
	$(RM) $(PKG_NAME)_* post-instapp-script-final

.PHONY: docker-shell
docker-shell:
	docker run -ti $(DOCKER_ARGS) /bin/bash

docker-%:
	docker run $(DOCKER_ARGS) $(MAKE) $* $(MAKEFLAGS)

.PHONY: docker-build-image
build-docker-image:
	docker build -t $(DOCKER_TAG) .
