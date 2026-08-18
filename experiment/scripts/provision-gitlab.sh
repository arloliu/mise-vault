#!/usr/bin/env bash
# Idempotent GitLab CE provisioning for the mise-vault experiment.
#
# What it does:
#   1. Wait for GitLab to become healthy (first boot takes several minutes).
#   2. Seed a root personal access token via gitlab-rails runner.
#   3. Create group `devtools` and project `devtools/mise-vault`.
#   4. Create user `developer` + a read-only PAT (simulates a workstation user token).
#   5. Smoke-test: authenticated clone (oauth2:<token>@) and raw-file fetch
#      (PRIVATE-TOKEN header), and confirm unauthenticated access fails.
set -euo pipefail

GITLAB_URL=${GITLAB_URL:-http://localhost:8929}
ROOT_TOKEN=${ROOT_TOKEN:-glpat-mise-vault-root-00001}       # >=20 chars required
DEV_TOKEN=${DEV_TOKEN:-glpat-mise-vault-dev-000001}
DEV_USER=${DEV_USER:-developer}
DEV_PW=${DEV_PW:-dev-mise-vault-pw1!}

log() { printf '>>> %s\n' "$*"; }
api() { curl -sf -H "PRIVATE-TOKEN: $ROOT_TOKEN" "$@"; }

log "waiting for GitLab at $GITLAB_URL (first boot can take 3-6 min) ..."
for i in $(seq 1 240); do
  status=$(curl -s -o /dev/null -w '%{http_code}' "$GITLAB_URL/users/sign_in" || true)
  [ "$status" = 200 ] && break
  sleep 5
  [ "$i" = 240 ] && { echo "GitLab did not come up"; exit 1; }
done
log "GitLab web is up"

# --- 2. root PAT ----------------------------------------------------------
if api "$GITLAB_URL/api/v4/user" >/dev/null 2>&1; then
  log "root token already valid"
else
  log "seeding root personal access token via rails runner (slow, ~30-60s)"
  docker exec mv-gitlab gitlab-rails runner "
    u = User.find_by_username('root')
    unless u.personal_access_tokens.active.find_by(name: 'mise-vault-experiment')
      t = u.personal_access_tokens.create!(
        scopes: ['api'], name: 'mise-vault-experiment',
        expires_at: 365.days.from_now)
      t.set_token('$ROOT_TOKEN'); t.save!
    end"
  api "$GITLAB_URL/api/v4/user" >/dev/null || { echo "root token still invalid"; exit 1; }
fi
log "root API auth ok"

# --- 3. group + project ---------------------------------------------------
GROUP_ID=$(api "$GITLAB_URL/api/v4/groups?search=devtools" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2 || true)
if [ -z "${GROUP_ID:-}" ]; then
  GROUP_ID=$(api -X POST "$GITLAB_URL/api/v4/groups" \
    --data-urlencode name=devtools --data-urlencode path=devtools \
    --data-urlencode visibility=private | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
  log "created group devtools (id=$GROUP_ID)"
else
  log "group devtools exists (id=$GROUP_ID)"
fi

if api "$GITLAB_URL/api/v4/projects/devtools%2Fmise-vault" >/dev/null 2>&1; then
  log "project devtools/mise-vault exists"
else
  api -X POST "$GITLAB_URL/api/v4/projects" \
    --data-urlencode name=mise-vault --data-urlencode path=mise-vault \
    --data-urlencode "namespace_id=$GROUP_ID" \
    --data-urlencode visibility=private \
    --data-urlencode initialize_with_readme=true >/dev/null
  log "created project devtools/mise-vault (private, with README)"
fi

# --- 4. developer user + read-only PAT ------------------------------------
if api "$GITLAB_URL/api/v4/users?username=$DEV_USER" | grep -q '"id":'; then
  log "user $DEV_USER exists"
else
  api -X POST "$GITLAB_URL/api/v4/users" \
    --data-urlencode "username=$DEV_USER" \
    --data-urlencode "name=Dev Eloper" \
    --data-urlencode "email=dev@example.invalid" \
    --data-urlencode "password=$DEV_PW" \
    --data-urlencode skip_confirmation=true >/dev/null
  log "created user $DEV_USER"
fi
DEV_ID=$(api "$GITLAB_URL/api/v4/users?username=$DEV_USER" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)

# reporter access on the group = read-only on all devtools projects
api -X POST "$GITLAB_URL/api/v4/groups/$GROUP_ID/members" \
  --data-urlencode "user_id=$DEV_ID" --data-urlencode access_level=20 >/dev/null 2>&1 \
  && log "added $DEV_USER to devtools as Reporter" \
  || log "$DEV_USER already a member of devtools"

if curl -sf -H "PRIVATE-TOKEN: $DEV_TOKEN" "$GITLAB_URL/api/v4/user" >/dev/null 2>&1; then
  log "developer token already valid"
else
  log "seeding developer read-only token via rails runner"
  docker exec mv-gitlab gitlab-rails runner "
    u = User.find_by_username('$DEV_USER')
    unless u.personal_access_tokens.active.find_by(name: 'workstation')
      t = u.personal_access_tokens.create!(
        scopes: ['read_api', 'read_repository'], name: 'workstation',
        expires_at: 365.days.from_now)
      t.set_token('$DEV_TOKEN'); t.save!
    end"
fi

# --- 5. smoke tests --------------------------------------------------------
TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT

# unauthenticated clone must fail (private project)
if git clone -q "$GITLAB_URL/devtools/mise-vault.git" "$TMPD/anon" 2>/dev/null; then
  echo "ERROR: anonymous clone unexpectedly succeeded"; exit 1
fi
log "anonymous clone correctly rejected"

# oauth2:<PAT> clone must succeed with the read-only developer token
CLONE_URL="http://oauth2:$DEV_TOKEN@localhost:8929/devtools/mise-vault.git"
git clone -q "$CLONE_URL" "$TMPD/dev" || { echo "ERROR: token clone failed"; exit 1; }
log "developer token clone ok (oauth2:<PAT>@ form)"

# raw file fetch with PRIVATE-TOKEN header
curl -sf -H "PRIVATE-TOKEN: $DEV_TOKEN" \
  "$GITLAB_URL/api/v4/projects/devtools%2Fmise-vault/repository/files/README.md/raw?ref=main" \
  >/dev/null || { echo "ERROR: raw file fetch failed"; exit 1; }
log "raw file fetch via API + PRIVATE-TOKEN ok"

log "GitLab provisioning complete"
echo
echo "  URL        : $GITLAB_URL   (root / Vq7#tKm2xRz9!pWd4s)"
echo "  root PAT   : $ROOT_TOKEN (scope: api)"
echo "  developer  : $DEV_USER / $DEV_PW"
echo "  dev PAT    : $DEV_TOKEN (read_api, read_repository)"
echo "  project    : $GITLAB_URL/devtools/mise-vault (private)"
echo "  clone      : http://oauth2:<PAT>@localhost:8929/devtools/mise-vault.git"
