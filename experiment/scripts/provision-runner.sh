#!/usr/bin/env bash
# Idempotent GitLab Runner provisioning for the experiment stack:
#   1. create an instance runner via the API (root PAT)
#   2. register it in the mv-runner container (docker executor, compose network,
#      clone-url override so job containers reach GitLab by service name)
#   3. set the project CI/CD variables the pipeline expects
set -euo pipefail
GITLAB_URL=${GITLAB_URL:-http://localhost:8929}
ROOT_TOKEN=${ROOT_TOKEN:-glpat-mise-vault-root-00001}
NET=mise-vault-experiment_default
log() { printf '>>> %s\n' "$*"; }
api() { curl -sf -H "PRIVATE-TOKEN: $ROOT_TOKEN" "$@"; }

if docker exec mv-runner sh -c 'grep -q "token = " /etc/gitlab-runner/config.toml' 2>/dev/null; then
  log "runner already registered"
else
  log "creating instance runner via API"
  RTOKEN=$(api -X POST "$GITLAB_URL/api/v4/user/runners" \
    --data "runner_type=instance_type" --data "run_untagged=true" \
    --data "description=mv-runner" | python3 -c "import json,sys;print(json.load(sys.stdin)['token'])")
  log "registering runner (docker executor on $NET)"
  docker exec mv-runner gitlab-runner register --non-interactive \
    --url "http://gitlab:8929" --token "$RTOKEN" \
    --executor docker --docker-image mise-vault-test \
    --docker-network-mode "$NET" \
    --clone-url "http://gitlab:8929" \
    --docker-pull-policy if-not-present
  log "runner registered"
fi

PROJ=devtools%2Fmise-vault
setvar() { # key value
  api -X DELETE "$GITLAB_URL/api/v4/projects/$PROJ/variables/$1" >/dev/null 2>&1 || true
  api -X POST "$GITLAB_URL/api/v4/projects/$PROJ/variables" \
    --data "key=$1" --data-urlencode "value=$2" >/dev/null
  log "project variable $1 set"
}
setvar NEXUS_CI_USER developer
setvar NEXUS_CI_PASSWORD dev-mise-vault
setvar NEXUS_URL http://nexus:8081/repository/devtools
setvar DEVTOOLS_CI_IMAGE mise-vault-test

log "runner provisioning complete"
