# Extending mise-vault beyond go install: cargo, npm, bun, pip, uv

> **Reading note (added 2026-08-20).**
> This research was commissioned while the working assumption was still
> "redirect every ecosystem to a private Nexus repository via env vars,
> exactly like the go-proxy design".
> The design direction then changed:
> for cargo/npm/bun/pip/uv the plugin will INHERIT the developer's own
> environment (registry settings, proxies, auth) instead of overriding it —
> see docs/specs/2026-08-20-ecosystem-tools-design.md.
> The registry-redirection sections below are therefore background, not
> requirements; the still-load-bearing findings are the
> install-at-pinned-version commands, the placement controls
> (install/bin directories), the integrity-pinning capabilities table,
> the runtime dependencies, and the per-registry version-listing APIs.

Research date: 2026-08-19.
Scope: whether and how mise-vault's go-install pattern
(spawn the ecosystem's native installer, redirect it entirely to a private
Nexus proxy via env vars, `GOSUMDB=off`-style integrity handling, `~/.netrc`
auth, fail-closed with no public-registry fallback)
generalizes to cargo, npm, bun, pip, and uv.

Method: five parallel research passes against official primary docs
(doc.rust-lang.org/cargo, docs.npmjs.com, bun.sh/docs, pip.pypa.io,
docs.astral.sh/uv, help.sonatype.com), each cross-checked empirically where
the tool was available locally. Locally installed and version-verified:
cargo 1.95.0 / rustc 1.95.0, npm 11.12.1 / node v25.9.0, pip 24.0 (Debian
packaging) / python3.12.3, uv 0.12.4. **bun was not available locally** —
its section rests on docs only, with gaps flagged explicitly. Findings
labeled "verified empirically" were tested live against the installed
binary; "per docs" claims come only from the cited page.

---

## 1. cargo (Rust)

Verified against cargo 1.95.0 / rustc 1.95.0.
All citations `doc.rust-lang.org/cargo/...` unless noted.

### 1.1 Pinned-version install command

```bash
cargo install ripgrep --version 14.1.0 --root /opt/vault/ripgrep/14.1.0 --locked
```

