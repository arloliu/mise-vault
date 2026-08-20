#!/usr/bin/env bash
# Idempotent Nexus provisioning for the mise-vault experiment.
#
# What it does:
#   1. Wait for Nexus to come up.
#   2. Rotate the generated admin password to a known value.
#   3. Disable anonymous read (we explicitly want to exercise authenticated reads
#      on the artifact repository).
#   4. Create a raw hosted repository `devtools` (writePolicy ALLOW_ONCE = immutable).
#   4b. Create a go proxy repository caching proxy.golang.org, for
#       go-installed tools, and re-enable anonymous access scoped to READ
#       ONLY THAT REPOSITORY.
#       This is required, not just convenient.
#       The go command's netrc-based auth only ever activates for an
#       https:// module proxy (verified by reading
#       cmd/go/internal/web/http.go in the installed toolchain — it calls
#       the credential lookup only when the request scheme is "https"),
#       and this experiment — like the real Nexus this simulates — serves
#       plain http.
#       Content behind this repository is every approved version's source,
#       mirrored read-only from the public go proxy.
#       The security boundary stays the approved-version list in the
#       catalog, so making the mirror itself world-readable gives
#       nothing away.
#   4d-4f. Create an npm proxy repository (caches registry.npmjs.org) and a
#       pypi proxy repository (caches pypi.org), for npm- and pypi-installed
#       tools (design doc docs/specs/2026-08-20-ecosystem-tools-design.md
#       section 8), and extend the same scoped anonymous-read exception to
#       both: npm has no netrc auth channel at all, and the experiment's
#       USER-ENV .npmrc / pip.conf / uv.toml carry no embedded credentials,
#       mirroring the production shapes.
#   4g-4h. Create a cargo proxy repository (caches index.crates.io) for
#       cargo-installed tools (Phase B of the same design doc), and extend
#       the same scoped anonymous-read exception to it: cargo's own registry
#       auth model is unrelated to netrc, and the experiment's USER-ENV
#       ~/.cargo/config.toml carries no embedded credentials either. Verified
#       empirically against this Nexus CE build (3.95.1): the cargo proxy
#       recipe exists, remoteUrl "https://index.crates.io" serves both the
#       sparse index (JSON lines under a name-length-keyed path, e.g.
#       "to/ke/tokei") and — via the repository's own "dl" field in
#       config.json — proxies the matching crate tarball downloads, so one
#       "cargo install" against it pulls a crate's whole dependency closure
#       exactly like the go/npm/pypi proxies above.
#   5. Create a read-only role + `developer` user (simulates workstation credentials).
#   6. Upload a smoke artifact as admin, download it back as developer, verify sha256.
set -euo pipefail

NEXUS_URL=${NEXUS_URL:-http://localhost:8081}
ADMIN_NEW_PW=${ADMIN_NEW_PW:-admin-mise-vault}
DEV_USER=${DEV_USER:-developer}
DEV_PW=${DEV_PW:-dev-mise-vault}
REPO=devtools

log() { printf '>>> %s\n' "$*"; }

log "waiting for Nexus at $NEXUS_URL ..."
for i in $(seq 1 120); do
  curl -sf "$NEXUS_URL/service/rest/v1/status" >/dev/null && break
  sleep 5
  [ "$i" = 120 ] && { echo "Nexus did not come up"; exit 1; }
done
log "Nexus is up"

# --- 2. admin credentials -----------------------------------------------
if docker exec mv-nexus test -f /nexus-data/admin.password 2>/dev/null; then
  INITIAL_PW=$(docker exec mv-nexus cat /nexus-data/admin.password)
  log "rotating initial admin password"
  curl -sf -u "admin:$INITIAL_PW" -X PUT \
    "$NEXUS_URL/service/rest/v1/security/users/admin/change-password" \
    -H 'Content-Type: text/plain' -d "$ADMIN_NEW_PW"
fi
AUTH="admin:$ADMIN_NEW_PW"
curl -sf -u "$AUTH" "$NEXUS_URL/service/rest/v1/status/check" >/dev/null \
  || { echo "admin auth failed"; exit 1; }
log "admin auth ok"

# --- 2b. accept Community Edition EULA (required since 3.77 for writes) ---
EULA=$(curl -sf -u "$AUTH" "$NEXUS_URL/service/rest/v1/system/eula")
if echo "$EULA" | grep -q '"accepted" *: *false'; then
  echo "$EULA" | sed 's/"accepted" *: *false/"accepted":true/' \
    | curl -sf -u "$AUTH" -X POST "$NEXUS_URL/service/rest/v1/system/eula" \
        -H 'Content-Type: application/json' -d @- >/dev/null
  log "accepted Community Edition EULA"
else
  log "EULA already accepted"
fi

# --- 3. disable anonymous read ------------------------------------------
curl -sf -u "$AUTH" -X PUT "$NEXUS_URL/service/rest/v1/security/anonymous" \
  -H 'Content-Type: application/json' \
  -d '{"enabled": false, "userId": "anonymous", "realmName": "NexusAuthorizingRealm"}' >/dev/null
log "anonymous access disabled"

# --- 4. raw hosted repository -------------------------------------------
if curl -sf -u "$AUTH" "$NEXUS_URL/service/rest/v1/repositories/raw/hosted/$REPO" >/dev/null 2>&1; then
  log "repository '$REPO' already exists"
else
  curl -sf -u "$AUTH" -X POST "$NEXUS_URL/service/rest/v1/repositories/raw/hosted" \
    -H 'Content-Type: application/json' -d "{
      \"name\": \"$REPO\",
      \"online\": true,
      \"storage\": {
        \"blobStoreName\": \"default\",
        \"strictContentTypeValidation\": false,
        \"writePolicy\": \"ALLOW_ONCE\"
      }
    }"
  log "created raw hosted repository '$REPO' (immutable: ALLOW_ONCE)"
