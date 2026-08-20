# Ecosystem tool types: cargo, npm, pypi — design

Status: APPROVED 2026-08-20.
Phases A (npm + pypi) and B (cargo) are implemented;
see the implementation notes at the end of this document.
Phase C (the bun runner) remains future work.
Amended later the same day
after reviewing the real private-network registry configuration:
pipx became the default pypi runner,
and sections 4, 5, 8, 9 gained environment-derived detail.
A second round the same day
resolved every open question with the project owner (section 10);
the spec is implementation-ready.
Builds on the go-installed tool type
(landed on branch `feat/go-install-tools`, commit `10ee3b6`).
Supporting research: `docs/research/package-manager-registry-mechanics.md`
(note its preface — parts of it predate the decisions below).

## 1. Goal

Let the catalog approve CLI tools that are installed by their own
ecosystem's package manager —
Rust crates via `cargo install`,
npm packages via `npm` or `bun`,
PyPI packages via `uv` or `pipx` —
with the same catalog-is-the-boundary behavior every existing tool type has:
`mise ls-remote` lists only approved versions,
an unapproved version fails closed,
aliases stay pure routing (`<tool> = 'vault:<tool>'`),
and adding a tool means adding catalog data, never tool-specific code.

## 2. Binding decisions (made by the project owner)

1. **Toolchains are the user's responsibility.**
   cargo, node/npm, bun, uv, pipx are NOT distributed or version-gated by
   the vault.
   The user installs them and configures them so they already work in
   their environment.
   The plugin only requires the selected runner to exist on PATH and
   fails closed with a clear message when it does not.
   (Deliberately different from the go type, which keeps its
   approved-toolchain gate — decided when the two philosophies were
   compared side by side.)
2. **The network story is the environment's, not the plugin's.**
   These ecosystems fetch from external registries through whatever
   proxy/registry/auth configuration the user's environment already has.
   The plugin inherits that environment instead of overriding it.
   This is a scoped revision of the "no public internet after bootstrap"
   principle: for ecosystem tool types, egress policy is enforced by the
   network (forward proxy), not by the plugin.
   The go type keeps its plugin-controlled GOPROXY design unchanged.
3. **Runners are selected by environment variable, not by catalog.**
   `MISE_VAULT_NPM_RUNNER=npm|bun` (default `npm`)
   and `MISE_VAULT_PYPI_RUNNER=uv|pipx` (default `pipx`).
   pipx is the default:
   it installs through pip,
   so it inherits the user's existing `pip.conf`
   (index-url and trusted-host) with no further setup.
   uv deliberately reads none of pip's configuration
   and needs its own settings (see section 5);
   the real environment does carry a `uv.toml`,
   so uv is fully supported as an opt-in runner,
   but `pip.conf` is the environment's more established channel,
   and the project owner reconfirmed pipx as the default
   after the uv configuration surfaced.
   An unknown value, or a selected runner missing from PATH, aborts;
   there is never a silent fallback to the other runner.
   Until the bun runner ships (Phase C),
   `MISE_VAULT_NPM_RUNNER=bun` is recognized but rejected with its
   own message naming the limitation
   ("the bun runner is not yet supported"),
   distinct from the unknown-value error;
   Phase C then replaces that rejection with the real branch,
   leaving the accepted-value set unchanged.

## 3. Catalog shapes

Three new `tool.json` types, one branch each in the schema `oneOf`:

```json
{ "name": "tokei", "type": "cargo", "crate": "tokei" }
{ "name": "prettier", "type": "npm", "package": "prettier" }
{ "name": "ruff", "type": "pypi", "package": "ruff" }
```

(These are the confirmed first approved tools,
resolved with the project owner on 2026-08-20,
chosen deliberately:
tokei compiles quickly from few dependencies,
prettier has zero runtime dependencies,
and ruff installs as one dependency-free prebuilt wheel —
see the selection guideline in section 6.
None of them is a scoped npm package,
so the `@scope/name` grammar is covered by negative fixtures
until a real scoped tool is approved.)

