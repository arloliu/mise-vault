#!/usr/bin/env bash
# One-time: fetch linux-arm64 and darwin-arm64 artifacts for the seeded tools
# and upload them to the experiment Nexus. Public internet is used HERE ONLY.
# Appends to experiment/artifacts.manifest (tool version platform sha256 file).
set -euo pipefail
NEXUS_URL=${NEXUS_URL:-http://127.0.0.2:8081}
AUTH="admin:${ADMIN_NEW_PW:-admin-mise-vault}"
MANIFEST="$(cd "$(dirname "$0")/.." && pwd)/artifacts.manifest"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
log() { printf '>>> %s\n' "$*"; }

upload() { # tool version platform file
  local tool=$1 version=$2 platform=$3 file=$4 name sha dest
  name=$(basename "$file"); sha=$(sha256sum "$file" | awk '{print $1}')
  dest="$NEXUS_URL/repository/devtools/$tool/$version/$name"
  curl -sf -u "$AUTH" -o /dev/null "$dest" || curl -sf -u "$AUTH" --upload-file "$file" "$dest"
  grep -q "^$tool $version $platform " "$MANIFEST" || echo "$tool $version $platform $sha $name" >> "$MANIFEST"
  log "$tool $version $platform -> $name"
}

# versions already in the catalog (keep in sync with catalog/*/versions.json)
GO_VERSIONS="1.25.13 1.26.6"; GCL_VERSIONS="2.12.1 2.12.2"; GLAB_VERSIONS="1.113.0"

for v in $GO_VERSIONS; do
  for pf in "linux-arm64:linux-arm64" "darwin-arm64:darwin-arm64"; do
    plat=${pf%%:*}; up=${pf##*:}
    f="$WORK/go$v.$up.tar.gz"
    curl -sfL -o "$f" "https://go.dev/dl/go$v.$up.tar.gz"
    upload go "$v" "$plat" "$f"
  done
done

for v in $GCL_VERSIONS; do
  for pf in "linux-arm64:linux-arm64" "darwin-arm64:darwin-arm64"; do
    plat=${pf%%:*}; up=${pf##*:}
    f="$WORK/golangci-lint-$v-$up.tar.gz"
    curl -sfL -o "$f" "https://github.com/golangci/golangci-lint/releases/download/v$v/golangci-lint-$v-$up.tar.gz"
    upload golangci-lint "$v" "$plat" "$f"
  done
done

for v in $GLAB_VERSIONS; do
  # discover glab's actual asset names per platform (naming differs per OS)
  python3 - "$v" "$WORK" <<'PY'
import json, sys, urllib.request
v, work = sys.argv[1], sys.argv[2]
rels = json.load(urllib.request.urlopen(
    "https://gitlab.com/api/v4/projects/gitlab-org%2Fcli/releases?per_page=20"))
rel = next(r for r in rels if r["tag_name"].lstrip("v") == v)
names = [l["name"] for l in rel["assets"]["links"]]
wanted = {"linux-arm64": ["linux_arm64.tar.gz"],
          "darwin-arm64": ["darwin_arm64.tar.gz", "macos_arm64.tar.gz"]}
with open(f"{work}/glab.list", "w") as fh:
    for plat, sufs in wanted.items():
        m = [ (l["name"], l["url"]) for l in rel["assets"]["links"]
              for s in sufs if l["name"].endswith(s) ]
        if m:
            fh.write(f"{plat} {m[0][0]} {m[0][1]}\n")
        else:
            print(f"warn: no asset for {plat}; available: {names}", file=sys.stderr)
PY
  while read -r plat name url; do
    f="$WORK/$name"; curl -sfL -o "$f" "$url"
    upload glab "$v" "$plat" "$f"
  done < "$WORK/glab.list"
done

log "done; manifest now:"
column -t "$MANIFEST"
