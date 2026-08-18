# Minimal developer-workstation image for offline/CI testing:
# mise + git + curl + coreutils, nothing else.
#
# Every external source is overridable for private-mirror / proxy builds:
#   --build-arg BASE_IMAGE=harbor.company.example/dockerhub-proxy/ubuntu:24.04
#   --build-arg APT_MIRROR=http://mirror.company.example/ubuntu
#   --build-arg MISE_BINARY_URL=https://nexus.company.example/repository/devtools/mise/v2026.8.1/mise-linux-x64
#   --build-arg MISE_INSTALL_URL=https://mirror.company.example/mise.run
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
 && apt-get install -y --no-install-recommends git curl ca-certificates xz-utils python3 \
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