fi

# --- 4b. go proxy repository (caches proxy.golang.org for go-installed tools) ---
GO_PROXY_REPO=go-proxy
GO_PROXY_REMOTE=${GO_PROXY_REMOTE:-https://proxy.golang.org}
if curl -sf -u "$AUTH" "$NEXUS_URL/service/rest/v1/repositories/go/proxy/$GO_PROXY_REPO" >/dev/null 2>&1; then
  log "repository '$GO_PROXY_REPO' already exists"
else
  curl -sf -u "$AUTH" -X POST "$NEXUS_URL/service/rest/v1/repositories/go/proxy" \
    -H 'Content-Type: application/json' -d "{
      \"name\": \"$GO_PROXY_REPO\",
      \"online\": true,
      \"storage\": {
        \"blobStoreName\": \"default\",
        \"strictContentTypeValidation\": true
      },
      \"proxy\": {
        \"remoteUrl\": \"$GO_PROXY_REMOTE\",
        \"contentMaxAge\": 1440,
        \"metadataMaxAge\": 1440
      },
      \"negativeCache\": {
        \"enabled\": true,
        \"timeToLive\": 1440
      },
      \"httpClient\": {
        \"blocked\": false,
        \"autoBlock\": true
      }
    }"
  log "created go proxy repository '$GO_PROXY_REPO' (caches $GO_PROXY_REMOTE)"
fi

# --- 4c. anonymous read, scoped to ONLY the go proxy repository -------------
# Nexus's built-in "nx-anonymous" role cannot be narrowed (it is read-only
# and already grants read on every repository), so the anonymous user is
# switched to a role this script owns instead of that built-in one.
GO_PROXY_ANON_ROLE=go-proxy-anon-read
if curl -sf -u "$AUTH" "$NEXUS_URL/service/rest/v1/security/roles/$GO_PROXY_ANON_ROLE" >/dev/null 2>&1; then
  log "role $GO_PROXY_ANON_ROLE already exists"
else
  curl -sf -u "$AUTH" -X POST "$NEXUS_URL/service/rest/v1/security/roles" \
    -H 'Content-Type: application/json' -d "{
      \"id\": \"$GO_PROXY_ANON_ROLE\",
      \"name\": \"$GO_PROXY_ANON_ROLE\",
      \"description\": \"anonymous read of $GO_PROXY_REPO ONLY — never $REPO\",
      \"privileges\": [
        \"nx-repository-view-go-$GO_PROXY_REPO-read\",
        \"nx-repository-view-go-$GO_PROXY_REPO-browse\"
      ],
      \"roles\": []
    }" >/dev/null
  log "created role $GO_PROXY_ANON_ROLE"
