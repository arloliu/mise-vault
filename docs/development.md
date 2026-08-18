# Developing mise-vault

How to set up a local environment, make changes, and test them.
For principles, binding design decisions, and lessons learned, read [AGENTS.md](../AGENTS.md) first;
for the why behind the architecture, see [design.md](design.md).

## What you are working on

This repository IS the mise plugin:
mise clones it, reads `metadata.lua`, and calls the three Lua hooks in `hooks/`.

| Piece | Runs when |
|---|---|
| `hooks/backend_list_versions.lua` | `mise ls-remote <tool>` — returns versions from `catalog/<tool>/versions.json`, order verbatim |
| `hooks/backend_install.lua` | `mise install <tool>@<version>` — builds the Nexus URL, downloads with `curl -n`, verifies SHA-256, extracts |
| `hooks/backend_exec_env.lua` | tool activation — PATH entries and env vars (e.g. GOROOT) from `tool.json` |
| `lib/common.lua` | shared helpers used by all three hooks |
| `scripts/vault-sync` | generates the machine config (`~/.config/mise/conf.d/mise-vault.toml`) from the catalog |
| `install.sh` | one-time workstation bootstrap |

Everything else is data (`catalog/`, `config/`),
validation (`schemas/`, `scripts/`),
or test infrastructure (`experiment/`, `tests/`).

## Prerequisites

- Docker with the compose plugin (the experiment stack runs Nexus, GitLab CE, and a CI runner)
- mise 2026.8.1 or newer (`mise --version`)
- `git`, `curl`, `python3` (no Python packages needed locally; CI installs `jsonschema`)

## Environment setup (once)

```bash
cd experiment
docker compose up -d                  # Nexus is healthy in ~1 min; GitLab takes 3-6 min on first boot
./scripts/provision-nexus.sh          # raw repo, read-only user, smoke artifact (idempotent)
./scripts/provision-gitlab.sh         # project, tokens, users (idempotent; waits for boot)
./scripts/provision-runner.sh         # CI runner + project variables (idempotent)
./scripts/seed-artifacts.sh           # real linux-amd64 tool artifacts (public internet, once)
./scripts/seed-extra-platforms.sh     # linux-arm64 + darwin-arm64 artifacts (public internet, once)
docker build -t mise-vault-test test-image/   # workstation-like image for offline/CI tests
```

Ports and credentials (test-only values) are in [experiment/README.md](../experiment/README.md),
including the loopback-address trick:
Nexus is addressed as `127.0.0.2:8081` and GitLab as `127.0.0.3:8929`
so that netrc `machine` entries stay per-service
(netrc matches hostname only — it has no port field).

Push access to the experiment GitLab copy of this repository:

```bash
git remote add experiment http://oauth2:glpat-mise-vault-root-00001@127.0.0.3:8929/devtools/mise-vault.git
```

Behind a corporate proxy or with an internal registry,
see "Private mirror / proxy overrides" in [experiment/README.md](../experiment/README.md).

## The development loop

### Fast iteration: link the working tree

`mise plugins link` points mise directly at a directory — no git round trip.
Always test in a throwaway HOME so your real mise config is untouched:

```bash
T=$(mktemp -d)
HOME="$T" bash -c '
  mkdir -p "$HOME/.config/mise"
  printf "[settings]\ngix = false\nlibgit2 = false\n" > "$HOME/.config/mise/config.toml"
  mise plugins link vault /path/to/your/checkout
  mise ls-remote vault:golangci-lint
  mise install vault:golangci-lint@2.12.2
  mise exec vault:golangci-lint@2.12.2 -- golangci-lint version
'
rm -rf "$T"
```

Downloads need credentials: either put a netrc in the throwaway HOME
(copy the machine entries from `experiment/README.md`)
or point the catalog at a Nexus that allows your access.

### Full verification: push to the experiment GitLab and run the suites

The end-to-end suites exercise the real install path
(plugin cloned by mise from GitLab, artifacts pulled from Nexus):

```bash
git push experiment main            # and tags, if the change should be pinnable:
git tag v0.0.X && git push experiment v0.0.X
```