Their initial approved versions are selected at implementation time.
The project owner names each tool's current stable version
(from the tool's release page or its registry)
and passes it to `scripts/add-version` explicitly —
the script validates the value and probes the registry for
existence;
it never chooses a version itself,
so no "latest" semantics need defining.
The result is recorded in `versions.json` through the normal
approval flow.
This spec deliberately names no version numbers —
`versions.json` is the record of approval, not this document.

The field grammars below are normative —
the JSON Schemas, `scripts/validate-catalog`, and the runtime Lua
checks implement exactly these patterns.
Every grammar is anchored against trailing newlines
(`\Z` in Python, `(?![\s\S])` in the JSON Schemas,
Lua patterns written to the same effect),
is enforced by both validation engines,
and is re-checked at runtime before the value reaches a shell
command, exactly like the go module grammar.
Their permitted character repertoires are deliberately narrower
than the registries allow (no uppercase, no unicode) —
widening one is a reviewed change, like the version grammars below —
while their structural checks are looser:
they are shell-safety envelopes, not full syntax validators,
so a value can match its envelope and still be invalid in its
ecosystem (a semver with a leading zero, for example).
That is fine by design —
`scripts/add-version` probes the registry for existence before
anything enters the catalog,
and the registry is the semantic authority on what is a real name
or version.

- `crate`: `^[a-z][a-z0-9_-]{0,63}\Z`
  (crates.io caps names at 64 characters and requires an alphabetic
  first character;
  historic uppercase crate names cannot be approved as-is).
- npm `package`: `^(@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*\Z`
  with a 214-character cap on the whole value (npm's own limit);
  the `/` in a scoped name is the only path separator allowed
  anywhere in the value.
- pypi `package`: `^[a-z0-9]+(-[a-z0-9]+)*\Z` —
  the PEP 503 normalized form.
  The catalog stores only normalized names;
  `scripts/add-version` refuses a non-normalized input and names the
  normalized form to use, instead of silently rewriting it.
- `bin`: `^[a-z0-9][a-z0-9._-]{0,63}\Z` (the field is defined below).
- All three types take the optional `bin` field:
  cargo and npm packages may install binaries whose names differ from
  the package name,
  and a PyPI project's console-script name may differ from its
  project name (the `httpie` project installs `http`),
  so `bin` names the executable the exec-env
  and post-install existence check look for.
  Resolved 2026-08-20: `bin` is a single optional string,
  defaulting to the tool name,
  validated against a shell-safe grammar
  (it becomes part of a filesystem path).
  It is an expectation, not an instruction:
  the ecosystem installer decides what binary names it writes,
  the plugin never renames anything,
  and `bin` only tells the plugin what to verify and expose.
  Example: a future `ripgrep` entry would carry `"bin": "rg"`,
  keeping the tool name aligned with the public mise registry
  so migrating developers type the same `mise use` name.
  Widening to a list later is a backward-compatible schema change,
  so nothing is reserved for it now.

`versions.json`: the same ordered array, entries carry a bare `version`
only — **no checksum field for these types** (see section 6).
Version grammars per ecosystem, all shell-safe and lowercase,
starting from the go version grammar and widening only where the
ecosystem requires it (e.g. PEP 440 local segments use `+`).
Concretely:

- cargo and npm `version`:
  `^[0-9]+\.[0-9]+\.[0-9]+(-[0-9a-z.-]+)?(\+[0-9a-z.-]+)?\Z`
  (a lowercase semver envelope —
  it does not re-implement semver's leading-zero and
  empty-identifier rules; the registry probe does the real check).
- pypi `version`:
  `^[0-9]+(\.[0-9]+)*((a|b|rc)[0-9]+)?(\.post[0-9]+)?(\.dev[0-9]+)?(\+[0-9a-z]+(\.[0-9a-z]+)*)?\Z`
  (an envelope for the common PEP 440 shapes;
  epochs and legacy version forms are deliberately not representable).
Lowercase-only is deliberate and narrower than the ecosystems allow:
npm and cargo prerelease segments may legally contain uppercase
(e.g. `1.0.0-RC.1`), and such versions cannot be approved as-is.
Approving a prerelease should be rare in this catalog;
if one is ever required,
widening the grammar is a small reviewed change
(schema, validator, and fixtures move together),
which is preferred over carrying a larger shell-facing alphabet
from day one.

## 4. Install semantics (hook branch per type)

All types install into `<install_path>` with binaries in
`<install_path>/bin`; `BackendExecEnv` adds that directory to PATH
(same branch the go type uses — generalize the existing
`tool.type == "go"` check to a set of source-built types).

These types support linux and darwin only.
npm on Windows places global executables directly in the prefix
rather than in `<prefix>/bin`,
none of the test suites exercise Windows,
and these types carry no per-platform catalog data that could encode
such differences —
so the hook checks the runtime OS first
and fails closed on anything else, naming the limitation.

- **cargo**:
  `cargo install <crate> --version <version> --locked --root <install_path>`
  (binaries land in `<root>/bin` natively).
  `--locked` uses the crate's committed lockfile for reproducibility;
  if a crate ships no lockfile, cargo errors and the failure message is
  surfaced (fail closed; document the flag so operators understand it).
  Pin `RUSTUP_AUTO_INSTALL=0`:
  a rustup-provided cargo would otherwise download a missing
  toolchain by itself,
  which is the user's job (decision 1)
  and may reach hosts outside the configured registry.
- **npm runner npm**:
  `npm install -g --prefix <install_path> <package>@<version>`;
  npm puts binaries in `<prefix>/bin` on Linux/macOS.
  Pin `NPM_CONFIG_UPDATE_NOTIFIER=false`, `NPM_CONFIG_FUND=false`,
  and `NPM_CONFIG_AUDIT=false`
  (pure noise suppression, not policy;
  audit endpoints are typically absent on private registry proxies,
  so the audit call is noise at best and an error at worst).
- **npm runner bun**:
  bun's global-install command (`bun add -g <package>@<version>` per its
  docs) with `BUN_INSTALL_GLOBAL_DIR=<install_path>` and
  `BUN_INSTALL_BIN=<install_path>/bin`.
  **Both the exact command form and the two directory variables are
  unverified research claims** (bun was not installed on the research
  machine) — the implementation must verify them empirically first,
  and if bun cannot be pinned to the target directories the bun runner
  ships as an explicit error naming that limitation
  (never a silent fall back to npm).
  Pin `DO_NOT_TRACK=1`.
- **pypi runner pipx** (default):
  `pipx install <package>==<version>` with
  `PIPX_HOME=<install_path>/pipx` and `PIPX_BIN_DIR=<install_path>/bin`,
  plus `PIPX_MAN_DIR=<install_path>/share/man` and
  `PIPX_COMPLETION_DIR=<install_path>/share`
  (their defaults point into the user's home directory,
  so a package shipping man pages or shell completions would
  otherwise leave files behind after mise removes the installation).
  Pin `PIPX_DEFAULT_BACKEND=pip`:
  pipx 1.12 and later auto-select a uv backend when uv is on PATH,
  which would route the install through uv's registry configuration
  instead of pip's —
  the pin keeps the documented `pip.conf` channel true
  regardless of what else is installed.
  Pin `PIPX_FETCH_PYTHON=never`:
  pipx can download a standalone Python interpreter when
  `PIPX_FETCH_PYTHON` (or the deprecated `PIPX_FETCH_MISSING_PYTHON`)
  arrives set in the inherited environment —
  the pin makes "never" unconditional,
  matching the other toolchain-download refusals.
  Pin `PIP_DISABLE_PIP_VERSION_CHECK=1`.
  With the backend pinned, pipx installs through pip,
  so it inherits the user's `pip.conf` (index-url, trusted-host)
  without further setup.
- **pypi runner uv** (opt-in):
  `uv tool install <package>==<version>` with
  `UV_TOOL_DIR=<install_path>/tools` and
  `UV_TOOL_BIN_DIR=<install_path>/bin`.
  uv is a managed-environment installer: the binary in bin is a
  launcher into `UV_TOOL_DIR`, so both directories must live under
  `install_path` for uninstall to stay clean.
  Pin `UV_PYTHON_DOWNLOADS=never`:
  uv would otherwise download a managed Python interpreter by
  itself, which is the user's job (decision 1)
  and may reach hosts outside the configured index.
  uv does NOT read pip configuration files:
  it needs its own configuration —
  `uv.toml` (`index-url`, or the newer `[[index]]` form)
  or the matching env vars
  (`UV_DEFAULT_INDEX`, `UV_INSECURE_HOST`).
  A plain-http index additionally requires
  `allow-insecure-host = ["<host>"]`
  (a list, and the host must match the index host).
  For `uv tool` commands, uv reads only user-level
  (`~/.config/uv/uv.toml`) and system-level (`/etc/uv/uv.toml`)
  configuration files — a project-local `uv.toml` is ignored —
  so the user documentation and the experiment setup must place the
  file at the user level.
  The real environment carries such a `uv.toml`,
  which is why uv ships in Phase A alongside pipx.
  The plugin never sets these — they are user environment —
  and the user documentation must state the requirement.

Shared rules, all inherited from the go implementation's lessons:

- Every interpolated value is validated against its grammar AND
  shell-quoted (defense in depth).
- Success is judged by an unconditional numeric exit-status trailer
  printed as the last line
  (`st=0 && { <cmd> 2>&1 || st=$?; } && echo "X_EXIT=$st"`,
  parsed with an end-anchored match) —
  never by a fixed success word, which build output can forge.
  Remember mise's `cmd.exec` shell aborts on the first unguarded
  nonzero status.
- After a zero status, the expected binary
  (`<install_path>/bin/<bin-or-tool-name>`) must exist, else abort.
  That abort message must go beyond "binary not found":
  a runner too old to honor the placement controls
  (`--prefix`, `PIPX_HOME`, `UV_TOOL_DIR`, …)
  installs into the user's real environment instead,
  and the missing expected binary is the only signal the plugin sees.
  The message therefore names the likely cause
  ("the runner may be too old to honor the install-location
  settings — check its version"),
  and the user documentation records the runner versions the
  experiment suites have verified.
  There is deliberately no minimum-version gate on runners:
  toolchains are the user's responsibility (decision 1),
  and the existence check already fails closed.
- The runner existence check runs first and its error message names the
  fix ("install <runner> and ensure it is on PATH").
  Note mise strips its own managed tool paths from PATH while hooks run
  (see the AGENTS.md lesson) — since these runners are user-installed
  (not mise-managed), plain PATH lookup is correct here,
  but a runner the user installed VIA mise will not be visible;
  document that limitation.

## 5. Environment handling

Inherit everything, pin almost nothing:
the subprocess environment is the user's own, so their registry,
proxy, and auth configuration Just Works.
The plugin sets only:

- placement (the per-runner directory variables above),
- the version pin (always in the command line, never resolved "latest"),
- noise suppression (update notifiers, telemetry, version checks —
  the specific variables listed per runner above),
- policy pins that keep decision 1 true
  (`RUSTUP_AUTO_INSTALL=0`, `UV_PYTHON_DOWNLOADS=never`, and
  `PIPX_FETCH_PYTHON=never` stop the
  installers from downloading toolchains by themselves;
  `PIPX_DEFAULT_BACKEND=pip` keeps pipx on the documented `pip.conf`
  channel even when uv is also installed).

Nothing else is overridden — no registry URLs, no index URLs,
no auth variables.

The pinned set is a guarantee, not best effort
(resolved 2026-08-20):
the per-runner variables above are documented as a table in the
user documentation,
tests assert they are set on every install,
and removing one is a behavior change.
Predictable installer output also protects the exit-status trailer
parsing,
so the pins are part of the success-detection defense,
not just politeness.
There is deliberately no `MISE_VAULT_*_REGISTRY` channel;
users who need a different registry configure their toolchain the way
that toolchain documents.

Each runner reads its registry from a different channel,
and they do not share configuration:
npm reads `.npmrc`;
bun reads `bunfig.toml`
(recent bun versions read a subset of `.npmrc` — verify in Phase C);
pip and pipx read `pip.conf`;
uv reads only its own settings (`UV_DEFAULT_INDEX`, `uv.toml`);
cargo reads `~/.cargo/config.toml` source replacement.
The user documentation must carry this mapping
so operators know which file to configure per runner.

For diagnosis, the install log prints the runner's effective registry
where the runner can report it (e.g. `npm config get registry`) —
display only, never validated and never overridden.

## 6. Integrity stance

Version-pin only.
None of these ecosystems supports an ad-hoc per-install content hash the
way go's `h1` does
(cargo/npm/bun verify only against the registry that serves the content;
pip's hash-checking mode needs a requirements file;
uv's `--require-hashes` does not exist on `uv tool install`) —
verified empirically in the research document.
The approved-version list in `versions.json` remains the security
boundary, as it already is for a go record without `h1`.
AGENTS.md's fail-closed bullet must be extended the same way it was for
the go exception: artifact SHA-256 stays mandatory,
ecosystem tool types are named as version-pin-only.
If pip-style hash pinning is ever wanted, a temp-requirements-file
mechanism for the pipx runner is the known path — explicitly out of
scope now.

Version pinning also does not reach the dependency tree,
and the three ecosystems differ sharply (resolved 2026-08-20):

- cargo `--locked` installs against the crate's committed lockfile —
  the entire tree is pinned.
- `npm install -g` resolves dependency ranges at install time;
  global installs use no lockfile,
  so the same approved version can pull a different tree next month.
- pipx and uv likewise resolve dependencies at install time.

No mechanism is added for this:
the private proxy being the only egress is the real control,
and a half-mechanism would be worse than an honest statement.
Instead the catalog carries a selection guideline:
prefer tools with zero runtime dependencies or self-contained
binaries.
The first approved batch is exactly that —
tokei (fully locked), prettier (zero dependencies),
ruff (one dependency-free wheel per platform) —
which also keeps offline-gate cache warming stable,
because a trivial dependency resolution cannot drift between
seeding time and test time.

## 7. Catalog tooling

- `scripts/add-version`: per-ecosystem existence probe before appending.
  Probe conventions are shared with the go probes:
  GET only (never HEAD), refuse redirects,
  always check the HTTP status code,
  and treat 404 and 410 as "absent".
  Endpoints:
  cargo — the sparse index the user's `config.toml` points at.
  Only a `sparse+http(s)://` index is supported:
  the probe strips exactly the `sparse+` marker,
  validates the remainder with the shared URL-shape rule,
  and rejects a git-index registry with a clear error.
  The crate's index path follows the registry's documented layout
  keyed by name length
  (e.g. `<index>/to/ke/tokei`; JSON lines, one line per version);
  npm — the package document at `<registry>/<escaped-package>`
  (`versions` map;
  a scoped name is URL-escaped as `@scope%2Fname`);
  pypi — the simple API at `<index>/<normalized-package>/`
  (PEP 691 JSON via content negotiation, HTML as fallback),
  the portable endpoint every index implements —
  never pypi.org's `/pypi/<package>/json`,
  which proxy repositories do not serve.
  Base URLs come from the user's toolchain configuration where
  practical
  (npm: for a scoped package, `npm config get @scope:registry`
  first, falling back to `npm config get registry` when no
  scope-specific value exists — npm itself routes scopes that way;
  pypi: pip's `index-url`),
  else from explicit `--registry-url`-style overrides;
  every base passes the same URL-shape validation used elsewhere,
  probes run through the user's environment
  (curl honors `http_proxy`),
  and auth rides the user's environment (netrc via `curl -n`),
  never the URL.
- `scripts/verify-artifacts`: same existence probes for every approved
  version; `--checksum` has nothing to verify for these types and must
  say so per record (skip, with the count reported), like h1-less go
  records.
- `scripts/validate-catalog` + schemas: new branches, cross-file rules
  (type ⇔ version-record shape), negative fixtures per grammar trap
  (shell metacharacters, uppercase, trailing newline, scoped-name edge
  cases), wired into `tests/run-validator-tests`.
- `scripts/vault-sync`: no change (aliases come from catalog directories).

## 8. Testing plan

- poc-test: per type — approved version installs and the binary runs;
  unapproved version fails by name; `mise tool <name>` resolves to
  `vault:<name>`; runner-missing aborts with the guidance message;
  `MISE_VAULT_*_RUNNER` with an unknown value aborts;
  forged-trailer regression per new command shape
  (mirror the existing go cases).
- Experiment stack: point the USER-ENV registry configuration of each
  toolchain at Nexus proxy repositories
  (npm and pypi proxy formats exist in Nexus CE),
  mirroring the production configuration shapes:
  user-level `.npmrc` `registry`,
  `pip.conf` `index-url` plus `trusted-host`,
  `uv.toml` `index-url` plus `allow-insecure-host`,
  cargo `config.toml` sparse-index source replacement,
  all over plain http —
  this exercises the inherit-the-environment design honestly.
  The production Nexus already serves a cargo proxy repository
  (a `sparse+http` index under `…/repository/OSS-cargo/`),
  so the format exists in current Nexus releases;
  what remains is confirming
  that the experiment stack's Nexus CE version supports it too.
  If it does not, cargo's end-to-end case runs online-only in
  poc-test and is excluded from the offline gate, with the limitation
  documented in the suite.
- offline-test: npm and pypi cases can join the offline gate once their
  proxy repos are seeded (warm the caches in seed-artifacts the way the
  go closure is warmed); cargo per the above.

## 9. Rollout phases

Each phase is its own branch + external-review loop + experiment gates:

- **Phase A — npm + pypi**
  (npm, pipx, and uv runners; pipx is the pypi default):
  best-understood placement controls,
  Nexus CE proxy support exists for both.
- **Phase B — cargo**: heavier (target machines need a Rust toolchain
  and C linker; installs compile from source), plus the Nexus CE
  registry-format question.
- **Phase C — bun runner**: gated on two empirical checks —
  the `BUN_INSTALL_GLOBAL_DIR`/`BUN_INSTALL_BIN` placement variables,
  and whether bun honors the environment's npm registry configuration
  (`.npmrc` support varies by bun version;
  a bun that silently reaches the public registry is disqualifying
  until it is configured via `bunfig.toml`).

## 10. Resolved questions (all settled 2026-08-20)

1. Real catalog example tools — resolved 2026-08-20:
   tokei (cargo), prettier (npm), ruff (pypi); see section 3.
2. `bin` field — resolved 2026-08-20:
   single optional string, default = tool name,
   expectation not instruction; see section 3.
3. Phase A runner order — resolved 2026-08-20:
   pipx is the default runner; uv ships alongside as opt-in.
   The real environment configures both channels
   (`pip.conf` and `uv.toml`),
   so both runners work there;
   pipx keeps the default because `pip.conf` is the more
   established of the two,
   reconfirmed by the project owner
   after the uv configuration surfaced.
4. Noise-suppression variable set — resolved 2026-08-20:
   guaranteed-pinned, like go's env table; see section 5.

All four questions are resolved;
together with the decisions recorded inline
(dependency-tree stance and selection guideline in section 6,
runner-age failure guidance in section 4,
lowercase-only version grammars in section 3),
the spec has no open items and is ready for Phase A implementation.

## Implementation notes (Phase A, 2026-08-20)

Phase A (npm, pypi) landed against this spec.
Two deviations from the plan were discovered during implementation
and accepted by the project owner;
both are recorded in full in `docs/research/SYNTHESIS.md` (entry 20),
and this note is the short version pinned to the spec that motivated
them.

1. `schemas/versions.schema.json` uses `anyOf`, not `oneOf`,
   for its per-item shapes.
   Bare-version records for go, npm, and pypi legally overlap —
   a value like `"1.0.0"` can satisfy more than one ecosystem's
   version envelope at once —
   and a single JSON Schema instance cannot see the sibling
   `tool.json` to know which type actually applies.
   `oneOf` would reject some valid records as ambiguous purely as a
   schema artifact, unrelated to whether the record is wrong.
   The schema therefore proves shape-membership only;
   `scripts/validate-catalog` is what enforces the exact grammar for
   the tool's declared type, cross-file, against `tool.json`.
2. When `bin` is absent, the tool name itself must satisfy the bin
   grammar, 64-character cap included, since `bin` defaults to the
   tool name.
   A long `name` with no explicit `bin` would otherwise pass schema
   validation and only fail at install time, when the plugin tries to
   verify a binary whose defaulted name violates a grammar nothing
   ever checked.
   `scripts/validate-catalog` now enforces this at approval time,
   so a bad entry fails there, not at a developer's `mise install`.

Also confirmed during implementation, not a deviation from the plan
but worth recording alongside it:
the effective-registry diagnostic line (section 7's "for diagnosis,
the install log prints the runner's effective registry") relies on
plugin `print()` output being visible in default `mise install`
output — verified against the experiment stack, surfacing as
`INFO [vault] ...`.
pipx placement was verified on pipx 1.4.3: `PIPX_HOME`/`PIPX_BIN_DIR`
place the installation correctly, but `PIPX_MAN_DIR`,
`PIPX_COMPLETION_DIR`, `PIPX_DEFAULT_BACKEND`, and `PIPX_FETCH_PYTHON`
are silently inert on that version — each was introduced in a later
pipx release, so the no-leftover-files and pinned-backend guarantees
those variables provide only hold on a sufficiently recent pipx.
The plugin sets all of them regardless, since they are
forward-compatible and an old pipx just ignores what it does not
recognize.

## Implementation notes (Phase B, 2026-08-20)

Phase B (cargo) landed against this spec.
tokei 14.0.0 is the seeded example — the latest stable, non-yanked
release on crates.io at approval time.
Full detail is recorded in `docs/research/SYNTHESIS.md` (entry 21);
this note is the short version pinned to the spec that motivated each
point.

1. **`require_runner`'s error message gained a second, cargo-specific
   sentence.**
   Section 4 already specifies that the runner-missing message names
   the fix ("install \<runner\> and ensure it is on PATH").
   For cargo, a bare "cargo not found" would send an operator looking
   for the wrong fix, since cargo installs compile from source: the
   hook now also names the Rust-toolchain-and-C-linker requirement up
   front, in the same message, before the operator goes looking.
2. **A yanked crate version is refused at approval time, not installed
   and then discovered broken.**
   The section 7 probe convention ("GET only, refuse redirects, always
   check the HTTP status code, treat 404 and 410 as absent") is
   extended, not replaced: a sparse-index line whose `vers` matches but
   whose `yanked` field is `true` is treated exactly like a missing
   line.
   This was not spelled out in section 7 because the sparse index
   format itself was not yet confirmed at spec time; crates.io's own
   `cargo install` already refuses a yanked version, so refusing it
   before it ever reaches `versions.json` keeps the catalog's
   fail-closed posture aligned with the registry's, rather than
   deferring the failure to a developer's `mise install`.
3. **`~/.cargo/config.toml` parsing choices, resolving the one thing
   section 4's index-resolution sketch left implicit.**
   `$CARGO_HOME/config.toml` replaces `~/.cargo/config.toml` outright
   when `CARGO_HOME` is set — matching cargo's own `CARGO_HOME`
   precedence exactly, not layering the two.
   Absence of `[source.crates-io]` `replace-with` in the resolved file
   is not an error: it means the default public sparse index legitimately
   applies, mirroring cargo's own default when nothing overrides it.
   A `replace-with` that names a registry with no matching
   `[registries.<name>]` `index` IS an error — a hard abort naming the
   fix, never a silent fallback to the public index — because a broken
   redirect resolving to "try the public internet instead" is exactly
   the fallback this project forbids, even though an absent
   `replace-with` legitimately reaches the same public index by
   default.
4. **Nexus CE supports the cargo proxy repository format, resolving
   section 8's open item.**
   Section 8 left this as a research-time unknown ("what remains is
   confirming that the experiment stack's Nexus CE version supports it
   too" — with an online-only fallback plan if not).
   Verified empirically against Nexus CE 3.95.1: a `cargo/proxy`
   repository proxying `https://index.crates.io` serves the standard
   sparse index layout directly under the repository root, and its
   `config.json` `dl` field routes crate tarball downloads through the
   same proxy, so the fallback plan was never needed — the cargo case
   runs end-to-end through the experiment Nexus and joins the offline
   gate unconditionally, the same as npm and pypi.
