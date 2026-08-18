#!/usr/bin/env bash
# mise-vault PoC test matrix: plugin behavior against the local Docker stack.
# Runs entirely inside an isolated HOME so the real machine config is untouched.
# Requires: experiment stack up + provisioned + seeded; plugin repo tagged v0.0.3/v0.0.4.
set -uo pipefail

GITLAB=http://127.0.0.3:8929           # distinct loopback IPs => distinct netrc machines
NEXUS=http://127.0.0.2:8081
PLUGIN_URL="$GITLAB/devtools/mise-vault.git"

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

echo "== Phase 1: plugin install (netrc only, no token in URL, gix=false) =="
mise plugin install vault "$PLUGIN_URL#v0.0.3" >/dev/null 2>&1 \
  && ok "mise plugin install vault <url>#v0.0.3 via netrc" \
  || bad "mise plugin install vault <url>#v0.0.3 via netrc"
mise plugins ls 2>/dev/null | grep -q vault && ok "plugin registered" || bad "plugin registered"

echo "== Phase 2: version discovery (catalog only) =="
LSR=$(mise ls-remote vault:golangci-lint 2>/dev/null)
[ "$(printf '%s\n' "$LSR" | tr '\n' ' ')" = "2.12.1 2.12.2 " ] \
  && ok "ls-remote vault:golangci-lint == exactly catalog (2.12.1 2.12.2)" \
  || bad "ls-remote vault:golangci-lint (got: $(echo $LSR))"
mise ls-remote vault:smoke 2>/dev/null | grep -q . \
  && bad "smoke must NOT be listed at v0.0.3" || ok "smoke absent at catalog v0.0.3"

echo "== Phase 3: short-name aliases (conf.d) =="
LSR2=$(mise ls-remote golangci-lint 2>/dev/null)
[ "$(printf '%s\n' "$LSR2" | tr '\n' ' ')" = "2.12.1 2.12.2 " ] \
  && ok "ls-remote golangci-lint (short name) routed to vault backend" \
  || bad "ls-remote golangci-lint short name (got: $(echo $LSR2))"
LSGO=$(mise ls-remote go 2>/dev/null)
echo "$LSGO" | grep -qx "1.26.6" && ! echo "$LSGO" | grep -q "^1.24" \
  && ok "ls-remote go shows only catalog versions (core backend shadowed)" \
  || bad "ls-remote go (got: $(echo $LSGO | head -c 120))"

echo "== Phase 4: installs (download via curl -n + sha256 + extract) =="
check "install golangci-lint@2.12.2 (nested archive, strip=1)" mise install golangci-lint@2.12.2
mise exec golangci-lint@2.12.2 -- golangci-lint version 2>/dev/null | grep -q "2.12.2" \
  && ok "golangci-lint runs and reports 2.12.2" || bad "golangci-lint version check"
check "install glab@1.113.0 (bin/ layout, strip=0)" mise install glab@1.113.0
mise exec glab@1.113.0 -- glab --version 2>/dev/null | grep -qi "1.113.0" \
  && ok "glab runs and reports 1.113.0" || bad "glab version check"
check "install go@1.26.6 (runtime distribution)" mise install go@1.26.6
GOV=$(mise exec go@1.26.6 -- go version 2>/dev/null)
echo "$GOV" | grep -q "go1.26.6" && ok "go runs: $GOV" || bad "go version check (got: $GOV)"
GOROOT_OUT=$(mise exec go@1.26.6 -- sh -c 'echo $GOROOT' 2>/dev/null)
[ -n "$GOROOT_OUT" ] && [ -d "$GOROOT_OUT/src" ] \
  && ok "GOROOT exported and valid ($GOROOT_OUT)" || bad "GOROOT (got: '$GOROOT_OUT')"

echo "== Phase 5: .tool-versions compatibility (asdf golang name) =="
PROJ="$T/proj"; mkdir -p "$PROJ"
printf 'golang 1.26.6\ngolangci-lint 2.12.2\n' > "$PROJ/.tool-versions"
(cd "$PROJ" && mise trust -q 2>/dev/null; V=$(mise exec -- go version 2>/dev/null); echo "$V" | grep -q go1.26.6) \
  && ok ".tool-versions 'golang 1.26.6' resolves through vault backend" \
  || bad ".tool-versions golang chain"

