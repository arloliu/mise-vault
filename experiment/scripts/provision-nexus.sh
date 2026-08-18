#!/usr/bin/env bash
# Idempotent Nexus provisioning for the mise-vault experiment.
#
# What it does:
#   1. Wait for Nexus to come up.
#   2. Rotate the generated admin password to a known value.
#   3. Disable anonymous read (we explicitly want to exercise authenticated reads).
#   4. Create a raw hosted repository `devtools` (writePolicy ALLOW_ONCE = immutable).
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

# --- 5. read-only role + developer user ----------------------------------
if curl -sf -u "$AUTH" "$NEXUS_URL/service/rest/v1/security/roles/devtools-read" >/dev/null 2>&1; then
  log "role devtools-read already exists"
else
  curl -sf -u "$AUTH" -X POST "$NEXUS_URL/service/rest/v1/security/roles" \
    -H 'Content-Type: application/json' -d "{
      \"id\": \"devtools-read\",
      \"name\": \"devtools-read\",
      \"description\": \"read-only access to $REPO\",
      \"privileges\": [
        \"nx-repository-view-raw-$REPO-read\",
        \"nx-repository-view-raw-$REPO-browse\"
      ],
      \"roles\": []
    }" >/dev/null
  log "created role devtools-read"
fi

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

# unauthenticated must fail
if curl -sf -o /dev/null "$NEXUS_URL/repository/$REPO/$SMOKE_PATH"; then
  echo "ERROR: anonymous download unexpectedly succeeded"; exit 1
fi
log "anonymous download correctly rejected"

# developer (read-only) must succeed and hash must match
GOT_SHA=$(curl -sf -u "$DEV_USER:$DEV_PW" "$NEXUS_URL/repository/$REPO/$SMOKE_PATH" | sha256sum | awk '{print $1}')
[ "$GOT_SHA" = "$WANT_SHA" ] || { echo "ERROR: sha mismatch"; exit 1; }
log "developer download + sha256 verified"

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
echo "  developer  : $DEV_USER / $DEV_PW  (read-only on $REPO)"
echo "  repository : $NEXUS_URL/repository/$REPO/<tool>/<version>/<artifact>"
