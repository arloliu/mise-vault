#!/usr/bin/env bash
# Offline gate: the complete developer flow must work inside a network that can
# reach ONLY the private GitLab and Nexus — no route to the public internet.
# Runs the flow in a container attached solely to the compose 'isolated'
# network (internal: true), using the mise-vault-test image.
set -uo pipefail

NET=mise-vault-experiment_isolated
IMG=mise-vault-test
INNER=$(mktemp /tmp/mise-vault-offline-inner.XXXXXX.sh)
trap 'rm -f "$INNER"' EXIT

cat > "$INNER" <<'INNER_EOF'
#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

export HOME=/root
cat > "$HOME/.netrc" <<NETRC
machine gitlab
  login developer
  password glpat-mise-vault-dev-000001
machine nexus
  login developer
  password dev-mise-vault
NETRC
chmod 600 "$HOME/.netrc"

echo "== 0. the network really is offline =="
curl -m 5 -sf https://github.com -o /dev/null 2>/dev/null \
  && bad "github.com reachable — network is NOT isolated" \
  || ok "github.com unreachable"
curl -m 5 -sf https://proxy.golang.org -o /dev/null 2>/dev/null \
  && bad "proxy.golang.org reachable" || ok "proxy.golang.org unreachable"
curl -m 5 -sf http://gitlab:8929/users/sign_in -o /dev/null \
  && ok "private GitLab reachable" || bad "private GitLab NOT reachable"
curl -m 5 -sfn http://nexus:8081/service/rest/v1/status -o /dev/null \
  && ok "private Nexus reachable" || bad "private Nexus NOT reachable"

echo "== 1. bootstrap from private GitLab only =="
GIT_TERMINAL_PROMPT=0 git clone -q --depth 1 http://gitlab:8929/devtools/mise-vault.git /tmp/bootstrap \
  && /tmp/bootstrap/install.sh > /tmp/install.log 2>&1 \
  && ok "git clone + install.sh (netrc, offline network)" \
  || bad "bootstrap failed: $(tail -2 /tmp/install.log 2>/dev/null | head -c 200)"

# The committed Nexus URL points at the host-side experiment address, which is
# not routable in this container. Use the sanctioned per-tool override channel.
cat > "$HOME/.config/mise/conf.d/mise-vault.toml" <<ALIASES
[tool_alias]
go = "vault:go[nexus_url=http://nexus:8081/repository/devtools]"
golangci-lint = "vault:golangci-lint[nexus_url=http://nexus:8081/repository/devtools]"
glab = "vault:glab[nexus_url=http://nexus:8081/repository/devtools]"
ALIASES

echo "== 2. discovery and install with zero public internet =="
LSR=$(mise ls-remote golangci-lint 2>/dev/null)
[ "$(echo $LSR)" = "2.12.1 2.12.2" ] \
  && ok "ls-remote == catalog" || bad "ls-remote (got: $(echo $LSR | head -c 80))"
mise install glab@1.113.0 >/dev/null 2>&1 \
  && mise exec glab@1.113.0 -- glab --version 2>/dev/null | grep -qi 1.113.0 \
  && ok "glab installed and runs (download from private Nexus, sha verified)" \
  || bad "glab install"
mise install go@1.26.6 >/dev/null 2>&1 \
  && mise exec go@1.26.6 -- go version 2>/dev/null | grep -q go1.26.6 \
  && ok "go runtime installed and runs" || bad "go install"

echo "== 3. catalog-only policy holds offline =="
JQOUT=$(timeout 30 mise ls-remote jq 2>&1 || true)
echo "$JQOUT" | grep -q "none of its backends" \
  && ok "uncataloged tool blocked" || bad "jq not blocked ($(echo $JQOUT | head -c 100))"

echo "== 4. MISE_OFFLINE=1 behavior (documenting, not gating) =="
MISE_OFFLINE=1 mise ls-remote glab 2>/dev/null | grep -qx 1.113.0 \
  && ok "MISE_OFFLINE=1: ls-remote still serves the local catalog" \
  || bad "MISE_OFFLINE=1 broke catalog listing"
rm -rf "$HOME/.local/share/mise/installs/golangci-lint" 2>/dev/null
if MISE_OFFLINE=1 mise install golangci-lint@2.12.2 >/dev/null 2>&1; then
  echo "  INFO  MISE_OFFLINE=1 does NOT block the plugin's own download (curl via cmd)"
else
  echo "  INFO  MISE_OFFLINE=1 blocks backend-plugin installs"
fi

echo
echo "OFFLINE RESULT: $PASS passed, $FAIL failed"
exit $([ "$FAIL" = 0 ] && echo 0 || echo 1)
INNER_EOF
chmod +x "$INNER"

docker run --rm --network "$NET" \
  -v "$INNER":/inner.sh:ro \
  "$IMG" bash /inner.sh
