# Dockerfile.builder — 在這個容器內跑 build.sh 產生 .deb。
# 跟最終要掃描的 image 分開，避免把一堆 build toolchain 帶進產出 image。
ARG UBUNTU_VERSION=24.04
FROM ubuntu:${UBUNTU_VERSION}

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends \
        ca-certificates curl git xz-utils file && \
    rm -rf /var/lib/apt/lists/*

COPY build.sh /work/build.sh
COPY builders /work/builders
RUN chmod +x /work/build.sh /work/builders/*.sh

WORKDIR /work
VOLUME ["/out"]
ENTRYPOINT ["/work/build.sh"]