| Suite | Covers | Runtime |
|---|---|---|
| `experiment/scripts/poc-test.sh` | plugin behavior matrix: discovery, installs (archive/runtime), aliases, `.tool-versions`, fail-closed paths, catalog update, unsupported platform | ~2 min |
| `experiment/scripts/bootstrap-test.sh` | the full new-developer flow: netrc clone, `install.sh` self-detection, generated config, public-backend blocking, idempotency, `vault-sync` | ~2 min |
| `experiment/scripts/offline-test.sh` | everything again inside a Docker network with **no route to the internet** | ~2 min |
| `scripts/validate-catalog` | catalog schema + rules, no network | seconds |
| `scripts/verify-artifacts --checksum` | every catalog entry exists in Nexus and hashes match (`NEXUS_CURL_OPTS="-u user:pass"` for auth) | ~1 min |

Note: the suites pin specific experiment tags (`REF=` near the top of each script);
bump the pin when your change needs a new tag to be visible.
Each suite prints `RESULT: N passed, M failed` and exits nonzero on any failure.

### CI

Pushing to the experiment GitLab triggers the real pipeline
(the same `.gitlab-ci.yml` production will use):
validate → artifact existence → checksums → a real install through the backend.

```bash
# watch the latest pipeline
curl -s -H "PRIVATE-TOKEN: glpat-mise-vault-root-00001" \
  "http://127.0.0.3:8929/api/v4/projects/devtools%2Fmise-vault/pipelines?per_page=1"
```

If a pipeline shows **failed with zero jobs**, the YAML is invalid —
GitLab hides the parse error; check it with the CI lint API
(`POST /api/v4/projects/:id/ci/lint`).

## Catalog changes

```bash
export NEXUS_CURL_OPTS="-u developer:dev-mise-vault"   # experiment credentials

scripts/add-version <tool> <version>      # verifies the artifact exists, takes sha from
                                          # the .sha256sum sidecar (or hashes the download),
                                          # appends to versions.json — never edits history
scripts/validate-catalog                  # before every commit
scripts/verify-artifacts --checksum
```

New tool: author `catalog/<tool>/tool.json` by hand first —
artifact name template per platform (only `{version}` is substituted),
archive format, `strip_components`, `bin_paths`, optional `env`.
Copy the closest existing tool as a starting point;
`tests/fixtures/catalog/` shows deliberately broken shapes the validator must reject.

## Testing conventions

- Never test against your real `$HOME` — every suite builds a throwaway one; do the same in ad-hoc tests.
- Assert the resolving backend, not just tool output:
  `mise tool glab` must show `vault:glab`,
  otherwise you may be watching mise's public registry answer instead of the plugin.
- When probing HTTP endpoints, check `-w '%{http_code}'`, not just curl's exit code —
  a 302 with an empty body exits 0 and reads as false success.
- Under `set -o pipefail`, don't pipe a failing command into `grep -q`:
  capture output into a variable first, then grep it.
- Negative tests matter as much as positive ones:
  every fail-closed path (unknown tool, unapproved version, missing platform, checksum mismatch)
  has an assertion in the suites — keep it that way when adding behavior.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| GitLab container exits during first boot | initial root password rejected by the strength policy — use a strong value, wipe the gitlab volumes, retry |
| Nexus uploads return 403 | Community Edition EULA not accepted — `provision-nexus.sh` handles it (REST `system/eula`) |
| Plugin install prompts for credentials or fails auth | `gix`/`libgit2` settings not false, or no netrc entry for the GitLab host |
| Artifact download 401 in a hook | the hook downloads with `curl -n`: the running HOME needs a netrc entry for the Nexus host |
| `ls-remote <short-name>` lists dozens of upstream versions | the alias file is missing — you are seeing mise's public registry; run `vault-sync` (and check `disable_backends` settings) |
| Raw-file URL returns 404 with a valid token | missing URL-encoding: project path (`devtools%2Fmise-vault`) and nested file paths must be encoded, and `/repository/` is required in the API path |
