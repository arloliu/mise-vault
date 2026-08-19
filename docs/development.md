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
  # downloads ride ~/.netrc — the throwaway HOME needs its own copy
  # (experiment credentials; production uses your real Nexus entry)
  printf "machine 127.0.0.2\n  login developer\n  password dev-mise-vault\n" > "$HOME/.netrc"
  chmod 600 "$HOME/.netrc"
  mise plugins link vault /path/to/your/checkout
  mise ls-remote vault:golangci-lint
  mise install vault:golangci-lint@2.12.2
  mise exec vault:golangci-lint@2.12.2 -- golangci-lint version
'
rm -rf "$T"
```

### Full verification: push to the experiment GitLab and run the suites

The end-to-end suites exercise the real install path
(plugin cloned by mise from GitLab, artifacts pulled from Nexus):

```bash
git push experiment main            # and tags, if the change should be pinnable:
git tag v0.0.X && git push experiment v0.0.X
```

| Suite | Covers | Runtime |
|---|---|---|
| `experiment/scripts/poc-test` | plugin behavior matrix: discovery, installs (archive/runtime/binary), aliases, `.tool-versions`, fail-closed paths, redirect refusal, catalog update, unsupported platform | ~2 min |
| `experiment/scripts/bootstrap-test` | the full new-developer flow: netrc clone, `install.sh` self-detection, generated config, public-backend blocking, idempotency, `vault-sync` | ~2 min |
| `experiment/scripts/offline-test` | everything again inside a Docker network with **no route to the internet** — the release gate: run it before tagging a release | ~2 min |
| `scripts/validate-catalog` | catalog schema + rules, no network | seconds |
| `tests/run-validator-tests` | the validator provably REJECTS unsafe catalog shapes (`tests/fixtures/invalid-catalog/`), no network | seconds |
| `scripts/verify-artifacts --checksum` | every catalog entry exists in Nexus and hashes match (`NEXUS_CURL_OPTS="-u user:pass"` for auth) | ~1 min |

The four test suites are Python on a shared harness in `tests/lib`, verified standalone by `tests/run-harness-selftest`.

What the pass counts vouch for:
`poc-test` runs its behavior matrix against your **working tree**
(it links the checkout as the plugin and prints the reviewed commit);
only its first phase uses pinned experiment tags
to exercise the install/re-pin lifecycle over git.
Expected version lists are derived from the catalog at runtime,
so approving a new version does not require editing the suites;
the pinned lifecycle tags default to `v0.0.3`/`v0.0.4`/`v0.0.14` and can be
overridden with `EXPERIMENT_TAG_A`, `EXPERIMENT_TAG_B`, and `EXPERIMENT_PIN_TAG`
on a freshly provisioned experiment GitLab.
`bootstrap-test` clones from the experiment GitLab
and **fails loudly if its default branch is not your local HEAD** —
push to the `experiment` remote before running it.
Each suite prints `RESULT: N passed, M failed` and exits nonzero on any failure.

Known limitation: only `linux-amd64` installs are executed end-to-end.
The other approved platforms (`linux-arm64`, `darwin-arm64`) are covered by
artifact existence + checksum verification and by the platform-data validation,
but nothing executes their binaries — there is no arm64/macOS host in the stack.

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

## Catalog changes: adding and updating tools

The catalog is the company allowlist —
a version becomes installable the moment its record lands on the default branch,
and never before.
Both workflows below end in an ordinary merge request;
CI (validate → verify existence → verify checksums → real install) is the approval gate.

Credentials first (auth rides `NEXUS_CURL_OPTS` or `~/.netrc`, never files in the repo):

```bash
export NEXUS_CURL_OPTS="-u developer:dev-mise-vault"   # experiment credentials
```

### Approving a new version of an existing tool

Precondition: the artifact for every supported platform is already uploaded to Nexus
under `<nexus_url>/<tool>/<version>/<artifact-file>`
(upload is a separate, admin-side step — this repository only records approvals).

```bash
scripts/add-version <tool> <version>   # e.g. scripts/add-version golangci-lint 2.12.3
scripts/validate-catalog
scripts/verify-artifacts --checksum --tool <tool>
```

`add-version --dry-run` prints the record it would append without touching
`versions.json` — useful the first time you approve a version for a new tool.

`add-version` does three things, all fail-closed:

1. verifies the artifact exists in Nexus for every platform declared in `tool.json`
   (a specific error tells you whether it is missing, an auth failure, or a refused redirect);
2. takes the SHA-256 from the `<artifact>.sha256sum` sidecar when present,
   otherwise downloads and hashes the artifact itself —
   either way the value is frozen into `versions.json`,
   and installation verifies against the catalog value only, never the sidecar;
3. appends one record to the END of `catalog/<tool>/versions.json` —
   the array is ordered oldest-approved first and is append-only;
   never reorder or rewrite existing records
   (revoking a version is the one exception: delete its record, keep the order).

Then open a merge request with the diff — it should be one small appended record.

### Adding a brand-new tool

1. Upload the artifacts (all platforms, plus optional `.sha256sum` sidecars) to Nexus
   under `<tool>/<version>/`.

2. Author `catalog/<tool>/tool.json` by hand — copy the closest existing tool:
   - `glab` — archive with a `bin/` directory (`strip_components: 0`, `bin_paths: ["bin"]`)
   - `golangci-lint` — archive nested in a versioned directory (`strip_components: 1`)
   - `go` — full runtime distribution (`bin_paths` + `env` for GOROOT)

   ```json
   {
     "name": "mytool",
     "type": "archive",
     "platforms": {
       "linux-amd64": {
         "artifact": "mytool_{version}_linux_amd64.tar.gz",
         "format": "tar.gz",
         "strip_components": 0,
         "bin_paths": ["bin"]
       }
     }
   }
   ```

   Field rules (enforced by the validator, so trying is cheap):
   - `name` must equal the directory name.
   - `platforms` keys are canonical ids (`linux-amd64`, `darwin-arm64`, ...);
     list exactly the platforms you uploaded — installs on any other platform fail closed.
   - `artifact` is an explicit file name template per platform;
     only `{version}` is substituted, nothing is inferred from OS or architecture.
     It must be a plain file name — no path separators, no shell metacharacters.
   - `format`: `tar.gz` / `tar.xz` / `tar.bz2` / `zip`, or `binary`
     for a single executable copied as `<install_path>/<tool>` and marked executable.
   - `bin_paths`: directories (relative to the install dir, `.` allowed, `..` never)
     that go on PATH.
   - `env` (optional): extra environment variables;
     `{install_path}` and `{version}` are substituted (e.g. `"GOROOT": "{install_path}"`).

3. Approve the first version and validate — same commands as above:

   ```bash
   scripts/add-version <tool> <version>
   scripts/validate-catalog
   scripts/verify-artifacts --checksum --tool <tool>
   ```

4. Smoke it end-to-end against your working tree
   (see "Fast iteration: link the working tree" above), then open the merge request.

5. After the merge, developer machines pick the tool up on their next
   `mise run vault-sync` — the generated alias file is derived from the catalog,
   so a new tool means a new short-name alias automatically.

Fixture note: `tests/fixtures/catalog/` holds schema-VALID entries that fail at
runtime on purpose (wrong checksum, unsupported platform) for the behavior suites;
`tests/fixtures/invalid-catalog/` holds the shapes the validator must REJECT,
exercised by `tests/run-validator-tests`.

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
