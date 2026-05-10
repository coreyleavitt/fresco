# fresco development image. Mirrors recall's Docker-for-tooling pattern.
#
# All toolchain operations (nim, nimble, tests) run inside this image.
# Pure-Nim package: no C deps beyond glibc.

FROM opensuse/tumbleweed

ARG NIM_VERSION=2.2.10
ARG NIM_ARCH=linux_x64

RUN zypper --non-interactive refresh \
    && zypper --non-interactive --gpg-auto-import-keys dup --no-recommends --allow-vendor-change \
    && zypper --non-interactive install --no-recommends \
        gcc \
        glibc-devel \
        ca-certificates \
        git \
        curl \
        tar \
        xz \
        findutils \
        ncurses-utils \
    && zypper clean -a \
    && rm -rf /var/cache/zypp/*

# Install Nim from the choosenim distribution tarball.
RUN curl -fsSL "https://nim-lang.org/download/nim-${NIM_VERSION}-${NIM_ARCH}.tar.xz" \
        -o /tmp/nim.tar.xz \
    && tar -xJf /tmp/nim.tar.xz -C /opt \
    && mv "/opt/nim-${NIM_VERSION}" /opt/nim \
    && rm /tmp/nim.tar.xz
ENV PATH="/opt/nim/bin:${PATH}"

WORKDIR /workspace

# fresco needs a real-ish TTY for the integration tests (PTY pair). The
# default `docker run` allocates a TTY when -t is passed; the dev script
# does. ncurses-utils provides `tput` etc. for diagnostic use in tests.
