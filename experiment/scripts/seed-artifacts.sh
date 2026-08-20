#!/usr/bin/env bash
# Seed the Nexus `devtools` repo with real tool artifacts (simulates the
# trusted build pipeline output), and warm the go-proxy/npm-proxy/pypi-proxy
# caches for the source-built and ecosystem tool types.
# Public internet is used HERE ONLY — afterwards the PoC must work entirely
# against Nexus.
#
# Produces experiment/artifacts.manifest:  <tool> <version> <platform> <sha256> <artifact>
# Runs from a network with internet access; behind a corporate proxy, set the
# standard http_proxy/https_proxy/no_proxy variables — curl and python urllib
# both honor them.
set -euo pipefail

NEXUS_URL=${NEXUS_URL:-http://localhost:8081}
AUTH="admin:${ADMIN_NEW_PW:-admin-mise-vault}"
REPO=devtools
PLATFORM=linux-amd64
MANIFEST="$(cd "$(dirname "$0")/.." && pwd)/artifacts.manifest"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

log() { printf '>>> %s\n' "$*"; }

upload() { # tool version file
  local tool=$1 version=$2 file=$3 name sha dest
  name=$(basename "$file")
  sha=$(sha256sum "$file" | awk '{print $1}')
  dest="$NEXUS_URL/repository/$REPO/$tool/$version/$name"
  if curl -sf -u "$AUTH" -o /dev/null "$dest"; then
    log "$tool $version already in Nexus"
  else
    curl -sf -u "$AUTH" --upload-file "$file" "$dest"
    log "uploaded $tool $version -> $dest"
  fi
  grep -q "^$tool $version $PLATFORM " "$MANIFEST" 2>/dev/null \
    || echo "$tool $version $PLATFORM $sha $name" >> "$MANIFEST"
}

touch "$MANIFEST"

# --- go (runtime distribution; latest two stable) --------------------------
log "resolving go versions from go.dev"
python3 - "$WORK" <<'PY'
import json, sys, urllib.request
work = sys.argv[1]
data = json.load(urllib.request.urlopen("https://go.dev/dl/?mode=json"))
picks = []
for rel in data:            # stable releases, newest first
    for f in rel["files"]:
        if f["os"] == "linux" and f["arch"] == "amd64" and f["kind"] == "archive":
            picks.append((rel["version"].lstrip("go"), f["filename"], f["sha256"]))
            break
    if len(picks) == 2:
        break
with open(f"{work}/go.list", "w") as fh:
    for v, fn, sha in picks:
        fh.write(f"{v} {fn} {sha}\n")
PY
while read -r v fn sha; do
  f="$WORK/$fn"
  log "downloading go $v"
  curl -sfL -o "$f" "https://go.dev/dl/$fn"
  echo "$sha  $f" | sha256sum -c - >/dev/null   # verify against upstream-published sha
  upload go "$v" "$f"
done < "$WORK/go.list"

# --- golangci-lint (latest two releases) -----------------------------------
log "resolving golangci-lint versions from GitHub"
python3 - "$WORK" <<'PY'
import json, sys, urllib.request
work = sys.argv[1]
req = urllib.request.Request(
    "https://api.github.com/repos/golangci/golangci-lint/releases?per_page=10",
    headers={"User-Agent": "mise-vault-experiment"})
rels = [r for r in json.load(urllib.request.urlopen(req)) if not r["prerelease"]][:2]
with open(f"{work}/gcl.list", "w") as fh:
    for r in rels:
        v = r["tag_name"].lstrip("v")
        for a in r["assets"]:
            if a["name"] == f"golangci-lint-{v}-linux-amd64.tar.gz":
                fh.write(f'{v} {a["name"]} {a["browser_download_url"]}\n')
PY
while read -r v name url; do
  f="$WORK/$name"
  log "downloading golangci-lint $v"
  curl -sfL -o "$f" "$url"
  upload golangci-lint "$v" "$f"
done < "$WORK/gcl.list"

# --- glab (latest release, from gitlab.com) ---------------------------------
log "resolving glab version from gitlab.com"
python3 - "$WORK" <<'PY'
import json, sys, urllib.request
work = sys.argv[1]
rels = json.load(urllib.request.urlopen(
    "https://gitlab.com/api/v4/projects/gitlab-org%2Fcli/releases?per_page=5"))
r = rels[0]
v = r["tag_name"].lstrip("v")
want = f"glab_{v}_linux_amd64.tar.gz"
for link in r["assets"]["links"]:
    if link["name"] == want or link["url"].endswith(want):
        with open(f"{work}/glab.list", "w") as fh:
            fh.write(f'{v} {want} {link["url"]}\n')
        break
PY
while read -r v name url; do
  f="$WORK/$name"
  log "downloading glab $v"
  curl -sfL -o "$f" "$url"
  upload glab "$v" "$f"
done < "$WORK/glab.list"

# --- go-proxy cache warming (go-installed tools; catalog/gocensus) ---------
# Unlike the tools above, a go tool has no Nexus artifact to upload: its
# content is the go proxy repository's cache of the real module, fetched
# straight from proxy.golang.org through Nexus. Warming it here means a
# later offline run finds every approved version already cached, the same
# reason the archive tools above are pre-uploaded.
log "warming the go-proxy cache for catalog/gocensus"
GOCENSUS_ROOT="github.com/arloliu/gocensus"
python3 - "$(cd "$(dirname "$0")/../.." && pwd)/catalog/gocensus/versions.json" <<'PY' > "$WORK/gocensus.versions"
import json, sys
for rec in json.load(open(sys.argv[1])):
    print(rec["version"])
PY
# Warming must cover the whole dependency closure, not just the module
# itself:
# installing gocensus later also downloads every module it depends on,
# and any of those missing from the cache would force Nexus to reach
# upstream at install time.
# A real "go install" through the proxy, with a fresh module cache and
# GOPATH, is the only reliable way to pull the full closure through.
GOCENSUS_MODULE="$GOCENSUS_ROOT/cmd/gocensus"
command -v go >/dev/null 2>&1 || {
  echo "ERROR: warming the go-proxy cache needs a go toolchain on PATH" >&2
  exit 1
}
GOWARM=$(mktemp -d)
while read -r v; do
  # -modcacherw keeps the throwaway module cache deletable afterwards
  if GOPROXY="$NEXUS_URL/repository/go-proxy" GONOPROXY=none GOPRIVATE= \
     GOSUMDB=off GOTOOLCHAIN=local GOENV=off GOCACHEPROG= GOFLAGS=-modcacherw \
     GOPATH="$GOWARM/gopath" GOMODCACHE="$GOWARM/modcache" \
     GOCACHE="$GOWARM/gocache" GOBIN="$GOWARM/bin" \
     go install "$GOCENSUS_MODULE@v$v" >/dev/null 2>&1; then
    log "gocensus $v and its full dependency closure cached at go-proxy"
  else
    echo "ERROR: could not warm go-proxy cache for gocensus $v" >&2
    exit 1
  fi
done < "$WORK/gocensus.versions"
rm -rf "$GOWARM"

# --- npm-proxy cache warming (npm-installed tools; catalog/prettier) -------
# Same philosophy as the go-proxy warming above: an npm tool has no Nexus
# artifact to upload, its content is the npm proxy repository's cache of the
# real package document + tarball, fetched straight from registry.npmjs.org
# through Nexus. Warming here means a later offline run finds every approved
# version already cached. prettier has zero runtime dependencies (the
# selection guideline in the design doc), so one real "npm install" pulls
# the whole closure: the package document plus its one tarball.
log "warming the npm-proxy cache for catalog/prettier"
python3 - "$(cd "$(dirname "$0")/../.." && pwd)/catalog/prettier/versions.json" <<'PY' > "$WORK/prettier.versions"
import json, sys
for rec in json.load(open(sys.argv[1])):
    print(rec["version"])
PY
NPM_WARM=$(mktemp -d)
while read -r v; do
  if NPM_CONFIG_UPDATE_NOTIFIER=false NPM_CONFIG_FUND=false NPM_CONFIG_AUDIT=false \
     npm install -g --prefix "$NPM_WARM/prefix" \
       --registry "$NEXUS_URL/repository/npm-proxy/" "prettier@$v" >/dev/null 2>&1; then
    log "prettier $v (package document + tarball) cached at npm-proxy"
  else
    echo "ERROR: could not warm npm-proxy cache for prettier $v" >&2
    exit 1
  fi
  rm -rf "$NPM_WARM/prefix"
done < "$WORK/prettier.versions"
rm -rf "$NPM_WARM"

# --- pypi-proxy cache warming (pypi-installed tools; catalog/ruff) ---------
# ruff installs as one dependency-free prebuilt wheel per platform (the
# selection guideline in the design doc), so a real "pip download" against
# the proxy — same philosophy as the go closure and npm warming above —
# pulls both the simple-API page and the one wheel matching this machine's
# platform, with nothing else to close over.
log "warming the pypi-proxy cache for catalog/ruff"
python3 - "$(cd "$(dirname "$0")/../.." && pwd)/catalog/ruff/versions.json" <<'PY' > "$WORK/ruff.versions"
import json, sys
for rec in json.load(open(sys.argv[1])):
    print(rec["version"])
PY
PYPI_WARM=$(mktemp -d)
while read -r v; do
  if python3 -m pip download --no-deps --no-cache-dir \
       --index-url "$NEXUS_URL/repository/pypi-proxy/simple" \
       --trusted-host "$(python3 -c "import urllib.parse,sys; print(urllib.parse.urlparse(sys.argv[1]).hostname)" "$NEXUS_URL")" \
       -d "$PYPI_WARM/dl" "ruff==$v" >/dev/null 2>&1; then
    log "ruff $v (simple-API page + wheel) cached at pypi-proxy"
  else
    echo "ERROR: could not warm pypi-proxy cache for ruff $v" >&2
    exit 1
  fi
  rm -rf "$PYPI_WARM/dl"
done < "$WORK/ruff.versions"
rm -rf "$PYPI_WARM"

# --- cargo-proxy cache warming (cargo-installed tools; catalog/tokei) ------
# Same philosophy as the go-proxy/npm-proxy/pypi-proxy warming above: a
# cargo tool has no Nexus artifact to upload, its content is the cargo proxy
# repository's cache of the sparse index plus the crate tarballs it proxies,
# fetched straight from index.crates.io through Nexus. Unlike npm/pypi,
# cargo's --locked build pulls its ENTIRE dependency tree (the crate's
# committed Cargo.lock), so a real "cargo install --locked" against the
# proxy, from a scratch CARGO_HOME that source-replaces crates-io with the
# Nexus cargo proxy, is the only reliable way to pull the full closure
# through — mirroring the go-proxy warming's reasoning exactly.
log "warming the cargo-proxy cache for catalog/tokei"
python3 - "$(cd "$(dirname "$0")/../.." && pwd)/catalog/tokei/versions.json" <<'PY' > "$WORK/tokei.versions"
import json, sys
for rec in json.load(open(sys.argv[1])):
    print(rec["version"])
PY
command -v cargo >/dev/null 2>&1 || {
  echo "ERROR: warming the cargo-proxy cache needs a Rust toolchain (cargo) on PATH" >&2
  exit 1
}
CARGO_WARM=$(mktemp -d)
mkdir -p "$CARGO_WARM/home"
cat > "$CARGO_WARM/home/config.toml" <<EOF
[source.crates-io]
replace-with = "nexus-cargo"

[registries.nexus-cargo]
index = "sparse+$NEXUS_URL/repository/cargo-proxy/"
EOF
while read -r v; do
  # RUSTUP_AUTO_INSTALL=0 mirrors the plugin's own pin: a rustup-provided
  # cargo must never reach for a toolchain download while seeding.
  if RUSTUP_AUTO_INSTALL=0 CARGO_HOME="$CARGO_WARM/home" CARGO_NET_RETRY=1 \
     cargo install tokei --version "$v" --locked --root "$CARGO_WARM/install" >/dev/null 2>&1; then
    log "tokei $v and its full dependency closure cached at cargo-proxy"
  else
    echo "ERROR: could not warm cargo-proxy cache for tokei $v" >&2
    exit 1
  fi
  rm -rf "$CARGO_WARM/install"
done < "$WORK/tokei.versions"
rm -rf "$CARGO_WARM"

log "seed complete; manifest:"
column -t "$MANIFEST"