- `--root <dir>` puts the binary at `<dir>/bin/<name>`. Precedence: `--root`
  flag > `CARGO_INSTALL_ROOT` env var > `install.root` config >
  `CARGO_HOME` env var > `$HOME/.cargo`.
  [cargo-install](https://doc.rust-lang.org/cargo/commands/cargo-install.html)
- `--version <v>` as a bare `MAJOR.MINOR.PATCH` is an exact `=` pin;
  version-range operators (`~1.2`, `^1.0`) pick the newest match instead —
  use the bare three-part form for a true pin.
- No project/`Cargo.toml` needed: `cargo install` "operates at system or
  user level, not project level"; config resolution starts at
  `$CARGO_HOME/config.toml`, not the current directory.
- `--locked` replays the crate's own shipped `Cargo.lock` verbatim
  (reproducible builds, requires the crate to have been published with
  Cargo 1.37+); `--offline`/`--frozen` (`--locked` + `--offline`) round out
  the offline story.

### 1.2 Private-registry env vars — the crux, resolved

Two separate mechanisms exist, and mise-vault needs the second one, not the
first:

**Source replacement (`[source.*]`) has no env-var form, at all, for any
key.** Every one of the eight `[source.<name>]` keys (`replace-with`,
`directory`, `registry`, `local-registry`, `git`, `branch`, `tag`, `rev`)
is documented as `Environment: not supported`
([config reference](https://doc.rust-lang.org/cargo/reference/config.html#source)).
The Source Replacement chapter itself says this mechanism is for
vendoring/mirroring and explicitly disclaims private-registry use: "this is
not appropriate for … private registries … see the Registries chapter."
([source replacement](https://doc.rust-lang.org/cargo/reference/source-replacement.html))

**But `[registries]` + `registry.default` has full env-var support and is
sufficient.** `registries.<name>.index` → env
`CARGO_REGISTRIES_<NAME>_INDEX`; `registry.default` → env
`CARGO_REGISTRY_DEFAULT` (default `"crates-io"`).
[config reference](https://doc.rust-lang.org/cargo/reference/config.html#registries)
The `cargo install` reference page confirms `cargo install` itself, when
`--registry`/`--index` are omitted, falls back to `registry.default`, not a
hardcoded crates.io.

**This was verified empirically, not just read from docs.** In an isolated
`CARGO_HOME` with no `config.toml` anywhere:

```
CARGO_REGISTRIES_BOGUS_INDEX="sparse+http://127.0.0.1:9/" \
  CARGO_REGISTRY_DEFAULT=bogus CARGO_NET_RETRY=0 \
  cargo install ripgrep --version 14.1.0 -v --root ./installA2
```

went straight to the bogus registry (connection-refused on `127.0.0.1:9`)
and never touched crates.io — no fallback attempt, confirmed by a
negative-control run with the same clean `CARGO_HOME` and no env override
succeeding against real crates.io.

**Why this covers transitive deps, and the one real gap.** Each dependency
entry in the sparse index JSON carries a `registry` field: "If not
specified or `null`, it is assumed the dependency is in the current
registry"
([registry index format](https://doc.rust-lang.org/cargo/reference/registry-index.html)).
Since a Nexus crates.io *proxy* mirrors the real index byte-for-byte, that
field stays absent, and the whole transitive graph resolves inside the
named registry. The gap: if an index entry ever carried an *explicit*
non-null `registry` URL pointing at crates.io (a hand-curated multi-source
index would do this), only true `[source]` replacement — config-file only,
no env path — could intercept it; env vars alone cannot cover that case.
Recommendation: pass `--registry` explicitly on every `cargo install`
invocation rather than relying on `registry.default` alone, as
defense-in-depth against an operator later unsetting the env var.

`CARGO_REGISTRIES_CRATES_IO_PROTOCOL` only controls protocol (`git` vs
`sparse`, default `sparse`) for the literal built-in `crates-io` source —
irrelevant once using a separate named registry.
`CARGO_REGISTRY_GLOBAL_CREDENTIAL_PROVIDERS` is the env form of
`registry.global-credential-providers` (default `["cargo:token"]`) — a
fallback credential-provider *selector*, not itself an auth mechanism.

**Sparse protocol**: the `sparse+https://…` URL prefix tells cargo to fetch
per-crate metadata files individually over plain HTTPS instead of cloning a
git index. Nexus's cargo proxy speaks this protocol exclusively (see 1.7).

**Honest gap**: this `registry.default` fallback behavior is confirmed for
`cargo install` specifically (both by doc text and by the empirical test
above); official docs don't state it's guaranteed for every subcommand
(`cargo add`, workspace builds against a checked-in `Cargo.lock` recording
a crates.io source). Don't generalize beyond the `cargo install` use case
mise-vault actually needs.

### 1.3 Blocking public fallback

Answered above — with only `CARGO_REGISTRIES_<NAME>_INDEX` +
`CARGO_REGISTRY_DEFAULT` set (or `--registry <name>` passed explicitly),
crates.io is never contacted for `cargo install`, verified live. The one
structural gap (an index entry with an explicit non-null `registry` field)
is not reachable through a plain Nexus mirror of the real index.

### 1.4 Toolchain side-channel fetches

cargo/rustc themselves have no telemetry and don't auto-update. **rustup
(the toolchain manager) does auto-install a missing toolchain.**
`RUSTUP_AUTO_INSTALL` (default `1`, i.e. enabled) — "installs the active
toolchain when it is absent. Set this value to `0` to disable automatic
installation."
([rustup env vars](https://rust-lang.github.io/rustup/environment-variables.html))
Per the Inside Rust blog, this fires "whenever rustup is invoked, including
proxy invocations such as `rustc` and `cargo`," reaching
`static.rust-lang.org` by default (mirror override: `RUSTUP_DIST_SERVER`).
`RUSTUP_TOOLCHAIN` pins/overrides which already-installed toolchain proxy
invocations use, and fails closed (doesn't fetch) if that toolchain is
missing.

**Set `RUSTUP_AUTO_INSTALL=0`** as a bootstrap-time export, the direct
analogue of `GOTOOLCHAIN=local` — this is the one rustup-mediated path that
could otherwise silently reach the public internet regardless of how
cargo's own registry traffic is redirected.

`CARGO_NET_OFFLINE` (config `net.offline`, default `false`) only governs
cargo's own network use (registry index, `.crate` downloads, git deps) —
it does not touch rustup's separate toolchain-fetch gate.

### 1.5 Integrity pinning

**Automatic and index-carried, not user-suppliable per invocation.** Every
version entry in the registry index carries `cksum` (SHA-256 of the
`.crate` file), which cargo checks automatically. **There is no
`cargo install --sha256 <hash>` flag or equivalent** — unlike go's module
hash verification, this is index-trust-based, not caller-suppliable.
`Cargo.lock` also records a `checksum` field, but that's for whole-project
`--locked` reproducible builds using the crate's own shipped lockfile, not
an independently caller-supplied pin.

**This is a real conflict with mise-vault's own fail-closed principle.**
The checksum cargo verifies is served *by the same registry index that
serves the tarball* — structurally the exact pattern AGENTS.md already
forbids ("a checksum stored next to the artifact it describes proves
nothing if the store is compromised"), just at the index level instead of
a sidecar-file level. Cargo gives no mechanism to independently verify a
catalog-held sha256 at `cargo install` time. If catalog-enforced integrity
is a hard requirement, it has to be enforced outside cargo's own
verification, or accepted as a scoped exception (network/TLS trust to the
Nexus proxy substitutes for it) — a design decision, not a technical gap
to close.

### 1.6 Auth

**No netrc support, confirmed by exhaustive doc search** — "netrc" does
not appear anywhere in cargo's config, registry-authentication, or
unstable docs pages. The only netrc-capable path is a **third-party**
credential-provider binary
([cargo-credential-netrc](https://github.com/Nikita240/cargo-credential-netrc)),
not shipped by rust-lang/cargo.

Built-in credential providers: `cargo:token` (plaintext
`credentials.toml`, but *also* honors `CARGO_REGISTRIES_<NAME>_TOKEN` env
vars — "If this credential provider is not listed, then the `*_TOKEN`
environment variables will not work"), plus OS-keychain and
`token-from-stdout <cmd>` variants.
([registry authentication](https://doc.rust-lang.org/cargo/reference/registry-authentication.html))
For a private authenticated registry you must explicitly set
`CARGO_REGISTRIES_<NAME>_CREDENTIAL_PROVIDER=cargo:token` (env var, no
config file needed) plus `CARGO_REGISTRIES_<NAME>_TOKEN=<token>` — this is
cargo's practical env-var-only auth path.

Auth is negotiated via the sparse protocol's `config.json` `auth-required`
flag (stabilized Cargo 1.74, safely predates the installed 1.95.0); on the
Nexus side this maps to "Restrict repository content to authenticated
users" (Nexus 3.75.0+) — without it enabled, Nexus won't request
credentials and cargo won't send any.

**No netrc means mise-vault's established `curl -n` / git-netrc pattern
cannot be reused for cargo's own registry HTTP traffic** — cargo's client
for the sparse protocol/`.crate` downloads is internal, not `curl`-shelled,
and doesn't read `~/.netrc`. Forcing the older git-protocol path
(`CARGO_NET_GIT_FETCH_WITH_CLI=true`, which does shell to real git) is moot
here because Nexus's cargo format only supports the sparse protocol (1.7),
not git. Auth must go through `CARGO_REGISTRIES_<NAME>_TOKEN`.

### 1.7 Nexus repository format

Nexus added native Cargo/Rust format support at **version 3.73.0**
(hosted/proxy/group), **sparse protocol only** — "Nexus Repository only
supports Cargo's `sparse` protocol; the Git protocol is not supported."
([Rust/Cargo](https://help.sonatype.com/en/rust-cargo.html)) At launch this
was Pro-only; it became available in free **Community Edition starting at
3.77.0**, per Sonatype's own CE announcement blog post listing Cargo as one
of the formats moved from paid-only to CE.

**Actionable gap**: `experiment/docker-compose.yml` pins
`sonatype/nexus3:latest` (a floating tag) — cargo format is almost
certainly present today, but this should be pinned/verified against
whatever Nexus version the real production instance runs (>= 3.77.0 for
free-tier cargo support, or confirm a Pro license otherwise); not verified
live here.

Proxy config requires the remote URL to end with a trailing slash (e.g.
`https://index.crates.io/`). If the version/edition constraint can't be
met: a raw/generic Nexus repo hand-serving the sparse index file layout
plus raw-hosted `.crate` blobs works on any edition (more maintenance), or
a dedicated mirror tool (`kellnr`, `panamax`) in front of Nexus/S3.

### 1.8 Runtime dependency

`cargo install` **compiles the crate from source** — it requires the full
Rust toolchain (cargo + rustc) present, confirmed by observed `Compiling
...` output in local testing. This is categorically heavier than
go/uv/bun, which distribute or fetch prebuilt binaries: Nexus's role for
cargo is serving **source packages** (`.crate` tarballs) compiled locally
on every install, not immutable prebuilt binaries matching this project's
existing artifact model. Install time, a working C toolchain/linker for
many crates, and per-install disk/CPU cost are all new categories of cost
relative to the existing backends.

### 1.9 Version listing via plain HTTP

```
GET https://index.crates.io/<prefix>/<name>
```
Prefix rule (lowercase name): 1 char → `1/<name>`; 2 chars → `2/<name>`;
3 chars → `3/<first-char>/<name>`; 4+ chars →
`<first-two>/<next-two>/<name>` (e.g. `cargo` → `ca/rg/cargo`).
([registry index format](https://doc.rust-lang.org/cargo/reference/registry-index.html))

Response is **newline-delimited JSON**, one object per published version,
in publish order. Key fields: `name`, `vers`, `deps[]` (each with
`name`/`req`/`features`/`optional`/`kind`/`registry`/`package`), `cksum`
(SHA-256 of the `.crate`), `features`/`features2`, `yanked` ("the only
field that may be modified after creation"), `links`, `v` (schema
version), `rust_version`, `pubtime`. The index root also carries
`config.json` with `dl` (download URL template), `api`, and optionally
`auth-required`.

### 1.10 The two genuine gaps to design around

1. **No netrc anywhere for cargo's own HTTP traffic.** Auth must be
   `CARGO_REGISTRIES_<NAME>_TOKEN` — env-var-only, but not netrc, breaking
   the netrc-everywhere pattern used elsewhere in this project.
2. **Checksum verification is automatic, internal, and sourced from the
   same index that serves the artifact** — no CLI mechanism to
   independently verify a catalog-held sha256 at install time, unlike this
   project's own Nexus-artifact download path.

---

## 2. npm (Node.js)

Verified against npm 11.12.1 / node v25.9.0.
Citations `docs.npmjs.com/cli/...` unless noted.

### 2.1 Pinned-version install command, predictable bin location

**Global with `--prefix`:**
```
npm install -g --prefix <dir> <pkg>@<version>
```
Verified empirically (installed `cowsay@1.6.0` into a clean directory with
no pre-existing `package.json`):
- Binaries land at `<dir>/bin/<name>` — a symlink,
  `globaltest/bin/cowsay -> ../lib/node_modules/cowsay/cli.js`.
- The package itself lands at `<dir>/lib/node_modules/<pkg>` on
  Linux/macOS; on Windows there's no `lib` split — Folders docs: "Global
  installs on Unix systems go to `{prefix}/lib/node_modules`. Global
  installs on Windows go to `{prefix}/node_modules`."
- No `package.json` was required beforehand and none was created by npm in
  the prefix root for the `-g` case.
- Official docs don't explicitly document the `-g` + `--prefix` combined
  interaction as a unit (each flag is documented separately) — a
  documentation gap, not a contradiction; no failure was reproduced
  empirically on npm 11.12.1.

**Non-global alternative** — `npm install --prefix <dir> <pkg>@<version>`
(no `-g`): verified empirically, arguably **more predictable**:
- Binaries land at `<dir>/node_modules/.bin/<name>`.
- Auto-creates `<dir>/package.json` and `<dir>/package-lock.json` as a side
  effect (global mode creates neither) — an artifact worth cleaning up or
  suppressing (`--no-package-lock`/`--no-save`) unless the install
  directory is exclusively owned per tool@version anyway (matching this
  repo's existing per-version immutable-directory pattern).
- Recommendation: the non-global form gives a uniform bin path independent
  of OS lib/no-lib quirks, at the cost of the extra manifest artifacts —
  acceptable given the directory is already single-purpose.

Pinned-version syntax `<pkg>@<version>` is explicitly documented.

### 2.2 Private-registry env vars

Naming rule, verified: any env var starting with `npm_config_` becomes a
config parameter, dashes → underscores.
([npm config](https://docs.npmjs.com/cli/v11/using-npm/config))

- `npm_config_registry=<url>` — verified empirically via
  `npm config get registry`. Default `https://registry.npmjs.org/`.

**Scoped registry via env var — works, but with a shell-identifier
caveat, verified empirically, undocumented in official docs.** Setting
`npm_config_@myscope:registry=<url>` in the *process environment* (not via
bash `export`, since `@` and `:` are illegal characters in a POSIX shell
variable name) correctly binds the scope, confirmed via `npm config get
@myscope:registry`. **This directly constrains mise-vault's
implementation**: it only works if the plugin's subprocess launch passes a
raw env array (argv+env, no shell string) rather than shelling through
`export`/a shell string — worth verifying against mise's Lua `cmd` module
semantics before relying on it.

**Auth token env var** — same shell-identifier caveat, verified working:
`npm_config_//<registry-host>/:_authToken=<token>`, confirmed masked
correctly in `npm config list -l` output.

**Net effect for unscoped packages**: `npm_config_registry` alone, a
plain, shell-safe env var, fully redirects unscoped package resolution —
sufficient if mise-vault's npm catalog entries are unscoped.

### 2.3 Blocking public fallback

With `registry` set to a private URL, ordinary installs don't contact
`registry.npmjs.org` — standard single-registry resolution, no documented
per-scope fallback. `npm audit` submits "alongside the current npm command
to the default registry and all registries configured for scopes" — i.e.
it follows the configured registry, not a hardcoded npmjs.org endpoint,
though behavior if Nexus's npm proxy lacks the bulk-audit endpoint wasn't
tested live. `replace-registry-host` (default `"npmjs"`) actively
*rewrites* npmjs.org dist URLs found in an existing lockfile toward the
configured registry — protective, not a risk; leave at default.
**Gap**: docs don't exhaustively enumerate every network call npm might
make (provenance/signature endpoints, etc.) — a live isolated-network test
(this repo's own `offline-test` pattern) remains the authoritative check.

### 2.4 Side-channel fetches to disable

All three verified empirically settable via env var:

| Config | Env var | Purpose |
|---|---|---|
| `update-notifier` | `npm_config_update_notifier=false` | suppresses the update-nag network check |
| `fund` | `npm_config_fund=false` | suppresses funding message |
| `audit` | `npm_config_audit=false` | disables the automatic post-install audit submission |

No dedicated telemetry/analytics config key exists elsewhere in npm's
config surface (checked empirically via `npm config list -l`) — treat
update-notifier/fund/audit as the complete known side-channel surface.
Recommendation: set all three to `false` unconditionally.

### 2.5 Integrity pinning

**Confirmed: no ad-hoc pin flag exists.** Full `npm install --help` flag
listing contains no `--integrity` or equivalent. The `integrity` field
lives only in `package-lock.json`, populated from the registry's own
`dist.integrity`/`dist.shasum` — registry-trust-based, not user-pinnable
at install time.

**Material design implication**: unlike mise-vault's existing
catalog-checksum pattern (fetch + `sha256sum` against `versions.json`),
npm-based installs cannot get an equivalent at npm's own install boundary.
To enforce the catalog-checksum invariant for npm packages, mise-vault
would need to independently resolve the exact tarball URL from Nexus's
packument and verify it out-of-band (`curl -fsSL -n` + `sha256sum`),
mirroring the pattern already used elsewhere in this repo, rather than
trusting `npm install`'s own SRI machinery.

### 2.6 Auth: no netrc support

`.npmrc`'s auth keys (`_auth`, `_authToken`, `username`, `_password`,
`email`, `cafile`, `certfile`, `keyfile`) are all scoped per-registry via
`//host/path:` prefix syntax. **`.netrc` is never mentioned anywhere** in
the npmrc/config/registry docs pages — npm has its own separate
auth-token mechanism, entirely independent of the netrc convention this
repo relies on for git and `curl -n`.

**Direct implication**: mise-vault's existing bootstrap pattern (netrc via
git/curl) does not carry over to npm. Authenticating against the Nexus npm
proxy requires either translating the plugin's existing Nexus credential
into `npm_config_//<nexus-host>/<repo-path>/:_authToken=<token>` (env var,
confirmed working), or relying on anonymous read access if the npm proxy
repo permits it. **Gap**: whether Nexus's npm proxy supports HTTP Basic as
an alternative to bearer `_authToken` wasn't verified live.

### 2.7 Nexus repository format

Confirmed: "Nexus Repository supports the npm registry format for proxy
repositories."
([npm registry](https://help.sonatype.com/en/npm-registry.html)) Caveat:
"Once you create an npm proxy repository, do not change the remote server
URL. Doing so may result in 404s… Instead, create a new proxy repository."
npm format is available in the current free **Community Edition** per the
[feature matrix](https://help.sonatype.com/en/nexus-repository-feature-matrix.html).
This repo's `experiment/docker-compose.yml` already pins the current
`sonatype/nexus3` CE image, so npm proxy support should already be
available in the local dev stack — not yet confirmed by actually
provisioning it.

### 2.8 Runtime dependency

npm requires a working Node.js runtime already present (`node` on `PATH`)
— confirmed, co-installed with npm via nvm locally. Same category of
runtime-dependency problem as go.

### 2.9 Version listing via plain HTTP

```
GET https://registry.example.com/<package-name>
```
Returns a **packument**: `dist-tags` (mapping of tags like `latest` to
versions) and `versions` (mapping of every published version string to its
install metadata).
([npm/registry package-metadata](https://github.com/npm/registry/blob/main/docs/responses/package-metadata.md))
An **abbreviated** response (smaller, install-optimized) is available via
`Accept: application/vnd.npm.install-v1+json` — the better fit for
mise-vault's `BackendListVersions` hook, fetchable with plain HTTP/curl
against the Nexus npm-proxy endpoint, no npm CLI needed for listing.

---

## 3. bun

**Not installed locally — docs-only, no empirical verification.** All
citations `bun.sh/docs/...`.

### 3.1 Pinned install / custom global dir — the crux issue

```
bun add -g <pkg>@<version>
```
(aliases: `bun install -g`/`--global`). Global installs never touch the
current project's `package.json`/lockfile.
([pm/cli/add](https://bun.sh/docs/pm/cli/add))

Custom install location **is** controllable, via two bunfig.toml keys each
with a documented 1:1 env var:
- `install.globalDir` ↔ `BUN_INSTALL_GLOBAL_DIR` (default
  `~/.bun/install/global`)
- `install.globalBinDir` ↔ `BUN_INSTALL_BIN` (default `~/.bun/bin`)

([bunfig](https://bun.sh/docs/runtime/bunfig), verbatim: "Environment
variable: `BUN_INSTALL_GLOBAL_DIR`" / "`BUN_INSTALL_BIN`")

`BUN_INSTALL` itself only sets the base directory bun's own
binary/installer uses (`$BUN_INSTALL/bin/bun`) — docs never state that
global-package or bin-dir defaults are *derived* from it at runtime.
([installation](https://bun.sh/docs/installation))
`BUN_INSTALL_CACHE_DIR` separately controls the shared download cache.
([pm/global-cache](https://bun.sh/docs/pm/global-cache))

**Conclusion**: setting `BUN_INSTALL_GLOBAL_DIR` + `BUN_INSTALL_BIN`
together, with no bunfig.toml, fully redirects both package files and the
bin symlink — the env-var-only path exists and should work.

**Gap flagged**: docs never state whether these three env vars derive from
`BUN_INSTALL` by default or are independently hardcoded — set all three
explicitly, don't rely on `BUN_INSTALL` alone. Unverified empirically
(bun unavailable locally).

### 3.2 Private-registry env vars & precedence

Bun honors **both** its own `BUN_CONFIG_REGISTRY` and the npm-style
`NPM_CONFIG_REGISTRY` — verbatim: "`BUN_CONFIG_REGISTRY` /
`NPM_CONFIG_REGISTRY` and `BUN_CONFIG_TOKEN` / `NPM_CONFIG_TOKEN`
environment variables."
([pm/npmrc](https://bun.sh/docs/pm/npmrc))

**Casing matters**: bun's docs write it uppercase `NPM_CONFIG_REGISTRY` —
not npm's own lowercase `npm_config_registry` convention. Env vars are
case-sensitive; docs give no statement about case-insensitive lookup, so
treat only the exact uppercase form as confirmed.

**Precedence, confirmed verbatim** ("Configuration is loaded in this
order, with later sources overriding earlier ones"):
1. `~/.npmrc` (or `$XDG_CONFIG_HOME/.npmrc`)
2. `./.npmrc`
3. `bunfig.toml` (global, then project)
4. `BUN_CONFIG_REGISTRY`/`NPM_CONFIG_REGISTRY` + token env vars
5. CLI flag `--registry`

**Env vars win over bunfig.toml** — stated independently on the install
page too: "Environment variables take priority over `bunfig.toml`."
([pm/cli/install](https://bun.sh/docs/pm/cli/install))

Scoped registries (`@myscope:registry`): **no env-var override
documented** — only `.npmrc` and bunfig.toml `[install.scopes]` are shown.

### 3.3 Blocking public fallback

**Documentation silence, flagged explicitly.** Docs never state a fallback
to the public npm registry exists, nor that it doesn't — architecturally
they only ever describe a single resolved registry per scope, no
"fallback list" concept documented anywhere checked (`pm/npmrc`,
`pm/scopes-registries`, `pm/cli/install`). Treat as inferred-safe by
architecture, not as a stated guarantee.

### 3.4 Side-channel fetches / telemetry

`DO_NOT_TRACK=1` disables crash-report uploads: "Disable uploading crash
reports to `bun.report` on crash… Bun sends no other telemetry."
([runtime/environment-variables](https://bun.sh/docs/runtime/environment-variables))
`bun upgrade` is user-invoked only — no documented background/automatic
update check.

**No `--offline` flag exists.** The auto-generated CLI flags reference
lists no `--offline`; open GitHub issues (oven-sh/bun #5062, #7956,
#20460) are feature requests confirming it isn't implemented.

**Auto-install is a real fail-open risk to flag**: "Bun auto-installs
every imported package on the fly into a global module cache during
execution… you don't need to run `npm install` or `bun install` before
running a file."
([runtime/auto-install](https://bun.sh/docs/runtime/auto-install)) This
only matters if mise-vault's wrapper ever shells to `bun run`/`bunx`
rather than the scripted `bun add -g` install path — worth avoiding
entirely if the implementation touches `bun run` anywhere.

### 3.5 Integrity pinning

`--no-verify` — "Skip verifying integrity of newly downloaded packages" —
the phrasing ("newly downloaded," not "lockfile entries") implies
verification runs by default on every download, including ad-hoc global
installs with no lockfile, not just `bun install`. Docs don't specify the
hash algorithm/source (presumably the npm packument's
`dist.integrity`/`dist.shasum`, matching npm's format — inferred, not
stated). `bun.lock` stores per-package "integrity hashes"; the isolated
global-store `entry_hash` folds in "tarball integrity"
([pm/global-store](https://bun.sh/docs/pm/global-store)). **No documented
CLI flag to pin/assert a specific expected hash** on an ad-hoc
single-package install — only the default verify-vs-skip toggle.

### 3.6 Auth

`.npmrc` auth keys (`_authToken`, `username`, `_password`, `_auth`,
`email`) supported, with `//<registry_url>/:<key>=<value>` matching and
`${VAR}` substitution inside `.npmrc` values. bunfig.toml
`[install.scopes]` also directly supports `token`/`username`/`password`.

**`.netrc` is never mentioned anywhere** in bun's registry/install/auth
docs — a firm negative finding checked across `pm/npmrc`,
`pm/scopes-registries`, `pm/cli/install`, `runtime/bunfig`,
`runtime/environment-variables`. Bun's documented auth chain is
`.npmrc` → `bunfig.toml` → `BUN_CONFIG_TOKEN`/`NPM_CONFIG_TOKEN` env vars →
CLI flags, with no netrc step. `BUN_CONFIG_TOKEN`/`NPM_CONFIG_TOKEN` only
apply to "the default registry" per docs wording — scoped-registry auth
needs `.npmrc`/bunfig, not an env var.

**Same conclusion as npm**: this breaks mise-vault's netrc-everywhere
model; the credential must be translated into `NPM_CONFIG_TOKEN` /
`BUN_CONFIG_TOKEN` at install time.

### 3.7 Runtime dependency / distribution

Confirmed: "Bun ships as a single, dependency-free executable."
([installation](https://bun.sh/docs/installation)) This makes bun itself
a candidate for direct distribution as a prebuilt binary artifact via
Nexus, through mise-vault's *existing* per-platform artifact-template
mechanism — independent of whether bun is later used to install other npm
packages.

### 3.8 Version listing via plain HTTP

Bun uses the standard npm registry HTTP protocol, not a divergent one —
inferred from its documented handling of "npm registry responses" caching
and `Cache-Control`/`Age` header semantics on registry metadata fetches,
consistently described as talking to an npm-API-compatible registry. Same
packument shape as §2.9 applies.

### 3.9 Summary of bun-specific gaps (all unresolved against empirical testing — bun unavailable locally)

1. Whether the three `BUN_INSTALL_*` dir env vars derive from `BUN_INSTALL`
   or are independently hardcoded.
2. Case sensitivity of `NPM_CONFIG_REGISTRY`/`NPM_CONFIG_TOKEN` — bun's
   docs use uppercase, npm's own convention is lowercase; untested whether
   bun accepts the lowercase form too.
3. Explicit "no fallback to registry.npmjs.org" guarantee — docs silent,
   architecturally inferred safe, never stated.
4. Exact integrity-hash algorithm/source for the default verify step — not
   documented precisely.
5. `.netrc` absence — confirmed by omission across every relevant doc
   page, treated as a firm finding despite being a negative one.

---

## 4. pip (Python)

Verified against pip 24.0 (Debian packaging) / python3.12.3, and pipx
1.4.3. Citations `pip.pypa.io/en/stable/...` and `pipx.pypa.io/latest/...`.

### 4.1 Pinned-version install into a chosen directory with a predictable executable

Tested against a real `console_scripts` package (`pycowsay==0.0.0.2`).

**`pip install --target <dir> pkg==<version>`**: docs describe only
library placement, no mention of scripts/`bin/` at all. **Verified
empirically**: `--target` *does* create `<dir>/bin/<script>` for a package
with a console_scripts entry point — contradicting the commonly repeated
claim that target mode drops entry-point scripts (that stale claim traces
to [pypa/pip#3934](https://github.com/pypa/pip/issues/3934), which is
actually about the *lack of a way to redirect* that scripts directory, not
about scripts being absent). But the generated script is **not runnable
as-is**: its shebang points at the interpreter that ran `pip install`, not
anything under `<dir>`, and that interpreter's default `sys.path` doesn't
include `<dir>` — fails `ModuleNotFoundError` until `PYTHONPATH=<dir>` is
set at invocation time (verified).

**`pip install --prefix <dir> pkg==<version>`**: docs explicitly warn
"the resulting installation may contain scripts and other resources which
reference the Python interpreter of pip, and not that of `--prefix`."
Verified empirically: creates `<dir>/local/bin/<script>` on this
Debian/Ubuntu system (the extra `local/` segment is a Debian-specific
`sysconfig` scheme quirk — vanilla upstream pip places `bin/`/`lib/`
directly under `<dir>`). Same `ModuleNotFoundError`-until-`PYTHONPATH`
problem as `--target`.

**Neither `--target` nor `--prefix` produces a self-contained,
immediately-executable binary.** For a mise backend this isn't fatal — mise
already has `BackendExecEnv` for exactly this shape of problem, the same
mechanism the go backend uses for `GOROOT`/`PATH` — a pip-based tool would
need `BackendExecEnv` to return both `PATH` and `PYTHONPATH`, an added
obligation go-style backends don't have (Go binaries are static).

**`pipx install pkg==<version>`** with `PIPX_HOME`/`PIPX_BIN_DIR`: pipx
has **no config file at all** — "Every setting is an environment variable,
all of them optional."
([pipx env vars](https://pipx.pypa.io/latest/reference/environment-variables.html))
- `PIPX_HOME` — root dir for pipx venvs, default `~/.local/share/pipx`;
  venvs land at `$PIPX_HOME/venvs/<pkg>`.
- `PIPX_BIN_DIR` — dir for entry-point symlinks, default `~/.local/bin`.

`pipx install --help` confirms "The PACKAGE_SPEC argument is passed
directly to `pip install`" — a plain `pkg==version` pin works with no
special pipx syntax. **Verified empirically**: installed
`pycowsay==0.0.0.2` with custom `PIPX_HOME`/`PIPX_BIN_DIR`, producing
`$PIPX_BIN_DIR/pycowsay -> $PIPX_HOME/venvs/pycowsay/bin/pycowsay`, whose
shebang is a self-relocating exec trampoline (`#!/bin/sh` +
`'exec' <venv>/bin/python "$0" "$@"`). Run in a **completely stripped
environment** (`env -i`, no `PYTHONPATH`, minimal `PATH`), it worked with
zero extra setup.

**Recommendation**: `pipx install` with `PIPX_HOME`/`PIPX_BIN_DIR` per
tool@version is the closest analogue to `go install` — one command, one
pinned artifact, one predictable location, runs standalone, no
`BackendExecEnv` plumbing beyond `PATH`. `--target`/`--prefix` are viable
but push `PYTHONPATH` correctness onto the plugin. Trade-off: pipx costs
more disk (a full venv per tool, including its own pip/setuptools stack)
versus `--target`'s flat package directory.

**Gap**: `--target`'s script generation is real but **undocumented and not
guaranteed** across pip versions — treat as version-fragile, unlike pipx's
documented, stable behavior; pin a specific pip version and add a
regression test if used.

### 4.2 Private-registry env vars

Naming rule: `PIP_<UPPER_LONG_NAME>`, dashes → underscores.
([configuration](https://pip.pypa.io/en/stable/topics/configuration/))

| Env var | CLI equivalent | Effect |
|---|---|---|
| `PIP_INDEX_URL` | `-i/--index-url` | **Replaces** the default index (default `https://pypi.org/simple`); must be PEP 503-compliant |
| `PIP_EXTRA_INDEX_URL` | `--extra-index-url` | **Adds to**, does not replace |
| `PIP_NO_INDEX` | `--no-index` | Disables index lookup entirely (only `--find-links`) |

**Verified empirically** (inside a venv to bypass the Debian PEP 668
guard), all three work as plain env vars, no config file:
```
PIP_INDEX_URL="http://127.0.0.1:1/simple" pip install --dry-run -v pycowsay==0.0.0.2
→ "Looking in indexes: http://127.0.0.1:1/simple" — pypi.org never mentioned, 5 retries then fails

PIP_NO_INDEX=1 pip install --dry-run -v pycowsay==0.0.0.2
→ no network attempt logged at all

PIP_EXTRA_INDEX_URL="http://127.0.0.1:1/simple" pip install --dry-run -v pycowsay==0.0.0.2
→ "Looking in indexes: https://pypi.org/simple, http://127.0.0.1:1/simple"
```

**Load-bearing empirical result**: `PIP_EXTRA_INDEX_URL` set alone, with
no `PIP_INDEX_URL`, queries pypi.org *and* the extra URL, in that order —
for a fail-closed design, `PIP_EXTRA_INDEX_URL` must never be the sole
redirect mechanism; only `PIP_INDEX_URL` (or `PIP_NO_INDEX` +
`--find-links`) blocks pypi.org.

### 4.3 Blocking public fallback — watertightness

For ordinary index-based resolution: **yes, verified** — a single "Looking
in indexes" line with no pypi.org entry, and failure is local
connection-refused, never a fallback request.

Documented/inferred edge cases **not** covered by `PIP_INDEX_URL`:
- **VCS or direct-URL requirements** (`git+https://…`, a `.whl` URL, a
  local path) are fetched directly, never through the index at all — a
  transitive dependency declared this way bypasses index configuration
  entirely.
- **`--find-links`** URLs/paths are consulted in addition to whatever
  index config is active (unless `--no-index` suppresses the index).
- **Build-system dependencies** (sdist `pyproject.toml` build requires)
  are resolved via the same session/index config, so they inherit the
  `PIP_INDEX_URL` restriction — not an extra hole, but a separate fetch
  pass worth knowing about.

**Fail-closed implication for mise-vault**: since the catalog is already
the approval boundary, the plugin should reject or flag any approved
package whose declared dependencies include VCS/direct-URL specifiers —
the one class of dependency `PIP_INDEX_URL` cannot redirect. **Flagged as
docs-implicit, not docs-explicit** — no single pip.pypa.io page enumerates
this as a checklist; synthesized from separate option docs plus the
empirical build-dependency log line.

### 4.4 Side-channel fetches

`--disable-pip-version-check` (env: `PIP_DISABLE_PIP_VERSION_CHECK=1`):
"Don't periodically check PyPI to determine whether a new version of pip
is available for download. Implied with `--no-index`."
([pip general options](https://pip.pypa.io/en/stable/cli/pip/))

Reading pip's own source
([`self_outdated_check.py`](https://github.com/pypa/pip/blob/main/src/pip/_internal/self_outdated_check.py))
corrects a plausible-but-wrong assumption: the version check does **not**
hit a hardcoded `pypi.org` endpoint — it reuses the exact same
`PackageFinder`/`options.index_url` the invoking command resolved from its
own config/env/CLI. **Consequence**: if `PIP_INDEX_URL` points at Nexus,
the self-check (when not disabled) queries Nexus for pip's own versions
too — not a separate ungated leak to the public index, but still a
redundant Nexus roundtrip worth eliminating with
`PIP_DISABLE_PIP_VERSION_CHECK=1` regardless. **Inconclusive
empirically**: the check couldn't be observed firing live under
`--dry-run` in this environment (no log lines, no cache file written) —
the gating-logic finding is source-verified, not traffic-verified.

No other default telemetry found on the pages reviewed.

### 4.5 Hash-checking mode: ad-hoc vs. requirements-file-only

**Verified empirically: `--hash` is not a valid `pip install` CLI
option** — `pip install pycowsay==0.0.0.2 --hash=sha256:<hex>` fails with
`no such option: --hash`. Docs confirm: the "Hash-checking Mode" page
presents `--hash` exclusively as a per-requirement directive inside a
requirements file.
([secure installs](https://pip.pypa.io/en/stable/topics/secure-installs/))
Once any requirement carries a hash: all requirements in the operation
must have hashes, all dependencies (including transitive) must have
hashes, and every requirement must be pinned (`==`, URL, or path).
`--require-hashes` forces the mode as a safety net.

**Correct incantation, verified working end-to-end** — a one-line
temporary requirements file, no persisted project file:
```bash
printf '%s==%s --hash=sha256:%s\n' "$PKG" "$VERSION" "$SHA256" > /tmp/req.txt
pip install --no-cache-dir --target "$DIR" -r /tmp/req.txt
```
Tested both directions live: a wrong hash produces a hard failure
("THESE PACKAGES DO NOT MATCH THE HASHES…", no files written); the correct
hash installs normally. **Fully resolved**: pip's hash mode is real and
enforced, but requirements-file-only — any mise-vault code path wanting
hash verification on a pip install must materialize a throwaway
requirements file, not pass `--hash` on the command line.

### 4.6 Auth: `~/.netrc`

"Pip supports loading credentials from a user's `.netrc` file. If no
credentials are part of the URL, pip will attempt to get authentication
credentials for the URL's hostname from the user's `.netrc` file." Only
ASCII permitted in netrc values.
([authentication](https://pip.pypa.io/en/stable/topics/authentication/))
netrc supplies HTTP Basic auth — matches this project's existing Nexus
finding (HTTP Basic via `curl -n`), so pip-against-Nexus and
curl-against-Nexus share the identical auth mechanism and the identical
`~/.netrc` entry. (Token-only indexes can alternatively embed the token as
the URL "username" with no password — not netrc-mediated, relevant only if
Nexus's PyPI realm ever moves to token auth.) The `PIP_INDEX_URL` value
itself, like Nexus's base URL elsewhere in this project, must not embed
the credential.

### 4.7 Nexus repository format

Confirmed: Nexus supports a PyPI proxy repository type — "Centralize
access to public Python packages and cache remote artifacts from PyPI."
([PyPI repositories](https://help.sonatype.com/en/pypi-repositories.html))
Protocol support: PEP 503 (HTML Simple API); PEP 691 JSON Simple API "as
of version 3.93"; PEP 700/714 (additional JSON fields) added in 3.94.
Client support explicitly listed: pip, Poetry, uv, twine.

**Practical implication**: a Nexus PyPI *proxy* repo still, by its own
nature, reaches real pypi.org on Nexus's own egress to satisfy cache
misses — the "no fallback to public PyPI" guarantee mise-vault needs is
about *pip's* traffic never leaving the private network, not about
Nexus's own upstream fetches, which are a server-side policy decision
(no-upstream configuration, or admin allow-listing) orthogonal to the
client-side redirection above. Mirrors the existing project distinction:
"an artifact existing in Nexus does not make it installable — only a
version listed in `catalog/<tool>/versions.json` is approved."

### 4.8 Runtime dependency

Confirmed trivially: pip is itself a Python package (`pip --version`
output names its own bound interpreter — `pip 24.0 … (python 3.12)`). No
standalone/static pip binary exists — a compatible Python interpreter must
already be resolvable on the target machine before any pip-based
mise-vault tool install can run.

### 4.9 PyPI Simple Repository API (PEP 503 / PEP 691)

```
GET /simple/<package>/
```
returns all release files for that project, in one of two
content-negotiated formats:
- **HTML (PEP 503)**: one anchor element per file, anchor text matching
  the filename, URLs optionally carrying a hash fragment
  (`#<hashname>=<hashvalue>`).
- **JSON (PEP 691)**: `name`, `project-status`, `files`, `meta`,
  `versions` (a plain list of all uploaded version strings); each `files`
  entry carries `filename`, `url`, `hashes`, `requires-python`,
  `core-metadata`, `gpg-sig`, `yanked`, `size`, `upload-time`,
  `provenance`.

Content negotiation via `Accept: application/vnd.pypi.simple.v1+json` (or
`+html`; bare `text/html` accepted as a legacy alias).
([Simple Repository API](https://packaging.python.org/en/latest/specifications/simple-repository-api/))
This is exactly the API Nexus's PyPI proxy implements and the API pip's
resolver walks for every install — a plain
`curl -H 'Accept: application/vnd.pypi.simple.v1+json' <nexus>/repository/<pypi-proxy>/simple/<pkg>/`
is a lightweight, pip-independent version-enumeration mechanism for
mise-vault's `BackendListVersions` hook.

### 4.10 Summary of pip gaps

1. `--target`'s `bin/` generation is real but undocumented/version-fragile;
   `--prefix`'s extra `local/` segment is Debian-specific.
2. The self-version-check network call was source-verified, not
   traffic-verified live in this environment.
3. No single doc page enumerates every index-bypass case (VCS/URL
   requirements, `--find-links`) — synthesized from separate sections.
4. Hash-checking mode is fully resolved — both success and failure paths
   tested live.

---

## 5. uv (Astral)

Verified against uv 0.12.4 (PyPI's latest at research time was 0.12.5, one
patch behind, no relevant CLI-surface differences). Citations
`docs.astral.sh/uv/...`; empirical findings label
**[EMPIRICAL]** vs **[DOCS]**.

### 5.1 Pinned-version install command

```
uv tool install <package>==<version>
```
**[EMPIRICAL]**, confirmed via `uv tool install --help`.
- Creates an **isolated venv per tool** — **[DOCS]** "a virtual
  environment is created in the [uv tools directory]… will not be removed
  unless the tool is uninstalled."
  ([concepts/tools](https://docs.astral.sh/uv/concepts/tools/))
- Executables are symlinked (Unix) / copied (Windows) into a separate bin
  dir.
- No project/lockfile required; standalone command.

**`UV_TOOL_DIR`** — venv storage location. **[EMPIRICAL]** confirmed as a
real string embedded in the binary's help text
(`"$UV_TOOL_DIR"`). **[DOCS]** default: `tools/` under the persistent data
dir (e.g. `~/.local/share/uv/tools` on Linux/macOS).
([reference/storage](https://docs.astral.sh/uv/reference/storage/))
Verified live: `uv tool dir` → `/home/arlo/.local/share/uv/tools`.

**`UV_TOOL_BIN_DIR`** — executable location. **[EMPIRICAL + DOCS]**
default resolution: `$XDG_BIN_HOME` → `$XDG_DATA_HOME/../bin` →
`$HOME/.local/bin`. Both env vars are real and current for 0.12.4.

### 5.2 Private-registry env vars — crux, resolved with no ambiguity

**[EMPIRICAL]**, confirmed via `uv tool install --help`/`uv help pip
install`, cross-checked against **[DOCS]**
([reference/environment](https://docs.astral.sh/uv/reference/environment/)
— the older `configuration/environment/` URL now 301-redirects here):

| Var | Status | Role |
|---|---|---|
| `UV_INDEX_URL` | Deprecated | old single-index name ("use `--default-index` instead") |
| `UV_DEFAULT_INDEX` | **Current** | **REPLACES** PyPI as the sole default index |
| `UV_INDEX` | **Current** | **ADDITIVE** — space-separated list, supports `name=url` |
| `UV_EXTRA_INDEX_URL` | Deprecated | old additive equivalent |

**Answer to the crux question**: `UV_DEFAULT_INDEX` is the direct
analogue of pip's `PIP_INDEX_URL` — replaces PyPI outright. `UV_INDEX` is
the analogue of `PIP_EXTRA_INDEX_URL` — additive, does **not** by itself
remove PyPI as a fallback (PyPI remains uv's built-in default index unless
`UV_DEFAULT_INDEX` also overrides it — see 5.3).

**[DOCS gap]**: no explicit "deprecated since version X.Y.Z" note found on
the environment reference page for `UV_INDEX_URL`/`UV_EXTRA_INDEX_URL`;
confirmed current and stable at 0.12.4 but undated in the fetched docs.

Per-index credential vars also confirmed:
`UV_INDEX_<NAME>_USERNAME`/`UV_INDEX_<NAME>_PASSWORD`, `<NAME>` being the
uppercased index name with non-alphanumerics turned to underscores.
([concepts/indexes#credentials](https://docs.astral.sh/uv/concepts/indexes/#providing-credentials-directly))

**Conclusion**: set `UV_DEFAULT_INDEX=<nexus-pypi-proxy-url>/simple`, never
set `UV_INDEX`/`UV_EXTRA_INDEX_URL`/`UV_INDEX_URL` pointing anywhere. Do
not rely on `UV_INDEX` alone.

### 5.3 Blocking public fallback

**[EMPIRICAL + DOCS]** `--index-strategy`/`UV_INDEX_STRATEGY`, default
`first-index`: "Only use results from the first index that returns a
match for a given package name." `unsafe-first-match` and
`unsafe-best-match` search every configured index; the latter is the
dangerous one for supply-chain safety since it can pull a version from
whichever index has it.

**The critical interaction**: regardless of index-strategy, PyPI is uv's
built-in default index unless explicitly overridden — **[DOCS]**: "By
default, uv includes the Python Package Index (PyPI) as the 'default'
index, i.e., the index used when a package is not found on any other
index."
([concepts/indexes](https://docs.astral.sh/uv/concepts/indexes/)) This
means even with `UV_INDEX` set to Nexus and `first-index` strategy, if a
package isn't found on Nexus, uv **will fall through to pypi.org** as the
default index unless `UV_DEFAULT_INDEX` has replaced it.

`--no-index`/`UV_NO_INDEX`: **[EMPIRICAL]** — `--no-index` exists as a
flag but has **no corresponding `[env: …]` annotation** in `--help`
output, confirmed by direct inspection; it also breaks normal name-based
`uv tool install`, so it's not the mechanism to use here.

`UV_OFFLINE` — **[EMPIRICAL + DOCS]**: blocks pypi.org absolutely, but
also blocks first-time installs against Nexus unless already cached —
a hard-offline mode, not a standing fail-closed-to-Nexus-only mechanism.

**Guaranteed combination**: `UV_DEFAULT_INDEX=<nexus-simple-url>`; never
set `UV_INDEX`/`UV_EXTRA_INDEX_URL`/`UV_INDEX_URL`; leave
`UV_INDEX_STRATEGY` at its default `first-index` explicitly. As with the
rest of this project, network-level egress control remains the only hard
guarantee — uv's own docs don't claim `UV_DEFAULT_INDEX` is a
cryptographic proof against contacting pypi.org.

### 5.4 Toolchain self-update / side-channel fetches

**[EMPIRICAL]** `uv self update` is a distinct, explicitly-invoked
subcommand, never wired into any other command — nothing in
`uv tool install --help` references it. **No `UV_NO_SELF_UPDATE`
environment variable exists** — confirmed by an exhaustive `strings` scan
of the installed binary for every `UV_*` token it recognizes. Self-update
fetches releases from GitHub (`github.com/astral-sh/uv/releases/download/`
found in binary strings, plus `UV_INSTALLER_GITHUB_BASE_URL`/
`UV_INSTALLER_GHE_BASE_URL` overrides). Since it's a separate opt-in
subcommand, `uv tool install` never triggers it — mise-vault simply must
never invoke `uv self update`.

**`UV_PYTHON_DOWNLOADS`** — **[DOCS,
reference/settings](https://docs.astral.sh/uv/reference/settings/)**,
default `"automatic"`: `"automatic"` (auto-download managed Python when
needed), `"manual"` (only via explicit `uv python install`), `"never"`
("Do not ever allow Python downloads"). **[EMPIRICAL]** also directly
confirmed by `uv tool install --help`: `--no-python-downloads` literally
shows `[env: "UV_PYTHON_DOWNLOADS=never"]` in its help text. This is the
direct analogue of `GOTOOLCHAIN=local`: **`UV_PYTHON_DOWNLOADS=never` is
necessary and sufficient** to stop uv from fetching a python-build-standalone
interpreter from GitHub when no compatible Python is locally available —
it fails closed instead. When allowed, Python downloads come from
python-build-standalone releases on GitHub, redirectable via
`UV_PYTHON_INSTALL_MIRROR` (confirmed present in binary strings) — meaning
mise-vault could redirect Python interpreter downloads to Nexus too,
mirroring the `UV_DEFAULT_INDEX` pattern.

**Telemetry — [GAP, not conclusively resolved]**: no docs.astral.sh page
fetched (FAQ candidates 404'd) explicitly states uv has no telemetry.
However, an exhaustive binary-strings scan of ~150 distinct `UV_*` tokens
contains no telemetry/analytics/tracking variable. Empirical negative
evidence, not a documented guarantee — recommend a network-capture check
inside the `experiment/` isolated stack if this matters for the
fail-closed claim.

### 5.5 Integrity pinning

**[EMPIRICAL]** — load-bearing finding: `uv pip install --help` exposes
`--require-hashes` (`[env: UV_REQUIRE_HASHES=]`) and
`--no-verify-hashes`. **`uv tool install --help` exposes none of this** —
grepped the full help text for "hash", zero matches.

**[DOCS]**: hash-checking mode requires that "all requirements must
include a hash or set of hashes, and all requirements must either be
pinned to exact versions… or specified via direct URL," disallowing Git
deps, editable installs, non-wheel local paths.

**Conclusion**: `--require-hashes` is enforceable only in
`uv pip install -r requirements.txt --require-hashes` (or `uv pip sync`)
mode — **not available at all on the ad-hoc `uv tool install
<pkg>==<version>` command surface**. This is a genuine capability gap,
not a doc oversight. If mise-vault needs integrity pinning on tool
installs, the achievable options are: (a) verify the Nexus-served
wheel/sdist checksum out-of-band before/after `uv tool install`, mirroring
the existing artifact-verification pattern elsewhere in this repo, or (b)
construct a throwaway requirements file and drive
`uv pip install --require-hashes -r <file> --python <tool-venv>` manually
instead of `uv tool install`, sacrificing the tool-isolation convenience.

### 5.6 Auth

**[DOCS]**
([concepts/authentication/http](https://docs.astral.sh/uv/concepts/authentication/http/)):
"reading credentials from `.netrc` files is always enabled" — no flag or
env var required. Target file resolved from `NETRC` env var if set, else
`~/.netrc`, same resolution git uses. Auth precedence: URL-embedded
credentials → netrc → uv's own credentials store → keyring providers
(only if explicitly enabled, off by default). No documented requirement
for `UV_NATIVE_TLS`/`--system-certs` to make netrc work — those are an
orthogonal TLS-source concern (`UV_NATIVE_TLS` is itself deprecated in
favor of `UV_SYSTEM_CERTS`). **Gap**: whether netrc works over plain HTTP
vs. requiring HTTPS wasn't explicitly stated in the fetched content —
unlikely to matter since Nexus should run HTTPS regardless.

Net effect: netrc "just works" for uv exactly as it does for git/curl,
matching this project's existing all-netrc auth pattern — no translation
step needed, unlike npm/bun/cargo.

### 5.7 Nexus PyPI-proxy compatibility

**[DOCS]**: uv's index client "implements PEP 503 (Simple Repository API)
and PEP 691 (JSON-based Simple API)" — the same protocol pip uses, so
Nexus's existing PyPI proxy (§4.7) is compatible with uv without any
Nexus-side changes.

### 5.8 uv's own distribution vs. the target tool's Python requirement

**[DOCS]**: uv ships as a **standalone installer**, a single binary — no
separate Python runtime needed to *run* uv itself (distinct from the
optional `pip install uv` convenience path, which needs Python only for
that particular installation method).
([getting-started/installation](https://docs.astral.sh/uv/getting-started/installation/))
This puts uv in the same "single static binary" category as bun — a
legitimate candidate for direct binary artifact distribution via Nexus,
independent of its package-installing function.

Distinguishing the two Python dependencies: **uv the binary** needs no
Python to run. **The installed CLI tool** still needs a Python interpreter
present in its isolated tool venv to execute — **[DOCS]**: "If the Python
version used by a tool is uninstalled, the tool environment will be broken
and the tool may be unusable," implying every tool venv is bound to a
concrete interpreter, either discovered locally or downloaded by uv
(subject to `UV_PYTHON_DOWNLOADS`, §5.4). With
`UV_PYTHON_DOWNLOADS=never` set, `uv tool install` on a machine with no
Python fails closed rather than silently fetching from GitHub — exactly
the desired behavior, but it means mise-vault must ensure some Python is
available (pre-provisioned separately, or route downloads through
`UV_PYTHON_INSTALL_MIRROR` pointed at Nexus).

### 5.9 Version listing via plain HTTP

**[DOCS + corroboration]** confirmed identical to §4.9/§4.7 — same PEP
503/691 Simple Repository API, same `GET /simple/<package>/` mechanism,
usable directly against Nexus for `BackendListVersions`.

### 5.10 Summary of uv gaps

1. No dated deprecation note for `UV_INDEX_URL`/`UV_EXTRA_INDEX_URL`.
2. Non-HTTPS/insecure-host interaction with netrc unconfirmed (likely
   moot).
3. No telemetry statement found in docs; absence in an exhaustive binary
   strings scan is suggestive, not documented.
4. `--require-hashes` confirmed absent from `uv tool install`'s flag
   surface — a genuine capability gap versus `uv pip install`.

---

## 6. Comparison table

| Feature | cargo | npm | bun | pip | uv |
|---|---|---|---|---|---|
| **Pinned single-tool install cmd** | `cargo install <crate> --version <v> --root <dir> --locked` | `npm install -g --prefix <dir> <pkg>@<v>` (or non-global `--prefix`, more predictable bin path) | `bun add -g <pkg>@<v>` + `BUN_INSTALL_GLOBAL_DIR`/`BUN_INSTALL_BIN` | `pipx install pkg==<v>` + `PIPX_HOME`/`PIPX_BIN_DIR` (recommended over `--target`/`--prefix`) | `uv tool install <pkg>==<v>` + `UV_TOOL_DIR`/`UV_TOOL_BIN_DIR` |
| **Produces standalone-runnable binary, no ambient state** | Yes (compiled native binary) | Yes (bin symlink into installed package) | Yes (docs-only, unverified) | **No** — `--target`/`--prefix` need `PYTHONPATH` at runtime; pipx's venv trampoline is standalone | Yes (isolated venv + relocating shim) |
| **Full registry redirect via env vars alone, no config file** | Yes — `CARGO_REGISTRIES_<N>_INDEX` + `CARGO_REGISTRY_DEFAULT` (verified live); `[source]` replacement has **no** env form at all | Yes — `npm_config_registry` (unscoped); scoped needs non-shell env injection (undocumented but verified) | Yes — `BUN_CONFIG_REGISTRY`/`NPM_CONFIG_REGISTRY`, confirmed to outrank bunfig.toml | Yes — `PIP_INDEX_URL` (verified live) | Yes — `UV_DEFAULT_INDEX` (current name; `UV_INDEX_URL` deprecated) |
| **A single env var fully replaces the public index (fail-closed by itself)** | Yes, `CARGO_REGISTRY_DEFAULT`/named registry (no crates.io fallback, verified) | Yes, `npm_config_registry` | Unconfirmed (docs silent on fallback existence either way) | Yes, `PIP_INDEX_URL` (verified); `PIP_EXTRA_INDEX_URL` alone is **not** safe (verified to add pypi.org) | Yes, `UV_DEFAULT_INDEX`; `UV_INDEX` alone is **not** safe (PyPI remains the fallback default index) |
| **Toolchain/self-update side channel to disable** | `RUSTUP_AUTO_INSTALL=0` (rustup fetches missing toolchains from `static.rust-lang.org` otherwise) | Update-notifier/fund/audit — all `npm_config_*=false` | No `--offline` flag exists; auto-install-on-run is a real fail-open risk if `bun run` is ever used | `PIP_DISABLE_PIP_VERSION_CHECK=1` (queries whichever index is configured, not hardcoded pypi.org — source-verified) | `UV_PYTHON_DOWNLOADS=never` (blocks GitHub interpreter fetch); no self-update side channel (separate opt-in subcommand) |
| **Ad-hoc per-install hash pin (analogue of go's h1)** | **No** — checksum is index-carried and automatic only, same trust boundary as the artifact itself | **No** — no `--integrity` flag; SRI only in lockfiles | **No** — only a verify-on/off toggle (`--no-verify`), no expected-hash pin | **No** as a flag, but a one-line throwaway requirements file with `--hash=sha256:…` works and was verified end to end | **No** on `uv tool install`; `--require-hashes` only exists on `uv pip install -r ...` |
| **Reads `~/.netrc`** | **No** (no built-in support; third-party provider binary only) | **No** (own `_authToken` mechanism only) | **No** (own `.npmrc`/bunfig token chain only) | **Yes**, verified/documented, Basic auth | **Yes**, documented, "always enabled," same resolution as git |
| **Nexus repo format available** | Cargo/Rust format, CE since 3.77.0, sparse-protocol only | npm proxy format, available in CE | (same npm proxy format pip/npm use) | PyPI proxy format, CE, PEP 503/691 since 3.93+ | (same PyPI proxy format pip uses) |
| **Runtime prerequisite already on the box** | Full Rust toolchain (cargo + rustc) — compiles from source | Node.js | None documented — bun is a standalone binary (unverified locally) | A Python interpreter | None to run uv itself (standalone binary); the *installed tool* still needs a Python present or auto-provisioned |
| **Candidate for direct prebuilt-binary distribution via Nexus, like go** | No (it *is* the compiler, not distributable as a single artifact in this role) | No (needs Node.js) | **Yes** — single dependency-free executable | No (needs Python) | **Yes** — single standalone executable |
| **Version listing via plain HTTP** | Sparse index, `GET /<prefix>/<name>`, newline-delimited JSON | Packument, `GET /<pkg>`, `versions`/`dist-tags` JSON (abbreviated form via `Accept` header) | Same as npm (npm-API-compatible) | PEP 503/691 Simple API, `GET /simple/<pkg>/`, HTML or JSON via content negotiation | Same as pip (PEP 503/691) |

---

## 7. Hard problems

### 7.1 cargo: env-var-only registry redirection works, but not via the mechanism the go-install analogy suggests

The natural first guess — "there must be an env var equivalent of
`[source.crates-io] replace-with = ...`" — is **wrong and confirmed
wrong**: every key under `[source.*]` is documented `Environment: not
supported`, with no exception. The mechanism that actually works
(`CARGO_REGISTRIES_<NAME>_INDEX` + `CARGO_REGISTRY_DEFAULT`) is a
different cargo subsystem (the multi-registry feature, not source
replacement) that happens to be exposed to `cargo install` specifically
via its own `registry.default` fallback logic, verified by direct
inspection of the `cargo install` reference page and confirmed live. This
is not the general-purpose "env vars mirror every TOML key" story that
holds for most of cargo's config surface — it's a narrower, install-command-specific
guarantee, and the report above deliberately does not generalize it to
other cargo subcommands mise-vault isn't using.

### 7.2 bun: global-install-dir controllability rests entirely on unverified documentation

Bun was not installed locally, so every claim in §3 — including the crux
finding that `BUN_INSTALL_GLOBAL_DIR` + `BUN_INSTALL_BIN` together fully
redirect a global install with no bunfig.toml — comes from docs text
alone, with no empirical confirmation that these variables actually take
effect as described, that they compose correctly, or that no additional
undocumented interaction (e.g. `BUN_INSTALL` itself silently changing
derived defaults) breaks the combination. Before mise-vault commits to
this pattern, bun needs to be installed and the exact combination tested
live, mirroring the empirical rigor applied to cargo/npm/pip/uv in this
report.

### 7.3 npm/bun scoped-registry env vars require bypassing the shell

Both npm's `npm_config_@scope:registry` and its `_authToken` counterpart
were verified to work only when injected into the process environment
directly (e.g. via a Lua/Go/Python subprocess `env` array), because `@`
and `:` are illegal characters in a POSIX shell variable name — bash
`export` cannot set them. If mise-vault's Lua `cmd` module shells through
a string rather than passing an argv+env array, these forms are simply
unusable, and unscoped-only npm packages would be the only ones
supportable without a config-file fallback. This needs to be checked
against mise's actual Lua `cmd` semantics before scoped npm/bun packages
are promised in the catalog design.

### 7.4 cargo/npm/bun have no netrc; only pip/uv do

Half of these five tools don't support `~/.netrc` at all, breaking this
project's netrc-everywhere auth model for three of five backends
(cargo, npm, bun) while extending it cleanly for two (pip, uv). Each of
the three needs its own env-var-based token translation step
(`CARGO_REGISTRIES_<NAME>_TOKEN` for cargo;
`npm_config_//<host>/:_authToken` for npm; `NPM_CONFIG_TOKEN`/
`BUN_CONFIG_TOKEN` for bun), sourced from wherever mise-vault's netrc
credential currently lives — a design decision, not just a config
tweak, since it means three different token-issuance/rotation stories
layered on top of the one netrc credential this project otherwise treats
as universal.

### 7.5 Ad-hoc integrity pinning (the "optional h1") has no equivalent in four of five ecosystems

Only pip supports pinning a hash on an install command at all, and even
then only via a throwaway requirements file, never a bare CLI flag. uv's
equivalent exists but only on a different command surface than the one
mise-vault would actually use (`uv pip install`, not `uv tool install`).
cargo, npm, and bun all verify integrity automatically but exclusively
against the same source that serves the artifact — structurally
identical to the "checksum next to the artifact it describes" anti-pattern
AGENTS.md already forbids for this project's own artifact store. If
per-version catalog-pinned integrity is treated as a hard requirement
(matching go's optional `h1`) rather than a nice-to-have, cargo/npm/bun
cannot satisfy it through their own install command at all, and even
pip/uv's answer requires bolting on an out-of-band verification step or a
non-default command path — this is a genuine, not-fully-closable gap
relative to the go pattern, and needs an explicit design decision (accept
network/TLS trust to Nexus as the substitute integrity boundary for these
three, or implement independent tarball/index verification outside each
tool's own install path).

### 7.6 pip's `--target`/`--prefix` don't produce a standalone binary — only pipx does

Unlike go/cargo/uv/bun (docs claim), a pip-installed console script
without pipx requires the invoking `PYTHONPATH` to be set correctly at
every future invocation, which is an ongoing `BackendExecEnv` obligation,
not a one-time install-time concern. This makes pip categorically
different from the others in this batch and argues for pipx, despite its
extra per-tool venv disk cost, as the only candidate that matches the
"one command, one pinned artifact, runs standalone" shape the go pattern
established.

### 7.7 cargo is the only one of the five that compiles from source on every install

go, uv, and bun deal in prebuilt binaries or interpreted packages; npm and
pip deal in packaged/interpreted code with no compilation step for most
CLI tools. cargo alone requires a working C toolchain/linker on the
target machine (for many crates' native dependencies) plus real CPU/disk
cost and materially longer install time — Nexus's role for cargo is
serving compilable source (`.crate` tarballs), not the same kind of
immutable prebuilt artifact this project's existing model assumes
everywhere else.
