#!/usr/bin/env bash
# mise-vault PoC test matrix: plugin behavior against the local Docker stack.
# Runs entirely inside an isolated HOME so the real machine config is untouched.
#
# Structure:
#   Phase 1 exercises the plugin LIFECYCLE (install / re-pin over git + netrc)
#   using pinned experiment tags (defaults v0.0.3 / v0.0.4; override with
#   EXPERIMENT_TAG_A / EXPERIMENT_TAG_B).
#   Phase 2 then links the CURRENT WORKING TREE as the plugin, so every
#   behavior check from phase 3 on runs the exact code under review —
#   the reviewed commit is printed and never hidden behind a stale tag.
#
# Requires: experiment stack up + provisioned + seeded; the lifecycle tags present.
set -uo pipefail

GITLAB=http://127.0.0.3:8929           # distinct loopback IPs => distinct netrc machines
NEXUS=http://127.0.0.2:8081
PLUGIN_URL="$GITLAB/devtools/mise-vault.git"
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# immutable experiment tags used only by the lifecycle phase; override when a
# fresh experiment GitLab carries different tags
TAG_A=${EXPERIMENT_TAG_A:-v0.0.3}
TAG_B=${EXPERIMENT_TAG_B:-v0.0.4}

# expected versions come from the working-tree catalog, so approving a new
# version never requires editing this suite
cat_versions() { # cat_versions <tool> -> all approved versions, space-separated
  python3 -c "import json,sys; print(' '.join(r['version'] for r in json.load(open(sys.argv[1]))))" \
    "$REPO_ROOT/catalog/$1/versions.json"
}
cat_latest() { # cat_latest <tool> -> newest approved version
  python3 -c "import json,sys; print(json.load(open(sys.argv[1]))[-1]['version'])" \
    "$REPO_ROOT/catalog/$1/versions.json"
}
GCL_ALL=$(cat_versions golangci-lint)
GCL_V=$(cat_latest golangci-lint)
GLAB_V=$(cat_latest glab)
GO_V=$(cat_latest go)

T=$(mktemp -d /tmp/mise-vault-poc.XXXXXX)
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
check() { # check <desc> <cmd...>
  local desc=$1; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}
check_fail() { # must fail
  local desc=$1; shift
  if "$@" >/dev/null 2>&1; then bad "$desc (unexpectedly succeeded)"; else ok "$desc"; fi
}

# --- isolated HOME ---------------------------------------------------------
export HOME="$T"
unset MISE_DATA_DIR MISE_CONFIG_DIR MISE_CACHE_DIR MISE_STATE_DIR MISE_GLOBAL_CONFIG_FILE 2>/dev/null
mkdir -p "$T/.config/mise/conf.d"

cat > "$T/.netrc" <<NETRC
machine 127.0.0.3
  login developer
  password glpat-mise-vault-dev-000001
machine 127.0.0.2
  login developer
  password dev-mise-vault
NETRC
chmod 600 "$T/.netrc"

# user-scoped settings a real bootstrap would write
cat > "$T/.config/mise/config.toml" <<TOML
[settings]
gix = false
libgit2 = false
TOML

# the generated conf.d file (aliases + nexus_url option per tool)
cat > "$T/.config/mise/conf.d/mise-vault.toml" <<TOML
[tool_alias]
go = "vault:go"
glab = "vault:glab"
smoke = "vault:smoke"
# one alias keeps an explicit URL option to cover the override channel
golangci-lint = "vault:golangci-lint[nexus_url=$NEXUS/repository/devtools]"
TOML

echo "== Phase 1: plugin lifecycle over git (netrc, tags $TAG_A -> $TAG_B) =="
mise plugin install vault "$PLUGIN_URL#$TAG_A" >/dev/null 2>&1 \
  && ok "mise plugin install vault <url>#$TAG_A via netrc" \
  || bad "mise plugin install vault <url>#$TAG_A via netrc"
mise plugins ls 2>/dev/null | grep -q vault && ok "plugin registered" || bad "plugin registered"
mise ls-remote vault:smoke 2>/dev/null | grep -q . \
  && bad "smoke must NOT be listed at $TAG_A" || ok "smoke absent at catalog $TAG_A"
mise plugin install -f vault "$PLUGIN_URL#$TAG_B" >/dev/null 2>&1 \
  && ok "plugin re-pin to $TAG_B (catalog update)" || bad "plugin re-pin to $TAG_B"
mise ls-remote smoke 2>/dev/null | grep -qx "0.0.1" \
  && ok "new tool 'smoke' appears after catalog update" || bad "smoke not visible after update"

