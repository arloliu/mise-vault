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
| `tests/run-approve-tests` | approve pre-flight must REJECT malformed or duplicate batch specs before any write, no network | seconds |
| `scripts/verify-artifacts --checksum` | every catalog entry exists in Nexus and hashes match (`NEXUS_CURL_OPTS="-u user:pass"` for auth) | ~1 min |

The five test suites are Python on a shared harness in `tests/lib`, verified standalone by `tests/run-harness-selftest`.

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
scripts/approve <tool>@<version> [<tool>@<version> ...]
# e.g. scripts/approve golangci-lint@2.12.3 glab@1.55.0
```

One command runs the whole flow:
it pre-flights every spec (nothing is written unless the whole batch parses and is new),
appends each record via `add-version` (fail-fast: the first failure stops the batch,
already-appended records are each individually verified and stay in place),
then runs `validate-catalog` and `verify-artifacts --checksum` for the touched tools
and prints the suggested git commands.

`approve --dry-run` rehearses the whole batch (artifact existence and checksums included)
without touching `versions.json` — useful the first time you approve a version for a new tool.

The underlying single-spec engine is still available
(`scripts/add-version <tool> <version>` plus the validate/verify commands it prints),
and everything below describes its behavior — `approve` adds batching and orchestration only.

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

   Every field is explained with worked examples in the
   [`tool.json` field reference](#tooljson-field-reference) below.
   The validator enforces all of those rules, so trying is cheap.

3. Approve the first version and validate — same command as above:

   ```bash
   scripts/approve <tool>@<version>
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

### `tool.json` field reference

A `tool.json` answers exactly two questions:
how to fetch and unpack one artifact per platform (used at **install** time),
and what the shell needs once the tool is installed (used at **activation** time).

Top-level fields:

| Field | Required | Meaning |
|---|---|---|
| `name` | yes | must equal the catalog directory name (`catalog/<name>/tool.json`) |
| `type` | yes | classification for humans reading the catalog: `archive`, `binary`, or `runtime`. Install behavior keys off each platform's `format`, not off `type` |
| `platforms` | yes | one entry per supported platform — every per-platform field below lives here |
| `env` | no | extra environment variables at activation — see below |

#### `platforms` — list exactly what you uploaded

Keys are canonical `<os>-<arch>` ids: `linux-amd64`, `linux-arm64`, `darwin-arm64`, ...
A platform missing here (or missing from the version record) fails closed with
`<tool> <version> is not available for <platform>` — so listing a platform is a
promise that its artifact exists in Nexus for every approved version.

#### `artifact` — the exact file name in Nexus, spelled out per platform

The download URL is `<nexus_url>/<tool>/<version>/<artifact>`.
Only `{version}` is substituted; nothing is ever inferred from OS or architecture,
which is why each platform spells out its own complete file name:

```json
"linux-amd64":  { "artifact": "glab_{version}_linux_amd64.tar.gz",  ... },
"darwin-arm64": { "artifact": "glab_{version}_darwin_arm64.tar.gz", ... }
```

With version `1.113.0` the first becomes `glab_1.113.0_linux_amd64.tar.gz`.
It must be a plain file name — no path separators, no shell metacharacters;
the plugin refuses anything else before building the URL.

#### `format` — how the artifact unpacks

- `tar.gz` / `tar.xz` / `tar.bz2` / `zip` — extracted into the tool's install
  directory, honoring `strip_components`.
- `binary` — the artifact IS the executable: it is copied to
  `<install_path>/<tool>` and marked executable
  (`strip_components` does not apply; leave `bin_paths` at its `["."]` default).

#### `strip_components` — flatten the archive's wrapper directory

Same meaning as `tar --strip-components`:
how many leading path components to drop from every entry while extracting.
Default `0`.
Decide by listing the archive — two real cases from this catalog:

```console
$ tar tzf golangci-lint-2.12.2-linux-amd64.tar.gz | head -3
golangci-lint-2.12.2-linux-amd64/LICENSE
golangci-lint-2.12.2-linux-amd64/README.md
golangci-lint-2.12.2-linux-amd64/golangci-lint
```

Everything sits inside one versioned wrapper directory, so `strip_components: 1`
places `golangci-lint` directly in the install dir (then `bin_paths: ["."]`).

```console
$ tar tzf glab_1.113.0_linux_amd64.tar.gz | head -4
CHANGELOG.md
LICENSE
README.md
bin/glab
```

No wrapper — the layout is already right, so `strip_components: 0`
(then `bin_paths: ["bin"]`).

Rule of thumb: if every entry starts with the same wrapper directory
(usually named after the version), use `1`; otherwise `0`.

#### `bin_paths` — which installed directories go on PATH

Directories relative to the install dir whose executables should be on PATH,
in order; `"."` is the install dir itself.
Never absolute, never containing `..`.
Omitted means `["."]`.

- golangci-lint (after `strip_components: 1`): executable at `<install>/golangci-lint` → `["."]`
- glab: executable at `<install>/bin/glab` → `["bin"]`
- go: executables at `<install>/bin/go`, `<install>/bin/gofmt` → `["bin"]`

#### `env` — extra environment variables at activation

Optional and top-level (not per-platform). Exported whenever the tool is
active, alongside PATH. Values may use `{install_path}` and `{version}`:

```json
"env": { "GOROOT": "{install_path}" }
```

Use it for runtime distributions that need a home variable
(`GOROOT`, `JAVA_HOME`, ...); ordinary CLI tools do not need it.

## Nexus URL override channels

The plugin builds every download URL from one base, resolved first match wins:

1. `MISE_VAULT_NEXUS_URL` environment variable —
   a shell export, or an `[env]` entry in a trusted `mise.toml`
   (handy for ad-hoc testing against a scratch Nexus without touching any config);
2. per-tool `nexus_url` option
   (`[tools]` entry or a bracketed alias option, e.g. `vault:go[nexus_url=...]`);
3. `config/defaults.json` bundled in the plugin checkout.

Every channel passes the same URL-shape validation before use,
and the plugin never follows redirects, whichever channel supplied the URL.
Covered end-to-end by poc-test's override phase.

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
