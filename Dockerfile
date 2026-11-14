# Sandbox image for running Claude Code under Apple's `container` runtime.
# Each container runs in its own lightweight Linux VM, so processes in here
# cannot see or signal anything on the macOS host.
FROM ubuntu:26.04

ARG USER_NAME=claude
ARG USER_UID=501
ARG USER_GID=20
ARG LLVM_VERSION=22

ENV DEBIAN_FRONTEND=noninteractive

# Base tools, Python 3, Node.js, GCC and LLVM/Clang from Ubuntu's own repos.
# /usr/lib/llvm points at the installed LLVM so PATH needs no version number.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates git ripgrep procps less curl jq openssh-client tini unzip \
      wget file zip zstd rsync tree gawk bc tzdata dos2unix sqlite3 \
      vim xxd nano htop lsof strace gdb shellcheck fd-find cmake ninja-build \
      iproute2 iputils-ping netcat-openbsd bind9-dnsutils \
      python3 python3-venv python3-pip \
      nodejs npm \
      libharfbuzz0b libfontconfig1 libfreetype6 libgl1 libx11-6 libxcb1 \
      build-essential pkg-config libssl-dev \
      clang-${LLVM_VERSION} lld-${LLVM_VERSION} llvm-${LLVM_VERSION} lldb-${LLVM_VERSION} \
      clangd-${LLVM_VERSION} clang-format-${LLVM_VERSION} clang-tidy-${LLVM_VERSION} \
      libc++-${LLVM_VERSION}-dev libc++abi-${LLVM_VERSION}-dev \
 && ln -s /usr/lib/llvm-${LLVM_VERSION} /usr/lib/llvm \
 && ln -s /usr/bin/fdfind /usr/local/bin/fd \
 && rm -rf /var/lib/apt/lists/*

# Ubuntu 26.04 ships uutils (Rust) coreutils by default; swap in GNU coreutils
# so scripts and tools that rely on GNU flags and output behave as expected.
RUN apt-get update \
 && apt-get install -y --no-install-recommends --allow-remove-essential coreutils-from-gnu coreutils-from-uutils- \
 && rm -rf /var/lib/apt/lists/*

# AWS CLI v2 from the official installer (the distro package lags behind).
RUN curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o /tmp/awscliv2.zip \
 && unzip -q /tmp/awscliv2.zip -d /tmp \
 && /tmp/aws/install \
 && rm -rf /tmp/aws /tmp/awscliv2.zip

# gh CLI from the official release; likewise, the distro package lags behind.
# Authentication comes at runtime from GH_TOKEN, injected by the wrappers.
RUN GHVER="$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/cli/cli/releases/latest | sed 's#.*/tag/v##')" \
 && curl -fsSL "https://github.com/cli/cli/releases/download/v${GHVER}/gh_${GHVER}_Linux_$(dpkg --print-architecture).tar.gz" -o /tmp/gh.tgz \
 && tar -C /tmp -xz -f /tmp/gh.tgz --wildcards --strip-components=2 "*/bin/gh" \
 && mv /tmp/gh /usr/local/bin/gh \
 && rm -f /tmp/gh.tgz

# Rust via rustup (the distro rustc lags behind). The toolchain lives in the
# image; CARGO_HOME is pointed at /global at runtime (see ENV below) so the
# registry cache and `cargo install` binaries persist between sessions.
ENV RUSTUP_HOME=/usr/local/rustup
RUN curl -fsSL https://sh.rustup.rs \
      | CARGO_HOME=/usr/local/cargo sh -s -- -y --no-modify-path --profile minimal \
          --component rustfmt,clippy \
 && chmod -R a+rX /usr/local/rustup /usr/local/cargo

# Go: latest official release (the distro package lags behind). GOPATH is
# /global/go at runtime, so the module cache and `go install` binaries persist.
RUN GOVER="$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -1)" \
 && curl -fsSL "https://go.dev/dl/${GOVER}.linux-$(dpkg --print-architecture).tar.gz" \
      | tar -C /usr/local -xz

RUN npm install -g @anthropic-ai/claude-code \
 && npm cache clean --force

# Unprivileged user matching the host uid/gid so files written to the mounted
# working directory keep sane ownership. gid 20 (staff on macOS) is "dialout"
# in Ubuntu, so reuse whatever group already has that gid.
RUN (getent group "${USER_GID}" >/dev/null || groupadd -g "${USER_GID}" "${USER_NAME}") \
 && useradd -m -u "${USER_UID}" -g "${USER_GID}" -s /bin/bash "${USER_NAME}"

# Aider is not in the image: bin/install-aider.sh installs it, with its own
# Python 3.12, into /global/aider and links it into /global/bin.
USER ${USER_NAME}
ENV HOME=/home/${USER_NAME} \
    CLAUDE_CONFIG_DIR=/home/${USER_NAME}/.claude \
    DISABLE_AUTOUPDATER=1 \
    NPM_CONFIG_PREFIX=/global/npm \
    CARGO_HOME=/global/cargo \
    GOPATH=/global/go \
    PATH=$PATH:/usr/lib/llvm/bin:/usr/local/cargo/bin:/usr/local/go/bin:/global/bin:/global/npm/bin:/global/cargo/bin:/global/go/bin

# tini reaps zombies and forwards signals to claude.
ENTRYPOINT ["/usr/bin/tini", "--", "claude"]