echo "== Phase 2: link the working tree — everything below tests the code under review =="
REVIEWED=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "unknown")
echo "  reviewed commit: $REVIEWED (plus any uncommitted changes in the working tree)"
PLUG="$T/plugin"
mkdir -p "$PLUG"
cp -r "$REPO_ROOT/metadata.lua" "$REPO_ROOT/hooks" "$REPO_ROOT/lib" "$REPO_ROOT/config" "$REPO_ROOT/catalog" "$PLUG/"
# fixtures: darwin-only (unsupported platform) and smoke (deliberately wrong sha256)
cp -r "$REPO_ROOT/tests/fixtures/catalog/darwin-only" "$PLUG/catalog/"
cp -r "$REPO_ROOT/tests/fixtures/catalog/smoke" "$PLUG/catalog/"
mise plugins uninstall vault >/dev/null 2>&1
mise plugins link vault "$PLUG" >/dev/null 2>&1 \
  && ok "working tree linked as the vault plugin" || bad "linking working tree failed"

echo "== Phase 3: version discovery + short-name aliases (catalog only) =="
LSR=$(mise ls-remote vault:golangci-lint 2>/dev/null)
[ "$(echo $LSR)" = "$GCL_ALL" ] \
  && ok "ls-remote vault:golangci-lint == exactly catalog ($GCL_ALL)" \
  || bad "ls-remote vault:golangci-lint (got: $(echo $LSR))"
LSR2=$(mise ls-remote golangci-lint 2>/dev/null)
[ "$(echo $LSR2)" = "$GCL_ALL" ] \
  && ok "ls-remote golangci-lint (short name) routed to vault backend" \
  || bad "ls-remote golangci-lint short name (got: $(echo $LSR2))"
LSGO=$(mise ls-remote go 2>/dev/null)
echo "$LSGO" | grep -qx "$GO_V" && ! echo "$LSGO" | grep -q "^1.24" \
  && ok "ls-remote go shows only catalog versions (core backend shadowed)" \
  || bad "ls-remote go (got: $(echo $LSGO | head -c 120))"

echo "== Phase 4: installs (download via curl -n + sha256 + extract) =="
check "install golangci-lint@$GCL_V (nested archive, strip=1)" mise install "golangci-lint@$GCL_V"
mise exec "golangci-lint@$GCL_V" -- golangci-lint version 2>/dev/null | grep -q "$GCL_V" \
  && ok "golangci-lint runs and reports $GCL_V" || bad "golangci-lint version check"
check "install glab@$GLAB_V (bin/ layout, strip=0)" mise install "glab@$GLAB_V"
mise exec "glab@$GLAB_V" -- glab --version 2>/dev/null | grep -qi "$GLAB_V" \
  && ok "glab runs and reports $GLAB_V" || bad "glab version check"
check "install go@$GO_V (runtime distribution)" mise install "go@$GO_V"
GOV=$(mise exec "go@$GO_V" -- go version 2>/dev/null)
echo "$GOV" | grep -q "go$GO_V" && ok "go runs: $GOV" || bad "go version check (got: $GOV)"
GOROOT_OUT=$(mise exec "go@$GO_V" -- sh -c 'echo $GOROOT' 2>/dev/null)
[ -n "$GOROOT_OUT" ] && [ -d "$GOROOT_OUT/src" ] \
  && ok "GOROOT exported and valid ($GOROOT_OUT)" || bad "GOROOT (got: '$GOROOT_OUT')"

echo "== Phase 5: .tool-versions compatibility (asdf golang name) =="
PROJ="$T/proj"; mkdir -p "$PROJ"
printf "golang $GO_V\ngolangci-lint $GCL_V\n" > "$PROJ/.tool-versions"
(cd "$PROJ" && mise trust -q 2>/dev/null; V=$(mise exec -- go version 2>/dev/null); echo "$V" | grep -q "go$GO_V") \
  && ok ".tool-versions 'golang $GO_V' resolves through vault backend" \
  || bad ".tool-versions golang chain"

echo "== Phase 6: fail-closed =="
check_fail "unknown tool rejected (vault:foo)" mise install vault:foo@1.0.0
check_fail "unapproved version rejected (golangci-lint@9.9.9)" mise install golangci-lint@9.9.9
OUT=$(mise install vault:darwin-only@1.0.0 2>&1)
[ $? -ne 0 ] && echo "$OUT" | grep -q "not available for linux-amd64" \
  && ok "darwin-only tool rejected: not available for linux-amd64" \
  || bad "unsupported-platform handling (out: $(echo $OUT | head -c 150))"
OUT=$(mise install smoke@0.0.1 2>&1)
if [ $? -ne 0 ] && echo "$OUT" | grep -qi "sha-256\|sha256"; then
  ok "checksum mismatch aborts install with explicit error"
else
  bad "checksum mismatch handling (exit=$?; out: $(echo $OUT | head -c 150))"