fi
curl -sf -u "$AUTH" -X PUT "$NEXUS_URL/service/rest/v1/security/users/anonymous" \
  -H 'Content-Type: application/json' -d "{
    \"userId\": \"anonymous\",
    \"firstName\": \"Anonymous\",
    \"lastName\": \"User\",
    \"emailAddress\": \"anonymous@example.org\",
    \"source\": \"default\",
    \"status\": \"active\",
    \"roles\": [\"$GO_PROXY_ANON_ROLE\"]
  }" >/dev/null
curl -sf -u "$AUTH" -X PUT "$NEXUS_URL/service/rest/v1/security/anonymous" \
  -H 'Content-Type: application/json' \
  -d '{"enabled": true, "userId": "anonymous", "realmName": "NexusAuthorizingRealm"}' >/dev/null
log "anonymous access re-enabled, scoped to $GO_PROXY_REPO only (role: $GO_PROXY_ANON_ROLE)"

# --- 4d. npm proxy repository (caches registry.npmjs.org for npm-installed tools) ---
# Same rationale as the go proxy above, generalized to ecosystem tool types
# (design doc section 8): npm does not read netrc, so the experiment's
# USER-ENV .npmrc points at this repository with no embedded credentials —
# anonymous read is therefore required here too, scoped the same way.
NPM_PROXY_REPO=npm-proxy
NPM_PROXY_REMOTE=${NPM_PROXY_REMOTE:-https://registry.npmjs.org}
if curl -sf -u "$AUTH" "$NEXUS_URL/service/rest/v1/repositories/npm/proxy/$NPM_PROXY_REPO" >/dev/null 2>&1; then
  log "repository '$NPM_PROXY_REPO' already exists"
else
  curl -sf -u "$AUTH" -X POST "$NEXUS_URL/service/rest/v1/repositories/npm/proxy" \
    -H 'Content-Type: application/json' -d "{
      \"name\": \"$NPM_PROXY_REPO\",
      \"online\": true,
      \"storage\": {
        \"blobStoreName\": \"default\",
        \"strictContentTypeValidation\": true
      },
      \"proxy\": {
        \"remoteUrl\": \"$NPM_PROXY_REMOTE\",
        \"contentMaxAge\": 1440,
        \"metadataMaxAge\": 1440
      },
      \"negativeCache\": {
        \"enabled\": true,
        \"timeToLive\": 1440
      },
      \"httpClient\": {
        \"blocked\": false,
        \"autoBlock\": true
      }
    }"
  log "created npm proxy repository '$NPM_PROXY_REPO' (caches $NPM_PROXY_REMOTE)"
fi

# --- 4e. pypi proxy repository (caches pypi.org for pypi-installed tools) ---
PYPI_PROXY_REPO=pypi-proxy
PYPI_PROXY_REMOTE=${PYPI_PROXY_REMOTE:-https://pypi.org}
if curl -sf -u "$AUTH" "$NEXUS_URL/service/rest/v1/repositories/pypi/proxy/$PYPI_PROXY_REPO" >/dev/null 2>&1; then
  log "repository '$PYPI_PROXY_REPO' already exists"
else
  curl -sf -u "$AUTH" -X POST "$NEXUS_URL/service/rest/v1/repositories/pypi/proxy" \
    -H 'Content-Type: application/json' -d "{
      \"name\": \"$PYPI_PROXY_REPO\",
      \"online\": true,
      \"storage\": {
        \"blobStoreName\": \"default\",
        \"strictContentTypeValidation\": true
      },
      \"proxy\": {
        \"remoteUrl\": \"$PYPI_PROXY_REMOTE\",
        \"contentMaxAge\": 1440,
        \"metadataMaxAge\": 1440
      },
      \"negativeCache\": {
        \"enabled\": true,
        \"timeToLive\": 1440
      },
      \"httpClient\": {
        \"blocked\": false,
        \"autoBlock\": true
      }
    }"
  log "created pypi proxy repository '$PYPI_PROXY_REPO' (caches $PYPI_PROXY_REMOTE)"
fi

