# Build and test environment of the Archer A5 v4 / C50 v4 build: Debian testing with the
# prerequisites of the OpenWrt build system and the tools of the QEMU bench (tests/qemu/).
# docker/run.sh builds the image and runs commands in it with the repository at /work.

FROM debian:testing

ARG UID=1000
ARG GID=1000

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
        bison \
        build-essential \
        bzip2 \
        ca-certificates \
        clang \
        curl \
        diffutils \
        file \
        flex \
        g++ \
        g++-multilib \
        gawk \
        gcc-multilib \
        gettext \
        git \
        less \
        libncurses-dev \
        libssl-dev \
        patch \
        perl \
        python3 \
        python3-dev \
        python3-pyelftools \
        python3-setuptools \
        rsync \
        swig \
        time \
        unzip \
        wget \
        xz-utils \
        zlib1g-dev \
        zstd \
        # QEMU bench: the emulator, network namespaces, the services of the LAN and WAN sides
        bind9-dnsutils \
        dnsmasq-base \
        iperf3 \
        iproute2 \
        iputils-ping \
        openssh-client \
        ppp \
        pppoe \
        procps \
        qemu-system-mips \
        socat \
        tcpdump \
        udhcpc \
        util-linux \
        wireguard-tools \
    && rm -rf /var/lib/apt/lists/*

# OpenWrt refuses to build as root: builds run as this user, whose IDs match the owner of the
# checkout on the host, so that the build tree stays writable outside the container.
RUN groupadd -g "$GID" builder 2>/dev/null || true; \
    useradd -m -u "$UID" -g "$GID" -s /bin/bash builder

WORKDIR /work
