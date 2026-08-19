# Ecosystem tool types: cargo, npm/bun, pip/uv — proposed design

Status: PROPOSED (approved in discussion on 2026-08-20, not yet implemented).
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
   and `MISE_VAULT_PYPI_RUNNER=uv|pipx` (default `uv`).
   An unknown value, or a selected runner missing from PATH, aborts;
   there is never a silent fallback to the other runner.

## 3. Catalog shapes

Three new `tool.json` types, one branch each in the schema `oneOf`:

```json
{ "name": "ripgrep", "type": "cargo", "crate": "ripgrep" }
{ "name": "typescript", "type": "npm", "package": "typescript" }
{ "name": "ruff", "type": "pypi", "package": "ruff" }
```

(The three example tools above are placeholders —
confirm or replace them with the real tools to approve
before implementation.)

- `crate`: crates.io naming rules, shell-safe grammar
  (lowercase letters, digits, `-`, `_`; no leading digit requirement
  beyond what crates.io itself enforces).
- npm `package`: bare or scoped (`@scope/name`), lowercase,
  URL-safe characters only; the `/` in a scoped name is the only
  path separator allowed anywhere in the value.
- pypi `package`: PEP 503 normalized form
  (lowercase letters, digits, single `-` separators).
- Every grammar is anchored against trailing newlines
  (`\Z` in Python, `(?![\s\S])` in the JSON Schemas),
  is enforced by both validation engines and re-checked at runtime
  before the value reaches a shell command,
  exactly like the go module grammar.
- The binary-name rule differs by ecosystem and must be validated where
  a rule exists:
  cargo and npm packages may install binaries whose names differ from
  the package name, so these types need an optional `bin` field
  (defaulting to the tool name) that names the executable the exec-env
  and post-install existence check look for.
  Whether `bin` is a single string or a list is an implementation
  decision; start with a single string (YAGNI).

`versions.json`: the same ordered array, entries carry a bare `version`
only — **no checksum field for these types** (see section 6).
Version grammars per ecosystem, all shell-safe and lowercase,
starting from the go version grammar and widening only where the
ecosystem requires it (e.g. PEP 440 local segments use `+`).

## 4. Install semantics (hook branch per type)

All types install into `<install_path>` with binaries in
`<install_path>/bin`; `BackendExecEnv` adds that directory to PATH
(same branch the go type uses — generalize the existing
`tool.type == "go"` check to a set of source-built types).

- **cargo**:
  `cargo install <crate> --version <version> --locked --root <install_path>`
  (binaries land in `<root>/bin` natively).
  `--locked` uses the crate's committed lockfile for reproducibility;
  if a crate ships no lockfile, cargo errors and the failure message is
  surfaced (fail closed; document the flag so operators understand it).
- **npm runner npm**:
  `npm install -g --prefix <install_path> <package>@<version>`;
  npm puts binaries in `<prefix>/bin` on Linux/macOS.
  Pin `NPM_CONFIG_UPDATE_NOTIFIER=false` and `NPM_CONFIG_FUND=false`
  (pure noise suppression, not policy).
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
- **pypi runner uv**:
  `uv tool install <package>==<version>` with
  `UV_TOOL_DIR=<install_path>/tools` and
  `UV_TOOL_BIN_DIR=<install_path>/bin`.
  uv is a managed-environment installer: the binary in bin is a
  launcher into `UV_TOOL_DIR`, so both directories must live under
  `install_path` for uninstall to stay clean.
- **pypi runner pipx**:
  `pipx install <package>==<version>` with
  `PIPX_HOME=<install_path>/pipx` and `PIPX_BIN_DIR=<install_path>/bin`.
  Pin `PIP_DISABLE_PIP_VERSION_CHECK=1`.

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
  the specific variables listed per runner above).

Nothing else is overridden — no registry URLs, no index URLs,
no auth variables.
There is deliberately no `MISE_VAULT_*_REGISTRY` channel;
users who need a different registry configure their toolchain the way
that toolchain documents.

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

## 7. Catalog tooling

- `scripts/add-version`: per-ecosystem existence probe before appending —
  crates.io sparse index (`https://index.crates.io/.../<crate>`, JSON
  lines), npm registry package document
  (`<registry>/<package>` → `versions` map), PyPI JSON API
  (`<index>/pypi/<package>/json`).
  Probes run through the user's environment (curl honors `http_proxy`),
  and read the registry base from the user's toolchain configuration
  where practical, else accept `--registry-url`-style overrides.
  Keep the URL-shape validation and redirect-refusal conventions.
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
  (npm and pypi proxy formats exist in Nexus CE) —
  this exercises the inherit-the-environment design honestly.
  Cargo's registry format in Nexus CE was flagged uncertain in research:
  verify; if unavailable, cargo's end-to-end case runs online-only in
  poc-test and is excluded from the offline gate, with the limitation
  documented in the suite.
- offline-test: npm and pypi cases can join the offline gate once their
  proxy repos are seeded (warm the caches in seed-artifacts the way the
  go closure is warmed); cargo per the above.

## 9. Rollout phases

Each phase is its own branch + external-review loop + experiment gates:

- **Phase A — npm + pypi** (npm and uv runners first; pipx alongside if
  cheap): best-understood placement controls, Nexus CE proxy support
  exists for both.
- **Phase B — cargo**: heavier (target machines need a Rust toolchain
  and C linker; installs compile from source), plus the Nexus CE
  registry-format question.
- **Phase C — bun runner**: gated on the empirical
  `BUN_INSTALL_GLOBAL_DIR`/`BUN_INSTALL_BIN` verification.

## 10. Open questions for the implementation conversation

1. Real catalog example tools per type (current ones are placeholders).
2. `bin` field: confirmed single-string default-to-tool-name shape?
3. Phase A: ship pipx runner together with uv, or uv only first?
4. Should the noise-suppression variable set be documented as
   guaranteed-pinned (like go's env table) or best-effort?