# --- 4g. cargo proxy repository (caches index.crates.io for cargo-installed tools) ---
CARGO_PROXY_REPO=cargo-proxy
CARGO_PROXY_REMOTE=${CARGO_PROXY_REMOTE:-https://index.crates.io}
if curl -sf -u "$AUTH" "$NEXUS_URL/service/rest/v1/repositories/cargo/proxy/$CARGO_PROXY_REPO" >/dev/null 2>&1; then
  log "repository '$CARGO_PROXY_REPO' already exists"
else
  curl -sf -u "$AUTH" -X POST "$NEXUS_URL/service/rest/v1/repositories/cargo/proxy" \
    -H 'Content-Type: application/json' -d "{
      \"name\": \"$CARGO_PROXY_REPO\",
      \"online\": true,
      \"storage\": {
        \"blobStoreName\": \"default\",
        \"strictContentTypeValidation\": true
      },
      \"proxy\": {
        \"remoteUrl\": \"$CARGO_PROXY_REMOTE\",
        \"contentMaxAge\": 1440,
        \"metadataMaxAge\": 1440
      },
      \"negativeCache\": {
        \"enabled\": true,
        \"timeToLive\": 1440
      },
      \"httpClient\": {
        \"blocked\": false,
        \"autoBlock\": true
      },
      \"cargo\": {
        \"requireAuthentication\": false
      }
    }"
  log "created cargo proxy repository '$CARGO_PROXY_REPO' (caches $CARGO_PROXY_REMOTE)"
fi

# --- 4f. anonymous read, scoped to ONLY the go/npm/pypi/cargo proxy repositories ---
# Same reasoning as 4c, extended to the new proxy repos: npm has no
# netrc-based auth channel at all, and the experiment's pip.conf / uv.toml /
# cargo config.toml carry no embedded credentials either (mirroring the
# production shapes in the design doc), so every proxy needs the same scoped
# anonymous exception.
NPM_PROXY_ANON_ROLE=npm-proxy-anon-read
if curl -sf -u "$AUTH" "$NEXUS_URL/service/rest/v1/security/roles/$NPM_PROXY_ANON_ROLE" >/dev/null 2>&1; then
  log "role $NPM_PROXY_ANON_ROLE already exists"
else
  curl -sf -u "$AUTH" -X POST "$NEXUS_URL/service/rest/v1/security/roles" \
    -H 'Content-Type: application/json' -d "{
      \"id\": \"$NPM_PROXY_ANON_ROLE\",
      \"name\": \"$NPM_PROXY_ANON_ROLE\",
      \"description\": \"anonymous read of $NPM_PROXY_REPO ONLY — never $REPO\",
      \"privileges\": [
        \"nx-repository-view-npm-$NPM_PROXY_REPO-read\",
        \"nx-repository-view-npm-$NPM_PROXY_REPO-browse\"
      ],
      \"roles\": []
    }" >/dev/null
  log "created role $NPM_PROXY_ANON_ROLE"
fi
PYPI_PROXY_ANON_ROLE=pypi-proxy-anon-read
if curl -sf -u "$AUTH" "$NEXUS_URL/service/rest/v1/security/roles/$PYPI_PROXY_ANON_ROLE" >/dev/null 2>&1; then
  log "role $PYPI_PROXY_ANON_ROLE already exists"
else
  curl -sf -u "$AUTH" -X POST "$NEXUS_URL/service/rest/v1/security/roles" \
    -H 'Content-Type: application/json' -d "{
      \"id\": \"$PYPI_PROXY_ANON_ROLE\",
      \"name\": \"$PYPI_PROXY_ANON_ROLE\",
      \"description\": \"anonymous read of $PYPI_PROXY_REPO ONLY — never $REPO\",
      \"privileges\": [
        \"nx-repository-view-pypi-$PYPI_PROXY_REPO-read\",
        \"nx-repository-view-pypi-$PYPI_PROXY_REPO-browse\"
      ],
      \"roles\": []
    }" >/dev/null
  log "created role $PYPI_PROXY_ANON_ROLE"
fi
CARGO_PROXY_ANON_ROLE=cargo-proxy-anon-read
if curl -sf -u "$AUTH" "$NEXUS_URL/service/rest/v1/security/roles/$CARGO_PROXY_ANON_ROLE" >/dev/null 2>&1; then
  log "role $CARGO_PROXY_ANON_ROLE already exists"
else
  curl -sf -u "$AUTH" -X POST "$NEXUS_URL/service/rest/v1/security/roles" \
    -H 'Content-Type: application/json' -d "{
      \"id\": \"$CARGO_PROXY_ANON_ROLE\",
      \"name\": \"$CARGO_PROXY_ANON_ROLE\",
      \"description\": \"anonymous read of $CARGO_PROXY_REPO ONLY — never $REPO\",
      \"privileges\": [
        \"nx-repository-view-cargo-$CARGO_PROXY_REPO-read\",
        \"nx-repository-view-cargo-$CARGO_PROXY_REPO-browse\"
      ],
      \"roles\": []
    }" >/dev/null
  log "created role $CARGO_PROXY_ANON_ROLE"