echo "== Phase 6: fail-closed =="
check_fail "unknown tool rejected (vault:foo)" mise install vault:foo@1.0.0
check_fail "unapproved version rejected (golangci-lint@9.9.9)" mise install golangci-lint@9.9.9

echo "== Phase 7: catalog update v0.0.3 -> v0.0.4 + checksum failure =="
mise plugin install -f vault "$PLUGIN_URL#v0.0.4" >/dev/null 2>&1 \
  && ok "plugin re-pin to v0.0.4 (catalog update)" || bad "plugin re-pin to v0.0.4"
mise ls-remote smoke 2>/dev/null | grep -qx "0.0.1" \
  && ok "new tool 'smoke' appears after catalog update" || bad "smoke not visible after update"
OUT=$(mise install smoke@0.0.1 2>&1)
if [ $? -ne 0 ] && echo "$OUT" | grep -qi "sha-256\|sha256"; then
  ok "checksum mismatch aborts install with explicit error"
else
  bad "checksum mismatch handling (exit=$?; out: $(echo $OUT | head -c 150))"
fi

echo "== Phase 8: auto-install behavior (fresh HOME, alias only, no plugin) =="
T2=$(mktemp -d /tmp/mise-vault-poc2.XXXXXX)
HOME="$T2" bash -c '
  mkdir -p "$HOME/.config/mise/conf.d"
  printf "[settings]\ngix = false\nlibgit2 = false\n" > "$HOME/.config/mise/config.toml"
  printf "[tool_alias]\nglab = \"vault:glab\"\n" > "$HOME/.config/mise/conf.d/mise-vault.toml"
  mise ls-remote glab
' >"$T/autoinstall.log" 2>&1
if grep -qx "1.113.0" "$T/autoinstall.log"; then
  ok "EMPIRICAL ANSWER: alias to uninstalled plugin AUTO-INSTALLS (unexpected)"
else
  ok "EMPIRICAL ANSWER: alias to uninstalled plugin does NOT auto-install -> bootstrap must pre-install (log tail: $(tail -1 "$T/autoinstall.log" | head -c 120))"
fi
rm -rf "$T2"

echo "== Phase 9: unsupported platform fails closed (linked plugin + fixture) =="
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
T3=$(mktemp -d /tmp/mise-vault-poc3.XXXXXX)
PLUG="$T3/plugin"
mkdir -p "$PLUG"
cp -r "$REPO_ROOT/metadata.lua" "$REPO_ROOT/hooks" "$REPO_ROOT/lib" "$REPO_ROOT/config" "$REPO_ROOT/catalog" "$PLUG/"
cp -r "$REPO_ROOT/tests/fixtures/catalog/darwin-only" "$PLUG/catalog/"
HOME="$T3" bash -c '
  mkdir -p "$HOME/.config/mise"
  printf "[settings]\ngix = false\nlibgit2 = false\n" > "$HOME/.config/mise/config.toml"
  mise plugins link vault "'"$PLUG"'" >/dev/null 2>&1
  mise ls-remote vault:darwin-only 2>/dev/null | grep -qx 1.0.0 || exit 2
  OUT=$(mise install vault:darwin-only@1.0.0 2>&1 || true)
  echo "$OUT" | grep -q "not available for linux-amd64" || { echo "$OUT" | tail -2; exit 3; }
'
case $? in
  0) ok "darwin-only tool listed, install rejected: not available for linux-amd64" ;;
  2) bad "fixture tool not listed via linked plugin" ;;
  *) bad "unsupported-platform error message wrong" ;;
esac
rm -rf "$T3"

echo
echo "RESULT: $PASS passed, $FAIL failed   (test HOME: $T — kept for inspection if failures)"
[ "$FAIL" = 0 ] && rm -rf "$T"
exit $([ "$FAIL" = 0 ] && echo 0 || echo 1)
