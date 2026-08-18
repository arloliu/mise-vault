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
# The version and repository URL are self-detected from the checkout this
# script runs in: cloning a tag installs that tag; cloning the default branch
# installs the exact commit that was cloned. Every commit on the default
# branch is a valid current version (changes are gated by merge request + CI).
# Environment overrides (required for the single-file CI download path,
# which has no git checkout):
#   MISE_VAULT_REPO_URL  git URL of this repository
#   MISE_VAULT_REF       tag, commit, or "latest" (default branch HEAD)
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLUGIN_NAME=vault
DATA_DIR="${MISE_DATA_DIR:-$HOME/.local/share/mise}"
PLUGIN_DIR="$DATA_DIR/plugins/$PLUGIN_NAME"

say()  { printf 'mise-vault install: %s\n' "$*"; }
fail() { printf 'mise-vault install: ERROR: %s\n' "$*" >&2; exit 1; }

# --- 0. determine release tag and repository URL ------------------------------
if [ -n "${MISE_VAULT_REF:-}" ]; then
    REF="$MISE_VAULT_REF"
elif REF=$(git -C "$SCRIPT_DIR" describe --tags --exact-match 2>/dev/null); then
    :  # tagged checkout: install exactly that tag
elif REF=$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null); then
    :  # branch checkout: install exactly the commit that was cloned
else
    fail "cannot determine the version: run this script from a git checkout or set MISE_VAULT_REF"
fi
REPO_URL="${MISE_VAULT_REPO_URL:-$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || true)}"
[ -n "$REPO_URL" ] || fail "cannot determine the repository URL: set MISE_VAULT_REPO_URL"
say "version $REF from $REPO_URL"

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
if [ "$REF" = "latest" ]; then PLUGIN_SPEC="$REPO_URL"; else PLUGIN_SPEC="$REPO_URL#$REF"; fi
say "installing plugin $PLUGIN_NAME from $PLUGIN_SPEC ..."
mise plugin install -f "$PLUGIN_NAME" "$PLUGIN_SPEC" \
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