fi
curl -sf -u "$AUTH" -X PUT "$NEXUS_URL/service/rest/v1/security/users/anonymous" \
  -H 'Content-Type: application/json' -d "{
    \"userId\": \"anonymous\",
    \"firstName\": \"Anonymous\",
    \"lastName\": \"User\",
    \"emailAddress\": \"anonymous@example.org\",
    \"source\": \"default\",
    \"status\": \"active\",
    \"roles\": [\"$GO_PROXY_ANON_ROLE\", \"$NPM_PROXY_ANON_ROLE\", \"$PYPI_PROXY_ANON_ROLE\", \"$CARGO_PROXY_ANON_ROLE\"]
  }" >/dev/null
curl -sf -u "$AUTH" -X PUT "$NEXUS_URL/service/rest/v1/security/anonymous" \
  -H 'Content-Type: application/json' \
  -d '{"enabled": true, "userId": "anonymous", "realmName": "NexusAuthorizingRealm"}' >/dev/null
log "anonymous access re-enabled, scoped to $GO_PROXY_REPO, $NPM_PROXY_REPO, $PYPI_PROXY_REPO, $CARGO_PROXY_REPO only"

# --- 5. read-only role + developer user ----------------------------------
# This role is always PUT (create-or-update), not create-once: unlike the
# other roles in this script, it must stay CURRENT rather than merely
# present.
# Reason (an experiment-only instance of the AGENTS.md netrc lesson):
# npm-proxy/pypi-proxy/go-proxy live on the SAME host:port as the
# authenticated-only devtools repo, and netrc has no port field, so a
# developer's netrc entry for this host is picked up automatically by any
# netrc-aware HTTP client (pip's requests library does this) even for a
# proxy repository request that would otherwise go through anonymously.
# If devtools-read ever fell behind (missing a proxy's read privilege), a
# developer's own valid credentials would silently turn an anonymous-OK
# request into an authenticated-but-forbidden one — observed empirically
# here as "pip: could not find a version" through the pypi proxy with a
# stale role.
# Keeping devtools-read a superset of the anonymous grants makes that
# failure mode structurally impossible instead of order-dependent.
DEVTOOLS_ROLE_METHOD=POST
DEVTOOLS_ROLE_URL="$NEXUS_URL/service/rest/v1/security/roles"
if curl -sf -u "$AUTH" "$NEXUS_URL/service/rest/v1/security/roles/devtools-read" >/dev/null 2>&1; then
  log "role devtools-read already exists; refreshing its privileges"
  DEVTOOLS_ROLE_METHOD=PUT
  DEVTOOLS_ROLE_URL="$NEXUS_URL/service/rest/v1/security/roles/devtools-read"
fi
curl -sf -u "$AUTH" -X "$DEVTOOLS_ROLE_METHOD" "$DEVTOOLS_ROLE_URL" \
  -H 'Content-Type: application/json' -d "{
    \"id\": \"devtools-read\",
    \"name\": \"devtools-read\",
    \"description\": \"read-only access to $REPO, $GO_PROXY_REPO, $NPM_PROXY_REPO, $PYPI_PROXY_REPO, $CARGO_PROXY_REPO\",
    \"privileges\": [
      \"nx-repository-view-raw-$REPO-read\",
      \"nx-repository-view-raw-$REPO-browse\",
      \"nx-repository-view-go-$GO_PROXY_REPO-read\",
      \"nx-repository-view-go-$GO_PROXY_REPO-browse\",
      \"nx-repository-view-npm-$NPM_PROXY_REPO-read\",
      \"nx-repository-view-npm-$NPM_PROXY_REPO-browse\",
      \"nx-repository-view-pypi-$PYPI_PROXY_REPO-read\",
      \"nx-repository-view-pypi-$PYPI_PROXY_REPO-browse\",
      \"nx-repository-view-cargo-$CARGO_PROXY_REPO-read\",
      \"nx-repository-view-cargo-$CARGO_PROXY_REPO-browse\"
    ],
    \"roles\": []
  }" >/dev/null
log "role devtools-read is current"

if curl -sf -u "$AUTH" "$NEXUS_URL/service/rest/v1/security/users?userId=$DEV_USER" | grep -q "\"userId\" *: *\"$DEV_USER\""; then
  log "user $DEV_USER already exists"
