#!/usr/bin/env bash
# mise-vault bootstrap: one-time workstation setup for the private tool backend.
#
# Intended invocation — pinned to an immutable release tag, netrc-authenticated.
# NOTE: GitLab's /-/raw/ web route does NOT accept token auth on private projects
# (verified: basic auth, PRIVATE-TOKEN header, and ?private_token= all redirect
# to sign-in). Bootstrap therefore goes through git, which rides ~/.netrc:
#
#   git clone -q --depth 1 -b vX.Y.Z \
#       https://gitlab.company.example/devtools/mise-vault.git /tmp/mise-vault-bootstrap
#   /tmp/mise-vault-bootstrap/install.sh
#
# Token-based alternative (CI / environments with $GITLAB_TOKEN):
#
#   curl -fsSL --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
#       "https://gitlab.company.example/api/v4/projects/devtools%2Fmise-vault/repository/files/install.sh/raw?ref=vX.Y.Z" | bash
#
# What it does (idempotent — safe to re-run):
#   1. verify prerequisites (mise, git, curl, sha256 tool)
#   2. write user-scoped mise settings: gix=false, libgit2=false, so plugin git
#      operations use the real git binary and its credential chain (~/.netrc)
#   3. install the vault backend plugin pinned to a release tag
#   4. generate ~/.config/mise/conf.d/mise-vault.toml via vault-sync
#   5. smoke-test version discovery through a short name
#
# Configuration (release process stamps the defaults; env overrides for testing):
#   MISE_VAULT_REPO_URL  git URL of this repository
#   MISE_VAULT_REF       release tag to pin
set -euo pipefail

REPO_URL="${MISE_VAULT_REPO_URL:-https://gitlab.company.example/devtools/mise-vault.git}"
REF="${MISE_VAULT_REF:-v0.0.5}"
PLUGIN_NAME=vault
DATA_DIR="${MISE_DATA_DIR:-$HOME/.local/share/mise}"
PLUGIN_DIR="$DATA_DIR/plugins/$PLUGIN_NAME"

say()  { printf 'mise-vault install: %s\n' "$*"; }
fail() { printf 'mise-vault install: ERROR: %s\n' "$*" >&2; exit 1; }

# --- 1. prerequisites --------------------------------------------------------
command -v mise >/dev/null || fail "mise is not installed (see the company mise onboarding page)"
command -v git  >/dev/null || fail "git is required"
command -v curl >/dev/null || fail "curl is required"
command -v sha256sum >/dev/null || command -v shasum >/dev/null \
    || fail "sha256sum (Linux) or shasum (macOS) is required"
say "prerequisites ok (mise $(mise --version 2>/dev/null | head -1))"

# --- 2. user-scoped settings ----------------------------------------------------
# `mise settings <key>=<value>` writes to the user's global config.
mise settings gix=false
mise settings libgit2=false
say "settings: gix=false libgit2=false (plugin git ops use the system git + its credential chain)"

# --- 3. plugin pinned to a release tag ----------------------------------------
say "installing plugin $PLUGIN_NAME from $REPO_URL#$REF ..."
mise plugin install -f "$PLUGIN_NAME" "$REPO_URL#$REF" \
    || fail "plugin install failed — check network access and ~/.netrc credentials for the GitLab host"

# --- 4. generate machine config (aliases + nexus_url + vault-sync task) -------
[ -x "$PLUGIN_DIR/scripts/vault-sync" ] || fail "vault-sync missing in plugin checkout ($PLUGIN_DIR)"
"$PLUGIN_DIR/scripts/vault-sync"

# --- 5. smoke test -------------------------------------------------------------
FIRST_TOOL=$(ls -1 "$PLUGIN_DIR/catalog" | head -1)
if mise ls-remote "$FIRST_TOOL" >/dev/null 2>&1; then
    say "smoke test ok: 'mise ls-remote $FIRST_TOOL' lists approved versions"
else
    fail "smoke test failed: 'mise ls-remote $FIRST_TOOL' returned nothing"
fi

say "done. Usage:"
printf '    mise ls-remote %s\n' "$FIRST_TOOL"
printf '    mise use %s@<approved-version>\n' "$FIRST_TOOL"
printf '    mise install            # in a project with mise.toml / .tool-versions\n'
printf '    mise run vault-sync     # update plugin + regenerate machine config\n'
