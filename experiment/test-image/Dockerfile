# Minimal developer-workstation image for offline/CI testing:
# mise + git + curl + coreutils, plus the ecosystem-tool-type runners
# (npm, pipx, uv, cargo, bun) the offline gate needs for the npm/pypi/cargo
# tool types.
# Toolchains are deliberately image-build-time installs, not vault-managed
# (cargo/npm/uv/pipx are the user's own responsibility, not the plugin's) —
# this mirrors a real workstation that already has them, the same way mise
# itself is installed here rather than vault-distributed.
#
# Every external source is overridable for private-mirror / proxy builds:
#   --build-arg BASE_IMAGE=harbor.company.example/dockerhub-proxy/ubuntu:24.04
#   --build-arg APT_MIRROR=http://mirror.company.example/ubuntu
#   --build-arg MISE_BINARY_URL=https://nexus.company.example/repository/devtools/mise/v2026.8.1/mise-linux-x64
#   --build-arg MISE_INSTALL_URL=https://mirror.company.example/mise.run
#   --build-arg UV_INSTALL_URL=https://mirror.company.example/uv-install.sh
#   --build-arg RUSTUP_INSTALL_URL=https://mirror.company.example/rustup-init.sh
#   --build-arg BUN_INSTALL_URL=https://mirror.company.example/bun-install.sh
# Standard proxy build args (http_proxy/https_proxy/no_proxy) are honored by
# apt and curl automatically when passed with --build-arg.
ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}

ARG APT_MIRROR=""
RUN if [ -n "$APT_MIRROR" ]; then \
      sed -i "s|http://archive.ubuntu.com/ubuntu|$APT_MIRROR|g; s|http://security.ubuntu.com/ubuntu|$APT_MIRROR|g" \
        /etc/apt/sources.list.d/ubuntu.sources; \
    fi \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      git curl ca-certificates xz-utils python3 python3-pip python3-venv pipx nodejs npm gcc libc6-dev unzip \
 && rm -rf /var/lib/apt/lists/*

# Prefer a directly hosted mise binary (fully private); fall back to the
# install script (public mise.run by default, or an internal mirror of it).
ARG MISE_BINARY_URL=""
ARG MISE_INSTALL_URL="https://mise.run"
RUN if [ -n "$MISE_BINARY_URL" ]; then \
      curl -fsSL -o /usr/local/bin/mise "$MISE_BINARY_URL" && chmod +x /usr/local/bin/mise; \
    else \
      curl -fsSL "$MISE_INSTALL_URL" | MISE_INSTALL_PATH=/usr/local/bin/mise sh; \
    fi \
 && mise --version

# uv has no Ubuntu 24.04 apt package; install via its official script (or a
# mirror of it), pinned straight to /usr/local/bin so it lands on PATH with
# no shell-profile step required.
ARG UV_INSTALL_URL="https://astral.sh/uv/install.sh"
RUN curl -fsSL "$UV_INSTALL_URL" | UV_INSTALL_DIR=/usr/local/bin sh \
 && uv --version \
 && npm --version \
 && pipx --version

# bun: no Ubuntu 24.04 apt package; install via its official script (or a
# mirror of it). The installer places the binary at $BUN_INSTALL/bin/bun,
# so BUN_INSTALL=/usr/local lands it at /usr/local/bin/bun — on PATH under
# any runtime $HOME, no shell-profile step required. It downloads a zip,
# which is why unzip is in the apt list above.
ARG BUN_INSTALL_URL="https://bun.sh/install"
RUN curl -fsSL "$BUN_INSTALL_URL" | BUN_INSTALL=/usr/local bash \
 && bun --version

# cargo: Ubuntu 24.04's apt rustc/cargo (1.75.0) is too old to build tokei
# 14.0.0 — verified empirically: `cargo install tokei --version 14.0.0
# --locked` fails with "package `clap-cargo v0.18.3` cannot be built because
# it requires rustc 1.86 or newer, while the currently active rustc version
# is 1.75.0". A rustup-installed stable toolchain (verified: 1.97.1 at the
# time of writing) builds it in well under a minute against a warm proxy
# cache.
#
# RUSTUP_HOME is pinned system-wide (independent of which $HOME a test run
# uses) because it holds TOOLCHAIN state — which stable release is
# installed — a system-level concern for this image, not something a test's
# throwaway $HOME should affect. CARGO_HOME is deliberately left UNSET,
# so it falls back to cargo's own default of $HOME/.cargo at runtime: that
# is exactly the channel the plugin's registry configuration lives on
# (~/.cargo/config.toml source replacement, design doc section 5), and
# pinning CARGO_HOME here would silently make the plugin's own registry
# config unreadable — verified empirically: with CARGO_HOME pinned to a
# fixed system directory, `cargo install` ignored a ~/.cargo/config.toml
# written under a different $HOME entirely and tried to reach
# index.crates.io directly instead of the Nexus proxy.
# The rustup-installed shim binaries (cargo, rustc, ...) land under
# /root/.cargo/bin at build time (root's $HOME here); that fixed path is
# added to PATH explicitly so the binaries stay reachable under ANY
# runtime $HOME, the same way mise's own install above is reachable
# regardless of $HOME.
# gcc + libc6-dev (not the much larger build-essential) are enough for the
# one C linker cargo needs — verified empirically against this same tokei
# build, keeping image bloat to two apt packages instead of a full build
# toolchain. libc6-dev must be named explicitly: this image installs with
# --no-install-recommends, and gcc only RECOMMENDS libc6-dev rather than
# depending on it, so without it the link step fails to find crt1.o/crti.o
# and the C runtime libraries (observed empirically as exactly that error).
ARG RUSTUP_INSTALL_URL="https://sh.rustup.rs"
ENV RUSTUP_HOME=/root/.rustup \
    PATH=/root/.cargo/bin:$PATH
RUN curl -fsSL "$RUSTUP_INSTALL_URL" | sh -s -- -y --profile minimal --default-toolchain stable \
 && rustc --version \
 && cargo --version