fi

echo "== Phase 7: redirect refusal + successful single-binary install =="
# correct the smoke fixture's sha256 in the LINKED catalog so the only thing
# standing between mise and a successful install is the transport policy
REAL_SHA=$(curl -fsSn "$NEXUS/repository/devtools/smoke/0.0.1/smoke-0.0.1.txt" | sha256sum | awk '{print $1}')
python3 - "$PLUG/catalog/smoke/versions.json" "$REAL_SHA" <<'PY'
import json, sys
path, sha = sys.argv[1], sys.argv[2]
recs = json.load(open(path))
recs[0]["platforms"]["linux-amd64"]["sha256"] = sha
json.dump(recs, open(path, "w"), indent=2)
PY
# a server that answers every request with a redirect TO THE REAL NEXUS:
# if the plugin followed redirects this install would succeed, so a failure
# here proves redirects are refused, not merely that the target was down.
# Every request path is appended to a log so the test can prove the plugin
# actually reached this server before it failed.
REDIR_LOG="$T/redirect-requests.log"
: > "$REDIR_LOG"
python3 - "$REDIR_LOG" <<'PY' &
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
log_path = sys.argv[1]
class H(BaseHTTPRequestHandler):
    def redirect(self):
        with open(log_path, "a") as f:
            f.write(self.path + "\n")
        self.send_response(302)
        self.send_header("Location", "http://127.0.0.2:8081" + self.path)
        self.end_headers()
    do_GET = redirect
    do_HEAD = redirect
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", 18082), H).serve_forever()
PY
REDIR_PID=$!
trap 'kill $REDIR_PID 2>/dev/null' EXIT
# readiness handshake: the server must answer 302 before the test proceeds
READY=""
for _ in $(seq 1 40); do
  CODE=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18082/ready 2>/dev/null)
  [ "$CODE" = "302" ] && READY=yes && break
  sleep 0.25
done
[ -n "$READY" ] && ok "redirect server is up and answering 302" \
  || bad "redirect server did not come up on 127.0.0.1:18082"
sed -i 's|^smoke = .*|smoke = "vault:smoke[nexus_url=http://127.0.0.1:18082/repository/devtools]"|' \
  "$T/.config/mise/conf.d/mise-vault.toml"
OUT=$(mise install smoke@0.0.1 2>&1)
INSTALL_EXIT=$?
if [ $INSTALL_EXIT -ne 0 ] \
  && grep -q "smoke-0.0.1.txt" "$REDIR_LOG" \
  && echo "$OUT" | grep -qi "redirect\|unavailable\|could not be downloaded"; then
  ok "redirect from the artifact server aborts the install (request logged, redirect refused)"
else
  bad "redirect handling (exit=$INSTALL_EXIT; server saw: $(tr '\n' ' ' < "$REDIR_LOG" | head -c 120); out: $(echo $OUT | head -c 200))"
fi
kill $REDIR_PID 2>/dev/null
sed -i 's|^smoke = .*|smoke = "vault:smoke"|' "$T/.config/mise/conf.d/mise-vault.toml"
check "install smoke@0.0.1 (single-binary format, correct sha256)" mise install smoke@0.0.1
SMOKE_BIN=$(mise where smoke@0.0.1 2>/dev/null)/smoke
[ -x "$SMOKE_BIN" ] && ok "binary installed executable at \$install_path/smoke" \
  || bad "binary install layout (expected executable: $SMOKE_BIN)"

echo "== Phase 8: an alias to an uninstalled plugin must NOT auto-install it =="
# bootstrap pre-installs the plugin because of exactly this behavior;
# if mise ever starts auto-installing here, bootstrap's assumptions change
T2=$(mktemp -d /tmp/mise-vault-poc2.XXXXXX)
HOME="$T2" bash -c '
  mkdir -p "$HOME/.config/mise/conf.d"
  printf "[settings]\ngix = false\nlibgit2 = false\n" > "$HOME/.config/mise/config.toml"
  printf "[tool_alias]\nglab = \"vault:glab\"\n" > "$HOME/.config/mise/conf.d/mise-vault.toml"
  mise ls-remote glab
' >"$T/autoinstall.log" 2>&1
if grep -qx "$GLAB_V" "$T/autoinstall.log"; then
  bad "alias to uninstalled plugin AUTO-INSTALLED — bootstrap's pre-install assumption no longer holds"
else
  ok "alias to uninstalled plugin does not auto-install (bootstrap must pre-install)"
fi
rm -rf "$T2"

echo
echo "RESULT: $PASS passed, $FAIL failed   (test HOME: $T — kept for inspection if failures)"
[ "$FAIL" = 0 ] && rm -rf "$T"
exit $([ "$FAIL" = 0 ] && echo 0 || echo 1)
