# Minimal developer-workstation image for offline/CI testing:
# mise + git + curl + coreutils, plus the ecosystem-tool-type runners
# (npm, pipx, uv) the offline gate needs for the npm/pypi tool types.
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
      git curl ca-certificates xz-utils python3 python3-pip python3-venv pipx nodejs npm \
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
