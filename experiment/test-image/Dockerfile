# Minimal developer-workstation image for offline/CI testing:
# mise + git + curl + coreutils, nothing else.
FROM ubuntu:24.04
RUN apt-get update \
 && apt-get install -y --no-install-recommends git curl ca-certificates xz-utils python3 \
 && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh \
 && mise --version
