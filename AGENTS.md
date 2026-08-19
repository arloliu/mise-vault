# AGENTS.md — mise-vault

Guidance for AI agents and new contributors working in this repository.

## What this project is

mise-vault is a private backend plugin for [mise](https://mise.jdx.dev)
that distributes centrally approved developer tools inside an isolated enterprise network.

- A **private GitLab** hosts this repository: the plugin code plus the approved-tool catalog.
- A **private Nexus** stores immutable prebuilt artifacts under `<base>/<tool>/<version>/<file>`.
- Developers use ordinary mise commands (`mise ls-remote go`, `mise use go@1.26.0`, `mise install`);
  they never see Nexus URLs, archive layouts, checksums, or backend names.
- After a one-time bootstrap, normal operation needs **no public internet access**
  and must never fall back to GitHub, public registries, or upstream release APIs.

The catalog is the security boundary:
an artifact existing in Nexus does not make it installable —
only a version listed in `catalog/<tool>/versions.json` is approved.
`mise ls-remote` means "what has the company approved", never "what exists upstream".

## Repository layout

```
metadata.lua            plugin identity (backend plugin name: vault)
hooks/                  the three mise backend hooks (list versions, install, exec env)
lib/common.lua          shared helpers: catalog loading, platform id, URL building
catalog/<tool>/         tool.json (packaging) + versions.json (approved versions + sha256)
config/defaults.json    default Nexus base URL
schemas/                JSON Schemas for the two catalog file types
scripts/                catalog tooling: approve, add-version, validate-catalog, verify-artifacts, vault-sync
install.sh              workstation bootstrap (idempotent)
tests/fixtures/         intentionally broken catalog entries for negative tests
tests/lib/              shared python test harness
tests/run-harness-selftest   self-test for the shared harness
experiment/             local Docker stack (Nexus + GitLab CE) and end-to-end test suites
docs/development.md     developer guide: environment, dev loop, test suites, troubleshooting
docs/design.md          the living design document (amended from the original proposal)
docs/research/          research notes and the decision log (SYNTHESIS.md)
tmp/                    scratch area, not part of the deliverable
```

## Writing principles

- **No jargon in code or scripts.**
  Comments and messages must be self-contained plain English.
  Never cite internal shorthand — no "§35", no "decision D7", no "see SYNTHESIS".
  If a rule matters to the code, state the rule itself where it applies;
  the numbered trail lives only under `docs/research/`.
- **Fail closed.**
  Unknown tool, unapproved version, unsupported platform, missing artifact, checksum mismatch:
  each aborts with a specific error message.
  Never add a fallback to a public service, and never make checksum verification optional.
- **Data over code.**
  Adding a normal tool means adding `catalog/<tool>/tool.json` and `versions.json`,
  not writing tool-specific Lua.
- **No credentials in files.**
  Auth rides `~/.netrc` (via git and `curl -n`) or environment-provided CI variables.
  Catalog files, configs, and scripts never embed tokens or passwords.
- **Generated files are never hand-edited.**
  `~/.config/mise/conf.d/mise-vault.toml` is derived from the catalog by `scripts/vault-sync`;
  regenerate it, do not patch it.
- **Commit messages follow Conventional Commits.**
  Subject line `type: summary` (types used here: feat, fix, docs, test, ci, build, refactor, chore),
  imperative mood, lowercase after the colon, no trailing period.
  The no-jargon rule applies to commit messages too:
  describe the change itself in plain English —
  never reference internal process artifacts
  (review round numbers, report files, decision IDs).

## Decisions that bind the implementation

Full reasoning and evidence: `docs/research/SYNTHESIS.md`.
The operative rules:

- Bootstrap writes user-scoped mise settings `gix = false` and `libgit2 = false`
  so plugin git operations use the real git binary and its credential chain (netrc included).
  Both must be false — either one being true selects mise's built-in git implementation,
  which ignores netrc and credential helpers.
- Artifact downloads and checksums shell out (`curl -fsSL -n`, `sha256sum` / `shasum -a 256`).
  The plugin's built-in Lua HTTP module never reads netrc, so it is not used for authenticated downloads.
- `versions.json` is an ordered array, oldest approved first.
  The plugin returns that order verbatim; CI validates ordering and uniqueness.
  Runtime code makes no assumption that versions are semver.
- Artifact names are explicit per-platform template strings with only `{version}` substituted.
  Platform resolution is one-way: mise's runtime info yields a canonical key like `linux-amd64`,
  which selects a platform entry in `tool.json`.
  Nothing ever parses an artifact file name to infer OS or architecture.
- The Nexus base URL is committed in `config/defaults.json` (it is not a secret; auth never lives in URLs)
  and read from the plugin checkout at install time,
  so it always matches the installed plugin version.
  A per-project tool option can override it; generated aliases are pure routing and carry no URL.
  Environment variables are NOT a supported channel —
  mise sandboxes `os.getenv` inside plugin hooks (see lessons below).
- Sidecar checksum files in Nexus (`<artifact>.sha256sum`) feed `scripts/add-version` only.
  Installation verifies against the catalog value exclusively:
  a checksum stored next to the artifact it describes proves nothing if the store is compromised.
- `install.sh` enforces mise >= 2026.8.1
  (set by the archive extractor's `strip_components` support; numeric calver comparison).
- Bootstrap is git-based (`git clone --depth 1 -b <tag>` then run `install.sh`),
  not `curl | sh` — see the GitLab raw-route lesson below.
  `install.sh` self-detects the version and repository URL from the checkout it runs in:
  a tagged checkout installs that tag, a branch checkout installs the exact cloned commit.
  Every commit on the default branch is a valid current version
  (the approval boundary is merge request + CI, not tagging);
  tags are optional markers for pinning and rollback,
  and users update with `mise run vault-sync latest` or `mise run vault-sync <tag>`.

## Lessons learned (empirical, against mise v2026.8.8 and current GitLab/Nexus)

- **mise clones plugins with a built-in Rust git by default.**
  netrc and credential helpers only work after setting `gix = false` AND `libgit2 = false`
  (the code path is selected by OR of the two settings).
- **`os.getenv` inside plugin Lua hooks does not read the real environment.**
  mise routes it through a sanitized internal table that omits almost everything.
  Subprocesses started via the `cmd` module DO inherit the real environment
  (which is why `curl -n` finds `~/.netrc`).
- **The Lua plugin API has archive extraction but no hashing.**
  `archiver.decompress` handles tar.gz/tar.xz/tar.bz2/zip; SHA-256 must shell out.
- **GitLab's `/-/raw/` web route accepts no token authentication on private projects.**
  Basic auth, the `PRIVATE-TOKEN` header, and `?private_token=` all redirect (302) to the sign-in page.
  Use `git clone` (netrc) or the `/api/v4/projects/:id/repository/files/:path/raw?ref=` endpoint
  with a `PRIVATE-TOKEN` header.
  Two encoding traps in that API URL (each produces a 404, not an auth error):
  the project path must be URL-encoded (`devtools%2Fmise-vault`, or use the numeric project ID),
  and a nested file path must be too (`scripts%2Fvault-sync`).
  The path segment `/repository/` is required.
- **A 302 redirect can look like success.**
  `curl -sf` exits 0 on a 302 with an empty body,
  which once produced a false "basic auth works" conclusion here.
  When probing endpoints, always check `-w '%{http_code}'` and the final URL, not just the exit code.
- **If the generated alias file is missing, short names silently fall back to mise's public registry**
  (observed live: `glab` resolved to a public backend and contacted gitlab.com).
  Bootstrap therefore disables all public backends
  (`disable_default_registry=true` plus a full `disable_backends` list — `core` included, which works);
  listing `vfox` there does not affect this plugin, which is addressed by its own name.
  Tests must assert the resolving backend (`mise tool <name>` shows `vault:<name>`),
  and network isolation remains the only hard guarantee of private-only operation.
- **`MISE_OFFLINE=1` does not block this plugin's downloads**
  (they run through `cmd`-spawned curl, outside mise's own HTTP layer).
  Never-contact-the-internet is enforced by the plugin constructing only Nexus URLs.
- **Under `set -o pipefail`, piping a failing mise command into `grep -q` hides the match** —
  the nonzero mise exit wins the pipeline status. Capture output into a variable first, then grep.
- **An alias pointing at an uninstalled plugin does not auto-install it.**
  Bootstrap must install the plugin before the aliases become usable.
- **netrc matches hostname only — there is no port field.**
  Two services on different ports of the same hostname share credentials.
  The local experiment avoids this by addressing Nexus as `127.0.0.2` and GitLab as `127.0.0.3`.
- **Nexus Community Edition requires accepting the EULA via REST before any upload** (HTTP 403 until then),
  and contrary to some documentation, password change and anonymous-access toggles DO have REST endpoints.
- **GitLab rejects weak values for the initial root password and then fails the entire first boot.**
  Use a strong password and wipe the volumes before retrying.
- **`install.sh` must be executed directly or with bash.**
  Piping to `sh` runs dash on Debian/Ubuntu, which rejects `set -o pipefail`.

## Development environment

`experiment/` contains a Docker stack simulating the private infrastructure:

```bash
cd experiment
docker compose up -d
./scripts/provision-nexus.sh      # idempotent; creates repo, users, uploads a smoke artifact
./scripts/provision-gitlab.sh     # idempotent; first GitLab boot takes several minutes
./scripts/seed-artifacts.sh       # one-time: fetches real tools from the internet into Nexus
```

Test suites (each runs in an isolated throwaway `$HOME`; the real machine config is never touched):

```bash
./experiment/scripts/poc-test          # plugin behavior matrix; links the WORKING TREE as the plugin
./experiment/scripts/bootstrap-test    # full bootstrap flow; asserts experiment GitLab serves local HEAD
./experiment/scripts/offline-test      # release gate: everything inside a no-internet network
scripts/validate-catalog               # catalog static validation (no network)
tests/run-validator-tests              # validator must REJECT unsafe catalog shapes (no network)
scripts/verify-artifacts [--checksum]  # catalog vs Nexus (network)
```

Every external fetch point (compose images, test-image base/apt/mise, CI job
images, pip) is overridable toward private mirrors —
see "Private mirror / proxy overrides" in `experiment/README.md`.

The experiment GitLab hosts a copy of this repository (`devtools/mise-vault`) with version tags;
after changing plugin code, sync and tag there before re-running the end-to-end suites.
Credentials for the experiment stack are in `experiment/README.md` (test-only values).

## Verification discipline

Claims about mise behavior must be verified against the currently installed mise release
(check `mise --version`), not assumed from older plugin systems or from memory.
When research and experiment disagree, the experiment wins — record the correction in
`docs/research/` rather than silently editing history.
