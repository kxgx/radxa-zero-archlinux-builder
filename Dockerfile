FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    crossbuild-essential-arm64 \
    flex bison \
    libssl-dev libncurses-dev \
    bc kmod \
    dosfstools mtools e2fsprogs fdisk \
    xz-utils git ca-certificates \
    libarchive-tools file wget curl rsync \
    openssl python3 python3-pyelftools \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work
CMD ["bash"]