else
  curl -sf -u "$AUTH" -X POST "$NEXUS_URL/service/rest/v1/security/users" \
    -H 'Content-Type: application/json' -d "{
      \"userId\": \"$DEV_USER\",
      \"firstName\": \"Dev\",
      \"lastName\": \"Eloper\",
      \"emailAddress\": \"dev@example.invalid\",
      \"password\": \"$DEV_PW\",
      \"status\": \"active\",
      \"roles\": [\"devtools-read\"]
    }" >/dev/null
  log "created read-only user $DEV_USER"
fi

# --- 6. smoke artifact ----------------------------------------------------
SMOKE_PATH="smoke/0.0.1/smoke-0.0.1.txt"
TMPF=$(mktemp)
trap 'rm -f "$TMPF"' EXIT
echo "hello mise-vault" > "$TMPF"
WANT_SHA=$(sha256sum "$TMPF" | awk '{print $1}')

if curl -sf -u "$AUTH" -o /dev/null "$NEXUS_URL/repository/$REPO/$SMOKE_PATH"; then
  log "smoke artifact already uploaded"
else
  curl -sf -u "$AUTH" --upload-file "$TMPF" "$NEXUS_URL/repository/$REPO/$SMOKE_PATH"
  log "uploaded smoke artifact"
fi

# unauthenticated must fail against the artifact repository ...
if curl -sf -o /dev/null "$NEXUS_URL/repository/$REPO/$SMOKE_PATH"; then
  echo "ERROR: anonymous download unexpectedly succeeded"; exit 1
fi
log "anonymous download of $REPO correctly rejected"

# ... but the PRIVILEGE CHECK for the go proxy must pass anonymously (see 4c
# for why this is required). Nexus enforces the privilege before it ever
# forwards a request upstream, so a probe path that does not exist proves the
# access grant on its own, with no dependency on this script reaching the
# public internet: a 401/403 here would mean the scoping is broken, while
# any other status (404 from Nexus, or whatever the upstream returns) means
# the request was let through.
GO_PROXY_PROBE_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
  "$NEXUS_URL/repository/$GO_PROXY_REPO/example.invalid/does-not-exist/@v/list")
case "$GO_PROXY_PROBE_CODE" in
  401|403)
    echo "ERROR: anonymous read of $GO_PROXY_REPO was rejected (HTTP $GO_PROXY_PROBE_CODE)"
    exit 1
    ;;
esac
log "anonymous read of $GO_PROXY_REPO correctly allowed (scoped exception; probe HTTP $GO_PROXY_PROBE_CODE)"

NPM_PROXY_PROBE_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
  "$NEXUS_URL/repository/$NPM_PROXY_REPO/does-not-exist-mise-vault")
case "$NPM_PROXY_PROBE_CODE" in
  401|403)
    echo "ERROR: anonymous read of $NPM_PROXY_REPO was rejected (HTTP $NPM_PROXY_PROBE_CODE)"
    exit 1
    ;;
esac
log "anonymous read of $NPM_PROXY_REPO correctly allowed (scoped exception; probe HTTP $NPM_PROXY_PROBE_CODE)"

PYPI_PROXY_PROBE_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
  "$NEXUS_URL/repository/$PYPI_PROXY_REPO/simple/does-not-exist-mise-vault/")
case "$PYPI_PROXY_PROBE_CODE" in
  401|403)
    echo "ERROR: anonymous read of $PYPI_PROXY_REPO was rejected (HTTP $PYPI_PROXY_PROBE_CODE)"
    exit 1
    ;;
esac
log "anonymous read of $PYPI_PROXY_REPO correctly allowed (scoped exception; probe HTTP $PYPI_PROXY_PROBE_CODE)"

# config.json is always served by an online cargo proxy repository regardless
# of crate content, so it is a reliable probe path that never depends on
# guessing a real (or plausibly absent) crate name or its index-path bucket.
CARGO_PROXY_PROBE_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
  "$NEXUS_URL/repository/$CARGO_PROXY_REPO/config.json")
case "$CARGO_PROXY_PROBE_CODE" in
  401|403)
    echo "ERROR: anonymous read of $CARGO_PROXY_REPO was rejected (HTTP $CARGO_PROXY_PROBE_CODE)"
    exit 1
    ;;
esac
log "anonymous read of $CARGO_PROXY_REPO correctly allowed (scoped exception; probe HTTP $CARGO_PROXY_PROBE_CODE)"

