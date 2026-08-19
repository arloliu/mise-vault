#!/usr/bin/env bash
# Seed the Nexus `devtools` repo with real tool artifacts (simulates the
# trusted build pipeline output). Public internet is used HERE ONLY —
# afterwards the PoC must work entirely against Nexus.
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

log "seed complete; manifest:"
column -t "$MANIFEST"
