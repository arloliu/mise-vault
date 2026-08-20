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
  Artifact and go-installed tools carry this guarantee absolutely:
  the plugin builds every download URL itself, from Nexus or the
  plugin-controlled go proxy, and constructs no other URL.
  npm, pypi, and cargo tool types are a scoped, deliberate exception:
  the plugin constructs no registry URL of its own for them at all —
  they install through the ecosystem's own package manager,
  which reads whatever registry, proxy, and auth configuration
  the user's own environment already has,
  and egress there is enforced by the network, not by the plugin
  (see "Decisions that bind the implementation" below).

The catalog is the security boundary:
an artifact existing in Nexus does not make it installable —
only a version listed in `catalog/<tool>/versions.json` is approved.
`mise ls-remote` means "what has the company approved", never "what exists upstream".

## Repository layout

```
metadata.lua            plugin identity (backend plugin name: vault)
hooks/                  the three mise backend hooks (list versions, install, exec env)
lib/common.lua          shared helpers: catalog loading, platform id, URL building
catalog/<tool>/         tool.json (packaging) + versions.json (approved versions;
                        sha256 for artifact tools, no checksum field for npm/pypi/cargo)
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
  Never add a fallback to a public service,
  and never make artifact SHA-256 verification optional.
  Two deliberate exceptions exist, both bounded by the approved-version list.
  A go-tool version record may omit its `h1` module checksum
  (an explicit proxy-trust entry, requiring `--no-h1` at approval time) —
  but a recorded `h1` is always enforced.
  npm, pypi, and cargo tool types are version-pin-only by design:
  none of these ecosystems supports an ad-hoc per-install content hash
  the way go's `h1` does, so no checksum field exists for them at all,
  and there is nothing to make optional.
  In every case the approved-version list still gates every install.
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
  Override precedence, first match wins: the `MISE_VAULT_NEXUS_URL` environment variable
  (a shell export, or an `[env]` entry in a trusted mise.toml)
  > per-tool `nexus_url` option > `config/defaults.json`.
  Generated aliases are pure routing and carry no URL.
  Every channel passes the same URL-shape validation before use.
- Sidecar checksum files in Nexus (`<artifact>.sha256sum`) feed `scripts/add-version` only.
  Installation verifies against the catalog value exclusively:
  a checksum stored next to the artifact it describes proves nothing if the store is compromised.
- `install.sh` enforces mise >= 2026.8.1
  (set by the archive extractor's `strip_components` support; numeric calver comparison).
- Every bootstrap path ends in the same `install.sh`.
  Documented entry paths, in order:
  (1) `MISE_GIX=false MISE_LIBGIT2=false mise plugin install vault <url>[#<tag>]`,
  then run the cloned checkout's `install.sh`
  (the one-shot env vars select the real git binary, which reads netrc,
  before the settings file exists — install.sh then persists those settings);
  (2) token-based fetch of `install.sh` via the GitLab files API with a `PRIVATE-TOKEN` header
  (never the `/-/raw/` web route — see the lesson below),
  driven by `MISE_VAULT_REF` / `MISE_VAULT_REPO_URL`;
  (3) `git clone --depth 1 [-b <tag>]`, then run `install.sh`.
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
  Both accept mise's settings env-var form —
  `MISE_GIX=false MISE_LIBGIT2=false` works for a first run before any settings file exists,
  and `mise settings get` reflects them.
- **`os.getenv` inside plugin Lua hooks DOES read the real environment**
  (verified empirically in both `BackendListVersions` and `BackendInstall`):
  shell exports and plain `[env]` entries from a trusted mise.toml are both visible.
  An earlier source-derived conclusion said mise routes it through a sanitized table
  that omits almost everything; the experiment contradicts that
  (correction recorded in `docs/research/plugin-hooks-and-config-channels.md`).
  Subprocesses started via the `cmd` module also inherit the real environment
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
- **mise strips its own managed tool paths from PATH while plugin hooks run**
  (verified against mise v2026.8.8: inside `BackendInstall`, `go` resolved to the
  system toolchain even under `mise exec go@… -- mise install …`).
  A hook that needs another mise-installed tool must locate it in
  `~/.local/share/mise/installs/<tool>/<version>/` itself; putting it on PATH first
  does not survive into the hook.
  Non-mise directories prepended to PATH do survive.
- **go's module client follows cross-host redirects and cannot be told not to.**
  The artifact path refuses redirects (`curl --max-redirs 0`), but `go mod download`
  and `go install` follow whatever the go proxy answers.
  A compromised or misconfigured proxy could redirect module fetches to another host;
  network egress policy, not the plugin, is what makes that unreachable in production.
- **`MISE_OFFLINE=1` does not block this plugin's downloads**
  (they run through `cmd`-spawned curl, outside mise's own HTTP layer).
  For artifact and go installs, never-contact-the-internet is enforced by the
  plugin constructing only Nexus and plugin-controlled-proxy URLs.
  npm, pypi, and cargo installs are the scoped exception to that mechanism:
  the plugin constructs no registry URL for them at all —
  the selected runner (cargo is always the runner for a cargo tool; there
  is no MISE_VAULT_CARGO_RUNNER) uses whatever registry the user's own
  environment configures, and egress there is enforced by the network,
  not the plugin.
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
- **pipx's install-location pins are not all honored on every pipx version.**
  Verified against pipx 1.4.3: `PIPX_HOME` and `PIPX_BIN_DIR` place the
  installation and its binaries exactly where told.
  `PIPX_MAN_DIR`, `PIPX_COMPLETION_DIR`, `PIPX_DEFAULT_BACKEND`, and
  `PIPX_FETCH_PYTHON` are silently inert on a pipx older than the release
  that introduced each one —
  so the no-leftover-files guarantee (man pages, completions) and the
  pinned-backend guarantee only hold on a sufficiently recent pipx.
  The plugin always sets all of them regardless:
  the pins are forward-compatible and a pipx too old to honor one just
  ignores it, so there is no reason to omit them.
- **A plugin hook's `print()` output IS visible in default `mise install`
  output**, surfacing as `INFO [vault] ...` lines —
  verified against the experiment stack.
  This is how the npm/pypi install branches' effective-registry diagnostic
  line (e.g. `npm config get registry`) reaches an ordinary developer
  without any extra flag.
- **A Nexus role created by provisioning must be create-or-update, not
  create-once, once other repositories start relying on it.**
  `devtools-read` was create-once; adding the npm-proxy and pypi-proxy
  read privileges to the script did not propagate to a role that already
  existed on a previously provisioned stack.
  Anyone who provisioned before the npm/pypi repos existed must re-run
  `provision-nexus.sh` once to pick up the new privileges.
  The cargo proxy repository (Phase B) adds both a new repository and its
  own scoped anonymous-read role the same way the npm/pypi proxies did,
  so the same re-run requirement extends to anyone who provisioned before
  cargo-proxy existed.
- **Pinning `CARGO_HOME` system-wide silently severs the user's own
  `~/.cargo/config.toml` registry channel** — verified while building the
  cargo test-image layer: with `CARGO_HOME` pinned to a fixed system
  directory, `cargo install` ignored a `~/.cargo/config.toml` written
  under a different `$HOME` entirely and went straight to
  `index.crates.io` instead of the configured proxy.
  Leave `CARGO_HOME` unset (it then defaults to `$HOME/.cargo`, cargo's
  own default) whenever the user's registry configuration must keep
  working; pin only `RUSTUP_HOME` and `PATH` for toolchain discovery,
  since those hold system-level toolchain state rather than the
  per-user registry configuration.
- **Ubuntu 24.04's apt `rustc`/`cargo` (1.75.0) cannot build current
  crates** — verified empirically: `cargo install tokei --version 14.0.0
  --locked` fails because a dependency (`clap-cargo`) requires rustc
  1.86 or newer.
  A rustup-installed stable toolchain (verified: 1.97.1) builds it in
  well under a minute against a warm proxy cache, so the cargo test
  image installs rustup instead of the distribution package.
  Separately, `gcc` alone is not enough for the one C linker cargo needs
  when the image is built with `--no-install-recommends`: `libc6-dev`
  must be named explicitly, since `gcc` only recommends it rather than
  depending on it, and without it linking fails with a missing
  `crt1.o`/`crti.o` and C runtime libraries.

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