# developer (read-only) must succeed and hash must match
GOT_SHA=$(curl -sf -u "$DEV_USER:$DEV_PW" "$NEXUS_URL/repository/$REPO/$SMOKE_PATH" | sha256sum | awk '{print $1}')
[ "$GOT_SHA" = "$WANT_SHA" ] || { echo "ERROR: sha mismatch"; exit 1; }
log "developer download + sha256 verified"

# developer must also be able to read npm-proxy and pypi-proxy, not just
# devtools: netrc has no port field, and these proxies share a host:port
# with devtools, so a developer's netrc credentials are picked up
# automatically by any netrc-aware client (pip's requests library does
# this) even for a request that would otherwise go through anonymously.
# If devtools-read ever fell behind (see the comment above it), that would
# silently turn an anonymous-OK proxy request into an authenticated-but-
# forbidden one for anyone with valid developer credentials in ~/.netrc —
# this probe catches that regression loudly instead of as a confusing
# "pip: could not find a version" failure downstream.
DEV_NPM_CODE=$(curl -s -o /dev/null -w '%{http_code}' -u "$DEV_USER:$DEV_PW" \
  "$NEXUS_URL/repository/$NPM_PROXY_REPO/does-not-exist-mise-vault")
case "$DEV_NPM_CODE" in
  401|403)
    echo "ERROR: developer read of $NPM_PROXY_REPO was rejected (HTTP $DEV_NPM_CODE) — devtools-read is stale"
    exit 1
    ;;
esac
log "developer read of $NPM_PROXY_REPO correctly allowed (probe HTTP $DEV_NPM_CODE)"
DEV_PYPI_CODE=$(curl -s -o /dev/null -w '%{http_code}' -u "$DEV_USER:$DEV_PW" \
  "$NEXUS_URL/repository/$PYPI_PROXY_REPO/simple/does-not-exist-mise-vault/")
case "$DEV_PYPI_CODE" in
  401|403)
    echo "ERROR: developer read of $PYPI_PROXY_REPO was rejected (HTTP $DEV_PYPI_CODE) — devtools-read is stale"
    exit 1
    ;;
esac
log "developer read of $PYPI_PROXY_REPO correctly allowed (probe HTTP $DEV_PYPI_CODE)"
DEV_CARGO_CODE=$(curl -s -o /dev/null -w '%{http_code}' -u "$DEV_USER:$DEV_PW" \
  "$NEXUS_URL/repository/$CARGO_PROXY_REPO/config.json")
case "$DEV_CARGO_CODE" in
  401|403)
    echo "ERROR: developer read of $CARGO_PROXY_REPO was rejected (HTTP $DEV_CARGO_CODE) — devtools-read is stale"
    exit 1
    ;;
esac
log "developer read of $CARGO_PROXY_REPO correctly allowed (probe HTTP $DEV_CARGO_CODE)"

# developer must NOT be able to write
if curl -sf -u "$DEV_USER:$DEV_PW" --upload-file "$TMPF" \
     "$NEXUS_URL/repository/$REPO/smoke/0.0.1/illegal-write.txt" 2>/dev/null; then
  echo "ERROR: read-only user was able to write"; exit 1
fi
log "read-only user correctly denied write"

log "Nexus provisioning complete"
echo
echo "  URL        : $NEXUS_URL"
echo "  admin      : admin / $ADMIN_NEW_PW"
echo "  developer  : $DEV_USER / $DEV_PW  (read-only on $REPO, $GO_PROXY_REPO, $NPM_PROXY_REPO, $PYPI_PROXY_REPO, $CARGO_PROXY_REPO)"
echo "  repository : $NEXUS_URL/repository/$REPO/<tool>/<version>/<artifact>"
echo "  go proxy   : $NEXUS_URL/repository/$GO_PROXY_REPO  (caches $GO_PROXY_REMOTE; anonymous read)"
echo "  npm proxy  : $NEXUS_URL/repository/$NPM_PROXY_REPO  (caches $NPM_PROXY_REMOTE; anonymous read)"
echo "  pypi proxy : $NEXUS_URL/repository/$PYPI_PROXY_REPO/simple  (caches $PYPI_PROXY_REMOTE; anonymous read)"
echo "  cargo proxy: $NEXUS_URL/repository/$CARGO_PROXY_REPO  (caches $CARGO_PROXY_REMOTE; anonymous read; sparse index)"
