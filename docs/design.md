# mise-vault — Design

Status: living document.
This started as the initial design proposal and has been amended
after the research and proof-of-concept phases (2026-08-18),
then again after Phase A of the ecosystem tool types landed (2026-08-20).
Evidence and the numbered decision log live in [research/SYNTHESIS.md](research/SYNTHESIS.md);
this document states the resulting rules in plain language.

## Key amendments over the original proposal

1. **Bootstrap is git-based, not `curl | sh`.**
   GitLab's `/-/raw/` web route accepts no token authentication on private projects
   (basic auth, `PRIVATE-TOKEN` header, and `?private_token=` all redirect to sign-in).
   Developers bootstrap with `git clone --depth 1 -b <tag> ... && ./install.sh` (rides `~/.netrc`);
   CI uses the `/api/v4/projects/:id/repository/files/:path/raw?ref=` endpoint with a `PRIVATE-TOKEN` header.
2. **Bootstrap writes user-scoped mise settings `gix = false` and `libgit2 = false`.**
   mise's default built-in git client ignores netrc and credential helpers;
   forcing the real git binary makes standard corporate auth work for plugin installs and updates.
3. **Artifact download and checksum verification shell out** (`curl -n`, `sha256sum`/`shasum -a 256`).
   The plugin Lua HTTP module never reads netrc and the Lua API has no hashing primitive.
4. **`versions.json` is an ordered array** (oldest approved first), not an object keyed by version.
   The plugin returns catalog order verbatim and makes no semver assumption;
   CI validates ordering and uniqueness.
5. **Short-name routing is solved with mise's `[tool_alias]`**
   in a generated file `~/.config/mise/conf.d/mise-vault.toml`.
   Aliases are pure routing entries (`go = "vault:go"`);
   the Nexus base URL is committed in the plugin's `config/defaults.json`
   and read from the installed checkout, so URL and plugin version cannot diverge.
   The file is derived from the catalog by `scripts/vault-sync`, never hand-edited,
   and `mise run vault-sync <tag>` performs plugin update + regeneration.
   An alias pointing at an uninstalled plugin does not auto-install it,
   so bootstrap always pre-installs the plugin.
6. **Public fallback is fully blocked by policy.**
   A short name missing from the generated alias file silently falls back
   to mise's public registry (observed live);
   bootstrap therefore also disables public backends in mise settings,
   and network-level isolation remains the hard guarantee.
7. **Sidecar checksum files in Nexus feed catalog tooling only.**
   `scripts/add-version` prefers `<artifact>.sha256sum` to avoid downloading tarballs,
   but installation verifies exclusively against the catalog value —
   a checksum stored next to its artifact proves nothing if the store is compromised.
8. **The original open questions (section 33) are all answered** — see research/SYNTHESIS.md.
9. **A second tool type exists: go-installed tools.**
   Not every tool is a prebuilt artifact — some are built on the fly with
   `go install <module>@v<version>` against a go module proxy the plugin
   controls (see the "Go-Installed Tool" worked example later in this
   document).
   Routing stays exactly the same as every other tool (`vault:<tool>`,
   name↔module mapping in `tool.json`); only the install mechanism differs.
   The go proxy gets its own env-var/option/default resolution ladder,
   deliberately separate from the Nexus one, so a go tool never inherits a
   developer's own `GOPROXY`.
   Module checksum verification (`h1`, matching `go.sum`'s format) is
   optional per version — the one deliberate exception to this catalog's
   "checksum verification is never optional" rule, justified because the
   go proxy is company infrastructure the plugin itself addresses, and the
   approved-version list is still the actual gate on what installs.
10. **Two more tool types exist: npm and pypi (Phase A of the ecosystem
    tool types; see the "Ecosystem-Installed Tools" worked example
    later in this document).**
    They install through the ecosystem's own package manager
    (npm; pipx by default or uv opt-in) rather than through Nexus or a
    plugin-controlled proxy, reading whatever registry the user's own
    environment already configures.
    This is a scoped, deliberate revision of the "no public internet
    after bootstrap" principle: it applies only to these two types,
    and it leaves the rule exactly as absolute as before for artifact
    and go-installed tools.
    They are version-pin-only — no checksum field exists for either
    type, so the approved-version list is their entire security
    boundary, the same role it already plays for an `h1`-less go
    record.
    Routing is unchanged (`vault:<tool>`, package name in `tool.json`).
    cargo (Phase B) and a bun runner (Phase C) are planned to follow
    the same pattern.

## 1. Overview

`mise-vault` is a private mise backend plugin for distributing centrally approved developer tools inside a fully isolated enterprise network.

The system must operate entirely using private infrastructure:

- **Private GitLab** for plugin source code, configuration, and the approved tool catalog.
- **Private Nexus** for immutable prebuilt binaries and archives.
- **mise** for client-side tool version management and activation.

After bootstrap, no access to public services should be required
for artifact and go-installed tools — the plugin builds every URL
itself, from Nexus or the plugin-controlled go proxy.

In particular, normal operation of those tool types must not depend on:

- GitHub
- GitLab.com
- go.dev
- proxy.golang.org
- crates.io
- PyPI
- npm
- Aqua's public registry
- Public release APIs
- Other Internet services

npm and pypi tool types (added in Phase A of the ecosystem tool types,
section 14.5) are a scoped, deliberate exception to this list:
they install through the ecosystem's own package manager, which reads
whatever registry — crates.io, PyPI, npm, or a private mirror of any of
them — the user's own environment already configures.
The plugin constructs no registry URL of its own for these types at all,
so egress there is a network-policy and user-configuration matter,
not something the plugin can enforce; see section 14.5 for the full
rationale and section 30 for how this changes the PoC success criteria.

The desired developer experience is intentionally conventional:

```bash
mise ls-remote go
mise ls-remote golangci-lint
mise ls-remote glab

mise use go@1.26.0
mise use golangci-lint@2.4.1
mise use glab@1.80.0

mise install
```

A project should ideally need nothing more than:

```toml
[tools]
go = "1.26.0"
golangci-lint = "2.4.1"
glab = "1.80.0"
```

Existing repositories using `.tool-versions` should remain compatible wherever practical:

```text
golang 1.26.0
golangci-lint 2.4.1
glab 1.80.0
```

Developers should not need to understand or configure:

- Nexus repository URLs
- Archive layouts
- Aqua registries
- mise HTTP backends
- Go/Cargo/PyPI/npm installation mechanisms
- OS/architecture naming differences
- Artifact checksums
- Internal approval metadata
- Internal backend routing

Those are platform concerns and belong in `mise-vault`.

One caveat, added by Phase A of the ecosystem tool types (section 14.5):
a developer who wants an npm or pypi tool DOES need their own npm/pip/uv
registry configuration pointed at a reachable registry
(usually already set up for their other ecosystem work).
The plugin still hides the installation mechanism —
which command runs, where the binary lands, which noise-suppression
variables are set — but registry reachability is the same prerequisite
that ordinary `npm install` or `pip install` already has,
and this plugin does not remove it for these two types.

---

# 2. Goals

## 2.1 Fully Private Operation

Once installed, `mise-vault` must work in a network with access only to approved internal infrastructure.

The minimum network dependency should be:

```text
Developer Workstation
        |
        +----> Private GitLab
        |
        +----> Private Nexus
        |
        X----> Internet
```

Public Internet access must not be required for:

```bash
mise ls-remote <tool>
mise install <tool>@<version>
mise use <tool>@<version>
mise outdated
```

for artifact and go-installed tools — the plugin builds every URL itself
for those, and the diagram above is the complete dependency set.
There must be no automatic fallback to public package registries or
release APIs for these types.

npm and pypi tools (section 14.5) are the deliberate exception:
`mise install <tool>@<version>` for those runs the ecosystem's own
package manager against whatever registry the user's own environment
configures, so the third arrow in the diagram above is theirs to draw,
not the plugin's — reachability there depends on where that registry
points, exactly as it would for an unmanaged `npm install` or
`pip install`.
`mise ls-remote <tool>` never depends on any of this, for any tool type:
version listing always reads the local catalog checkout, never a
network call.

---

## 2.2 Simple Developer Experience

Installation should be a one-time bootstrap operation.

For example:

```bash
git clone -q --depth 1 -b v1.0.0 \
  https://gitlab.company.example/devtools/mise-vault.git /tmp/mise-vault-bootstrap
/tmp/mise-vault-bootstrap/install.sh
```

After bootstrap, developers should use ordinary mise commands:

```bash
mise ls-remote golangci-lint
mise use golangci-lint@2.4.1
mise install
mise outdated
```

Application repositories should only express:

> Which tool and version does this project require?

They should not express:

> How is the tool downloaded and installed inside the company?

---

## 2.3 Central Tool Governance

`mise-vault` must define which tools and versions are approved for use.

For example:

```bash
$ mise ls-remote golangci-lint

2.3.1
2.4.0
2.4.1
```

Suppose upstream has:

```text
2.5.0
2.5.1
```

and Nexus already contains a staging artifact for `2.5.0`.

If neither version has been approved in the `mise-vault` catalog, developers must not see them.

The security model is therefore:

```text
Artifact exists in Nexus
        !=
Approved for developer use
```

Instead:

```text
Artifact exists in Nexus
        +
Version exists in mise-vault catalog
        =
Approved tool version
```

Therefore:

> `mise ls-remote` should effectively mean "list company-approved versions."

---

## 2.4 Reproducible Tool Universe

The first implementation should keep plugin implementation and catalog data in the same Git repository and release them together.

For example:

```text
mise-vault v1.5.0

go:
  1.25.6
  1.26.0

golangci-lint:
  2.4.0
  2.4.1

glab:
  1.79.0
  1.80.0
```

This gives the useful invariant:

> A specific `mise-vault` release defines a deterministic set of available tools and versions.

---

# 3. Non-Goals

The initial implementation should not become:

- A general-purpose package manager.
- A replacement for Nexus.
- A replacement for GitLab.
- An OSS review system.
- A vulnerability scanner.
- A build system.
- A public mise registry.
- A proxy for GitHub or public language registries.
- A dynamic metadata service.
- A dependency resolver for arbitrary Go, Rust, Python, or Node packages.

The backend should remain a relatively thin installation and resolution layer.

---

# 4. Architecture

```text
                         PUBLIC NETWORK
                              |
                              v
                     OSS Intake Workflow
                              |
                  Review / Verification
                              |
             +----------------+----------------+
             |                                 |
             v                                 v
      Reviewed Source                    Trusted Build
             |                                 |
             v                                 v
      Private GitLab                     Binary Archives
       OSS Snapshots                           |
                                               v
                                          Private Nexus


====================== PRIVATE NETWORK ======================


                    Private GitLab
                  devtools/mise-vault
                         |
            +------------+-------------+
            |                          |
            v                          v
     Backend Plugin               Tool Catalog
            |                          |
            +------------+-------------+
                         |
                         v
                       mise
                         |
                         v
                   Private Nexus
                         |
                         v
                Approved Artifact
```

Responsibilities should remain deliberately separated:

| Component | Responsibility |
|---|---|
| OSS intake workflow | Import and review upstream software |
| Private GitLab OSS repositories | Preserve reviewed source snapshots |
| Trusted build pipeline | Build approved binaries and archives |
| Private Nexus | Store immutable artifacts |
| `mise-vault` catalog | Define approved tools, versions, platforms, and checksums |
| `mise-vault` backend | Resolve versions and install artifacts |
| mise | Tool lifecycle and environment activation |
| `mise.toml` / `.tool-versions` | Declare project tool requirements |

---

# 5. OSS Source Intake

Open-source projects should be independently imported and reviewed before becoming available inside the private environment.

A typical workflow is:

```text
Upstream repository/release
          |
          v
Temporary review workspace
          |
          +--> License review
          +--> Security review
          +--> Dependency review
          +--> Source verification
          |
          v
       Approved
          |
          v
Remove upstream .git metadata
          |
          v
Initialize internal repository
          |
          v
Private GitLab
```

The private GitLab repository should contain a reviewed source snapshot rather than a mirror of the upstream Git history.

The resulting internal Git history represents:

- Import events
- Security reviews
- Company modifications
- Version upgrades
- Internal approvals

rather than upstream development history.

Useful provenance metadata should still be retained.

For example:

```yaml
upstream:
  repository: https://example.org/upstream/project
  version: v2.4.1
  commit: abcdef1234567890

review:
  ticket: OSS-2841
  approved_at: 2026-08-18

source:
  sha256: <source-archive-sha256>
```

---

# 6. Trusted Build Model

Developer workstations should preferably not compile third-party developer tools during installation.

Avoid installation paths such as:

```text
mise
  -> cargo install
  -> resolve/build many crates
```

or:

```text
mise
  -> go install
  -> resolve/build a Go module graph
```

or:

```text
mise
  -> pipx
  -> resolve Python packages dynamically
```

Instead:

```text
Reviewed Source
      |
      v
Trusted Build Pipeline
      |
      +--> Binary/archive
      +--> SHA-256
      +--> SBOM
      +--> Build provenance
      |
      v
Private Nexus
```

Developers then consume only an approved artifact.

This should apply independently of the implementation language.

For example:

```text
glab             Go
golangci-lint    Go
ripgrep          Rust
ruff             Rust
uv               Rust
custom CLI       Python
```

From the developer's perspective, all of these are simply tools.

---

# 7. Repository Layout

The repository is self-contained.

The implemented structure:

```text
mise-vault/
├── README.md
├── AGENTS.md
├── install.sh
├── metadata.lua
│
├── hooks/
│   ├── backend_list_versions.lua
│   ├── backend_install.lua
│   └── backend_exec_env.lua
│
├── lib/
│   └── common.lua            # shared helpers: catalog loading, platform id, URL building
│
├── catalog/
│   ├── go/
│   │   ├── tool.json
│   │   └── versions.json
│   ├── glab/
│   │   ├── tool.json
│   │   └── versions.json
│   └── golangci-lint/
│       ├── tool.json
│       └── versions.json
│
├── config/
│   └── defaults.json          # committed Nexus base URL
│
├── schemas/
│   ├── tool.schema.json
│   └── versions.schema.json
│
├── tests/
│   ├── fixtures/
│   │   ├── catalog/           # schema-valid entries that fail at runtime on purpose
│   │   └── invalid-catalog/   # shapes the validator must reject
│   ├── lib/                   # shared python test harness
│   ├── run-harness-selftest
│   └── run-validator-tests
│
├── scripts/
│   ├── approve
│   ├── validate-catalog
│   ├── add-version
│   ├── verify-artifacts
│   └── vault-sync
│
└── experiment/                # local Docker stack (Nexus + GitLab) and end-to-end suites
```

Do not introduce a separate catalog service for the first version.

The Git repository itself is the approved catalog database.

---

# 8. Catalog Design

Static installation metadata and frequently changing version metadata should be separated.

## 8.1 `tool.json`

Example for `golangci-lint`:

```json
{
  "name": "golangci-lint",
  "type": "archive",
  "platforms": {
    "linux-amd64": {
      "artifact": "golangci-lint-{version}-linux-amd64.tar.gz",
      "format": "tar.gz",
      "strip_components": 1,
      "bin_paths": ["."]
    },
    "linux-arm64": {
      "artifact": "golangci-lint-{version}-linux-arm64.tar.gz",
      "format": "tar.gz",
      "strip_components": 1,
      "bin_paths": ["."]
    }
  }
}
```

This describes **how the tool is packaged**.

It should not need modification whenever a normal new version is approved.

---

## 8.2 `versions.json`

An ordered array, oldest approved version first.
The order is authoritative:
the backend returns it verbatim to mise and never re-sorts,
so no assumption about version schemes (semver, date-based, or otherwise) leaks into runtime code.
CI validates uniqueness and, for purely numeric schemes, ascending order.

```json
[
  {
    "version": "2.4.0",
    "platforms": {
      "linux-amd64": { "sha256": "<sha256>" },
      "linux-arm64": { "sha256": "<sha256>" }
    }
  },
  {
    "version": "2.4.1",
    "platforms": {
      "linux-amd64": { "sha256": "<sha256>" },
      "linux-arm64": { "sha256": "<sha256>" }
    }
  }
]
```

Adding a normal version appends one record — a small, reviewable, append-only diff.

For example:

```diff
 [
   {
     "version": "2.4.0",
     "platforms": { ... }
+  },
+  {
+    "version": "2.4.1",
+    "platforms": {
+      "linux-amd64": { "sha256": "..." },
+      "linux-arm64": { "sha256": "..." }
+    }
   }
 ]
```

This is desirable because the catalog MR itself becomes part of the approval process.

---

# 9. Catalog Schema

The catalog should be formally schema-validated.

At minimum, each tool definition should describe:

```text
name
type
supported platforms
artifact naming rule
archive format
strip depth and bin paths (directories put on PATH)
```

Each version record should contain:

```text
version
supported platforms
SHA-256 for every platform artifact
```

Optional future metadata may include:

```text
source repository
source commit
review ticket
approval timestamp
SBOM reference
provenance reference
deprecation status
end-of-life date
security notes
```

Do not require all governance metadata to participate in installation logic.

Installation metadata and audit metadata should remain conceptually separable.

---

# 10. Nexus Layout

Use a deterministic artifact hierarchy.

For example:

```text
repository/devtools/
├── go/
│   ├── 1.25.6/
│   │   ├── go1.25.6.linux-amd64.tar.gz
│   │   └── go1.25.6.linux-arm64.tar.gz
│   └── 1.26.0/
│       ├── go1.26.0.linux-amd64.tar.gz
│       └── go1.26.0.linux-arm64.tar.gz
│
├── glab/
│   └── 1.80.0/
│       ├── glab-1.80.0-linux-amd64.tar.gz
│       └── glab-1.80.0-linux-arm64.tar.gz
│
└── golangci-lint/
    ├── 2.4.0/
    └── 2.4.1/
```

The backend should define one centrally configurable Nexus base URL:

```text
https://nexus.company.example/repository/devtools
```

Artifact URLs should normally be constructed from:

```text
<NEXUS_BASE>/<tool>/<version>/<artifact>
```

Do not copy the Nexus hostname into every version record.

This allows a Nexus migration to require one configuration change instead of rewriting the catalog.

---

# 11. Version Discovery

`BackendListVersions` should read the version catalog from the local plugin checkout.

It must not:

- Query GitHub.
- Query public release APIs.
- Enumerate Nexus directories.
- Infer versions from file names.
- Contact a separate metadata service.

Conceptually:

```text
mise ls-remote golangci-lint
            |
            v
    BackendListVersions
            |
            v
   Local plugin directory
            |
            v
catalog/golangci-lint/versions.json
            |
            v
       Parse versions
            |
            v
Return catalog order verbatim
   (the array is already
  oldest-approved first)
            |
            v
2.4.0
2.4.1
```

This provides deterministic discovery.

The locally installed plugin/catalog version controls what is visible.

---

# 12. Installation Flow

The installation flow should be approximately:

```text
mise install golangci-lint@2.4.1
                  |
                  v
           BackendInstall
                  |
          +-------+-------+
          |               |
          v               v
       tool.json      versions.json
          |               |
          +-------+-------+
                  |
                  v
           Resolve platform
                  |
                  v
          Resolve artifact
                  |
                  v
       Construct Nexus URL
                  |
                  v
             Download
                  |
                  v
          Verify SHA-256
                  |
                  v
             Extract
                  |
                  v
          Final install path
```

Checksum verification is mandatory.

A mismatching checksum must fail installation.

There must be no fallback such as:

```text
checksum failed
     |
     v
continue anyway
```

or:

```text
internal artifact missing
     |
     v
try upstream
```

Both are prohibited.

---

# 13. Platform Model

Define a canonical internal platform vocabulary.

Initial platforms:

```text
linux-amd64
linux-arm64
darwin-amd64
darwin-arm64
```

Windows may be added if required.

The backend should normalize runtime/mise platform information into these canonical identifiers.

Tool-specific archive naming belongs in `tool.json`.

For example, one upstream may call AMD64:

```text
amd64
```

another:

```text
x86_64
```

and another:

```text
x64
```

These differences must not leak into application repositories.

---

# 14. Supported Installation Types

The architecture should support at least three classes of tools.

## 14.1 Single Binary

Example artifact:

```text
jq
```

Installation:

```text
download
-> verify
-> chmod executable
-> install
```

---

## 14.2 Archive Containing Executable

Example:

```text
golangci-lint-2.4.1-linux-amd64.tar.gz

golangci-lint-2.4.1-linux-amd64/
└── golangci-lint
```

Installation:

```text
download
-> verify
-> extract
-> expose executable
```

---

## 14.3 Runtime Distribution

Go is an important example.

Input:

```text
go1.26.0.linux-amd64.tar.gz

go/
├── bin/
├── pkg/
├── src/
└── ...
```

Result:

```text
<install_path>/
├── bin/
├── pkg/
├── src/
└── ...
```

The environment should then expose approximately:

```text
PATH=<install_path>/bin
GOROOT=<install_path>
```

---

## 14.4 Go-Installed Tool

gocensus is the example.
There is no artifact to download at all: `tool.json` carries a `module`
(the package path passed to `go install`) instead of `platforms`, and
`versions.json` carries a bare version plus an optional `h1` checksum
instead of per-platform SHA-256 values.

```json
{
  "name": "gocensus",
  "type": "go",
  "module": "github.com/arloliu/gocensus/cmd/gocensus",
  "module_root": "github.com/arloliu/gocensus"
}
```

`module_root` names the module that `go mod download` verifies when a
version carries an `h1`; here the installed package lives under `/cmd/`,
so the package path alone would not resolve as a module.

Installation:

```text
version approved?
-> approved go toolchain located (PATH go if its version is approved,
   else mise's own install tree, newest approved version first —
   any binary merely named "go" is refused)
-> (if h1 present) no nested module shadows module_root at this version,
   then go mod download -json against the plugin's GOPROXY,
   compare Sum, abort on mismatch
-> go install <module>@v<version> with GOBIN=<install_path>/bin
```

Every go subprocess runs in a pinned environment: the plugin's GOPROXY,
`GONOPROXY=none`, empty `GOPRIVATE`, pinned `GOFLAGS`, `GOSUMDB=off`,
`GOTOOLCHAIN=local`, `GOENV=off`, `GOCACHEPROG` cleared, and fresh
per-install `GOMODCACHE`/`GOPATH`/`GOCACHE` directories shared by the
checksum preflight and the build (details and rationale in
docs/development.md).

The environment then exposes just:

```text
PATH=<install_path>/bin
```

No GOROOT, no platform lookup — a go-installed tool runs wherever an
approved go toolchain already runs.

Prebuilt runtime distributions — the go distribution itself is the worked
example — are modeled generically: platform artifacts in the catalog plus
tool-specific environment definitions (like GOROOT) where required, never
runtime-specific code.
The go-installed tool type is the deliberate, contained exception: it is
one explicit branch in the install and exec-env hooks, driven entirely by
catalog data, and future build-from-source ecosystems (Python, Node.js,
Rust, Java tooling) would follow the same pattern — a catalog-driven
branch per ecosystem, never per-tool code.

---

## 14.5 Ecosystem-Installed Tools (npm, pypi)

prettier (npm) and ruff (pypi) are the Phase A examples.
Like a go-installed tool, there is no artifact to download and no
`platforms` entry in `tool.json` — just the package name the ecosystem
already knows it by:

```json
{ "name": "prettier", "type": "npm", "package": "prettier" }
{ "name": "ruff", "type": "pypi", "package": "ruff" }
```

`versions.json` carries a bare version and, deliberately, no checksum
field at all: neither ecosystem supports an ad-hoc per-install content
hash the way go's `h1` does, so these types are version-pin-only by
design, and the approved-version list is the entire security boundary
for them, exactly as it already is for an `h1`-less go record.

The load-bearing difference from every other tool type is the network
model.
A go-installed tool still resolves through a proxy the plugin
constructs and controls (the GOPROXY ladder, section 14.4).
An npm or pypi tool installs through a runner selected by an
environment variable (`MISE_VAULT_NPM_RUNNER`, `MISE_VAULT_PYPI_RUNNER`
— pipx is the pypi default; npm is the npm default) that reads its
registry from the user's own environment: `.npmrc` for npm,
`pip.conf` for pipx (it installs through pip), `uv.toml` or
`UV_DEFAULT_INDEX`/`UV_INSECURE_HOST` for the opt-in uv runner.
The plugin sets only placement (where the binary lands), the version
pin, and a small table of noise-suppression and
toolchain-download-refusal environment variables — it never sets a
registry URL, an index URL, or any auth for these types.
That is the scoped exception to the "no public internet, no fallback"
principle stated in sections 1 and 2.1: for these two types, the
network boundary is enforced by the same mechanism that already
enforces it for a developer's own `npm install` or `pip install` —
network policy (the forward proxy) and the user's own registry
configuration — not by the plugin constructing a URL.
Toolchains themselves (node/npm, python/pip/pipx/uv) are the user's
responsibility too, the same way go's own toolchain already was;
the plugin only requires the selected runner to be on `PATH` and fails
closed, naming the fix, when it is not.

Installation (npm shown; pypi via pipx or uv follows the same shape):

```text
version approved?
-> selected runner on PATH? (else fail closed, naming the fix)
-> npm install -g --prefix <install_path> <package>@<version>
   (noise-suppression variables pinned; registry read from .npmrc)
-> expected binary exists at <install_path>/bin/<bin-or-name>?
   (else fail closed — likely cause: a runner too old to honor
   the placement controls)
```

The environment then exposes just:

```text
PATH=<install_path>/bin
```

Full field grammars, the per-runner environment-variable table, the
registry-probe conventions `scripts/add-version` uses, and the
rollout phases (npm+pypi now, cargo and the bun runner later) are
authoritative in `docs/specs/2026-08-20-ecosystem-tools-design.md`;
this section states the resulting shape, not the detail.

---

# 15. Bootstrap Installer

The repository contains an `install.sh`.

Workflow (git-based — see Key amendments #1 for why raw-URL piping is not used):

```bash
git clone -q --depth 1 -b v1.0.0 \
  https://gitlab.company.example/devtools/mise-vault.git /tmp/mise-vault-bootstrap
/tmp/mise-vault-bootstrap/install.sh
```

The script should:

1. Validate prerequisites.
2. Verify that a supported mise version exists.
3. Install/register `mise-vault`.
4. Configure required backend routing.
5. Configure any company-level mise settings.
6. Validate the plugin installation.
7. Run a minimal smoke test.
8. Print concise usage examples.

Prefer mise's native plugin management over manually copying files into mise internal directories.

The bootstrap implementation should be idempotent.

Running it twice should not corrupt an existing installation.

---

# 16. Bootstrap Security

Cloning the default branch installs the exact commit you cloned —
every commit on the default branch has passed merge request review and CI,
so it is always a valid current version.
Clone with `-b <release-tag>` when you need an immutable pin
(rollback, reproducible workstation setup);
`install.sh` self-detects either kind of checkout.

Note that piping the raw file is not an option on a private project anyway:
GitLab's `/-/raw/` web route rejects every token authentication method.
The only authenticated raw-file channel is
`/api/v4/projects/:id/repository/files/:path/raw?ref=` with a `PRIVATE-TOKEN` header
(project path and nested file paths must be URL-encoded),
which is the documented CI alternative.

Where practical, publish:

```text
install.sh
install.sh.sha256
```

and provide a more security-conscious installation variant:

```bash
curl -O <versioned-install-script>
curl -O <checksum>
sha256sum -c install.sh.sha256
./install.sh   # run directly or with bash — /bin/sh may be dash, which rejects pipefail
```

The convenient `curl | sh` flow may still be available for trusted internal networks.

Do not embed:

- Personal access tokens
- Usernames/passwords
- Nexus credentials
- GitLab credentials

inside the repository.

Use approved corporate authentication mechanisms instead.

---

# 17. Plugin Installation and Updates

`mise-vault` should itself be installed from the private GitLab repository.

Conceptually:

```text
Private GitLab
     |
     v
mise plugin installation
     |
     v
local mise plugin directory
     |
     +--> backend implementation
     |
     +--> catalog snapshot
```

Plugin updates should be explicit and auditable.

Do not silently track the GitLab `main` branch if doing so makes the local tool catalog nondeterministic.

Prefer released tags:

```text
v1.0.0
v1.1.0
v1.2.0
```

A plugin update then corresponds to adoption of a new approved catalog snapshot.

---

# 18. Tool Onboarding Workflow

The intended lifecycle for adding a tool or version is:

```text
Developer requests tool/version
            |
            v
      OSS intake workflow
            |
            v
     Fetch upstream source
            |
            v
Security / license review
            |
            v
   Private source snapshot
            |
            v
       Trusted build
            |
            v
 Artifact + SHA256 + metadata
            |
            v
      Nexus staging area
            |
            v
 Generate catalog change
            |
            v
       mise-vault MR
            |
       +----+----+
       |         |
       v         v
Schema test   Artifact validation
       |         |
       +----+----+
            |
            v
          Review
            |
            v
          Merge
            |
            v
      Tag new release
```

The catalog MR should represent the explicit transition:

```text
artifact exists
      |
      v
approved for general developer use
```

---

# 19. CI Requirements

Every catalog change must be automatically validated.

## 19.1 Schema Validation

Validate all:

```text
catalog/*/tool.json
catalog/*/versions.json
```

against checked-in JSON schemas.

Unknown fields should preferably be rejected unless intentionally supported.

---

## 19.2 Version Validation

Verify:

- Version strings are valid.
- Version ordering is deterministic.
- Duplicate versions cannot exist.
- Required platforms are present where policy requires them.

---

## 19.3 Artifact Existence

For every catalog entry, verify that the referenced Nexus artifact exists.

A catalog entry must not be mergeable if its artifact is missing.

---

## 19.4 Checksum Verification

Download or otherwise verify the artifact against the catalog SHA-256.

A mismatch must fail CI.

---

## 19.5 Installation Test

Perform a real installation through the backend.

For example:

```bash
mise install vault:golangci-lint@2.4.1
```

Then:

```bash
golangci-lint version
```

The test should confirm that the expected version is executed.

---

## 19.6 Version Discovery Test

Verify:

```bash
mise ls-remote vault:golangci-lint
```

contains exactly the catalog-approved versions.

It must not discover versions from Nexus or public services.

---

## 19.7 Offline Test

Where practical, run integration tests in an environment where public Internet access is unavailable.

The backend must continue to function using only:

```text
Private GitLab
Private Nexus
```

for artifact and go-installed tools.
npm and pypi tools join this gate once their registry configuration
points at Nexus proxy repositories (`npm-proxy`, `pypi-proxy`) with a
warmed cache — still "only Private Nexus" in this test topology, but
worth stating explicitly: the plugin itself does not guarantee that
production points these types at Nexus rather than a real registry,
it only refuses to override wherever the user's environment already
points them (section 14.5).

This should eventually become a required release gate.

---

# 20. Short-Name Backend Routing

One of the most important usability requirements is hiding the backend namespace.

The backend's native identity may initially look like:

```text
vault:go
vault:glab
vault:golangci-lint
```

but developers should ideally use:

```text
go
glab
golangci-lint
```

The bootstrap process must therefore investigate and implement the cleanest supported mise mechanism for centrally mapping:

```text
go            -> vault:go
glab          -> vault:glab
golangci-lint -> vault:golangci-lint
ripgrep       -> vault:ripgrep
ruff          -> vault:ruff
```

This is especially important for tools such as `go`, which already have a mise core backend.

The design should prefer:

```bash
mise use go@1.26.0
```

over:

```bash
mise use vault:go@1.26.0
```

and should preserve compatibility with existing `.tool-versions` where feasible.

This integration point must be investigated early during the proof of concept rather than assumed.

---

# 21. Configuration Layering

Company infrastructure details must not be copied into every application repository.

The intended layering is:

```text
Bootstrap / machine-level configuration
        |
        +--> Install private backend
        +--> Configure short-name routing
        +--> Configure internal policy
        |
        v
Application repository
        |
        +--> Tool name
        +--> Required version
```

Application repository:

```toml
[tools]
go = "1.26.0"
golangci-lint = "2.4.1"
```

Not:

```toml
[tools."http:company-go"]
version = "1.26.0"
url = "https://nexus..."
version_list_url = "..."
```

Distribution policy is an infrastructure concern, not an application concern.

---

# 22. `.tool-versions` Compatibility

Existing repositories may contain:

```text
golang 1.26.0
golangci-lint 2.4.1
glab 1.80.0
```

The project should investigate whether bootstrap-level aliases/backend routing can preserve these files without modification.

Migration should ideally support:

```text
Old developer:
asdf + .tool-versions

New developer:
mise + mise-vault + same .tool-versions
```

This would allow gradual migration from asdf without immediately modifying every repository.

If `golang` versus `go` naming creates compatibility issues, document and centralize the mapping instead of requiring every repository to solve it independently.

---

# 23. Catalog as Security Boundary

The catalog is not merely installation metadata.

It is also the machine-readable company allowlist.

Therefore:

```text
Nexus
```

answers:

> Which artifacts physically exist?

while:

```text
mise-vault catalog
```

answers:

> Which artifacts may developers install?

These responsibilities must not be conflated.

The backend must never derive approved versions by enumerating Nexus.

---

# 24. Failure Behavior

Failure should be explicit and fail closed.

Examples:

## Unknown tool

```text
error: tool 'foo' is not available in the company tool catalog
```

## Unknown version

```text
error: golangci-lint 2.5.0 is not an approved version
```

## Unsupported platform

```text
error: golangci-lint 2.4.1 is not available for linux-arm64
```

## Artifact unavailable

```text
error: approved Nexus artifact is unavailable
```

## Checksum mismatch

```text
error: SHA-256 verification failed
```

None of these errors should trigger a public fallback.

---

# 25. Caching

mise and the backend may cache:

- Downloaded artifacts
- Extracted installations
- Parsed catalog information

However, the source of truth remains:

```text
installed mise-vault release
+
its checked-in catalog
```

A cache must never introduce versions not present in the active catalog.

---

# 26. Authentication

Authentication should remain external to tool metadata.

Possible enterprise mechanisms include:

- Existing Git credential helpers
- Corporate SSO
- GitLab read/deploy credentials
- Nexus machine credentials
- Network-level read-only access

Catalog files must not contain credentials.

Artifact URLs should look like:

```text
https://nexus.company.example/repository/devtools/...
```

not:

```text
https://user:password@nexus.company.example/...
```

---

# 27. Nexus Permissions

A reasonable model is:

```text
OSS Intake / Build CI
    write staging artifacts

Release Pipeline
    promote/write approved artifacts

Developers
    read approved artifacts

Public network
    no access
```

The backend only requires read access.

---

# 28. Release Model

A normal `mise-vault` release may consist only of catalog changes.

For example:

```text
v1.5.0
  Add golangci-lint 2.4.1
  Add glab 1.80.0

v1.5.1
  Fix glab archive metadata

v1.6.0
  Add Go 1.27.0
  Add ripgrep 15.0.0
```

Semantic versioning may be used for plugin releases, but catalog additions should not necessarily be considered breaking API changes.

Define release semantics during implementation.

---

# 29. Initial Proof of Concept

Start with three representative tools:

## Go

Tests:

- Full runtime distribution.
- Environment setup.
- Core mise tool-name collision.
- Existing `.tool-versions` compatibility.

## golangci-lint

Tests:

- Typical Go-based CLI.
- Archive extraction.
- Nested executable path.
- Multiple versions.
- Checksum validation.

## ripgrep or glab

Tests:

- Another normal prebuilt CLI.
- Different archive naming convention.
- Demonstrates that backend logic is language-independent.

A successful PoC should demonstrate:

```bash
mise ls-remote go
mise install go@<approved-version>

mise ls-remote golangci-lint
mise install golangci-lint@<approved-version>

mise ls-remote glab
mise install glab@<approved-version>
```

with public Internet connectivity disabled.

---

# 30. PoC Success Criteria

The project is ready to proceed beyond PoC when all of the following are true:

- mise can install the backend from private GitLab.
- The plugin can read its catalog directly from its own checkout.
- `mise ls-remote` lists only catalog-approved versions.
- Tool artifacts come only from private Nexus.
- SHA-256 verification is mandatory.
- Go can be installed as a complete runtime distribution.
- Normal CLI archives can be installed.
- Public Internet access can be completely disabled.
- No public fallback occurs.
- Bootstrap installation is idempotent.
- Short-name routing works or a well-defined limitation is documented.
- Existing `.tool-versions` compatibility is understood.
- CI validates catalog metadata and artifacts.
- Adding a tool version requires only a small, reviewable catalog change.

This list describes the original PoC's three tools (go, golangci-lint,
glab), all artifact or go-installed — "Tool artifacts come only from
private Nexus", "SHA-256 verification is mandatory", "Public Internet
access can be completely disabled", and "No public fallback occurs"
hold exactly as written for those types, unchanged.
npm and pypi tool types (section 14.5, Phase A, landed after this PoC)
carry a different, later-documented network model:
they are version-pin-only (no checksum field exists for them) and they
install through the user's own ecosystem registry configuration rather
than only from Nexus, so "Public Internet access can be completely
disabled" for them depends on where that registry points, and "no
public fallback" means no SILENT fallback to a different registry than
the one the user configured — not that no ecosystem registry is ever
reached.
See section 14.5 for the full rationale.

---

# 31. Important Design Principles

## Keep the Backend Thin

The backend should primarily perform:

```text
tool/version
    |
    v
catalog lookup
    |
    v
platform resolution
    |
    v
Nexus artifact
    |
    v
verification
    |
    v
installation
```

Do not move OSS intake, vulnerability scanning, or build responsibilities into the plugin.

---

## Prefer Data Over Tool-Specific Code

Adding a normal CLI should require:

```text
catalog/<tool>/tool.json
catalog/<tool>/versions.json
```

not:

```text
lib/install_glab.lua
lib/install_ripgrep.lua
lib/install_ruff.lua
...
```

Tool-specific code should be exceptional.

---

## Fail Closed

If the catalog does not explicitly approve an operation, reject it.

Do not attempt to be helpful by discovering an upstream alternative.

---

## Keep Infrastructure Hidden from Projects

Projects should express:

```text
tool + version
```

not:

```text
backend + URL + archive format + version endpoint + mirror policy
```

---

## Treat Version Discovery as Approval Discovery

`mise ls-remote` should never mean:

> What versions exist upstream?

or:

> What files happen to exist in Nexus?

It should mean:

> What versions has the company approved for this tool?

---

# 32. Future Extensions

After the base architecture is proven, potential extensions include:

### Deprecation Metadata

```json
{
  "1.24.0": {
    "status": "deprecated"
  }
}
```

### Security Revocation

An approved version could later be marked:

```text
revoked
```

and blocked from new installation.

Consider carefully how this interacts with reproducibility.

### Aliases

Support centrally defined aliases such as:

```text
stable
current
legacy
```

provided their semantics remain deterministic enough for enterprise use.

### SBOM and Provenance Links

Catalog entries may expose audit metadata without requiring it during normal installation.

### Internal Signing

Move beyond SHA-256 to company-signed artifact manifests.

### Catalog Generation

The OSS intake pipeline could automatically generate a proposed catalog MR after a successful build.

### Tool Search

If the catalog becomes large, support an internal command or metadata interface for discovering available approved tools.

### Catalog Service

A remote metadata service may eventually become appropriate if the catalog grows very large.

Do not introduce one prematurely.

---

# 33. Open Questions for the Initial Design Phase

The implementation phase should answer these questions before committing to a stable architecture:

1. What is the cleanest currently supported mise mechanism for mapping short names such as `go` to `mise-vault` backend tools?

2. Can that mapping be installed centrally by `install.sh` without requiring modifications to every repository?

3. How should the existing asdf name `golang` map to the mise-facing name `go`?

4. Can `.tool-versions` remain unchanged for repositories currently using asdf?

5. How should the plugin itself be pinned to an immutable GitLab tag?

6. What is the cleanest mise API for checksum verification and archive extraction?

7. What environment data is available to the backend for OS and architecture normalization?

8. What is the correct backend lifecycle for full runtime distributions such as Go?

9. Can `mise outdated` operate entirely from `BackendListVersions` without accessing public metadata?

10. What exact behavior occurs if a built-in mise core tool such as `go` has the same short name as a private backend tool?

11. How should plugin/catalog updates be distributed without silently changing the approved tool universe?

12. Should bootstrap install a machine-level mise configuration, user-level configuration, environment variables, or some combination?

These questions should be answered experimentally with the current mise release rather than assumed from older plugin mechanisms.

---

# 34. Suggested Implementation Strategy

## Phase 1 — Backend Skeleton

Implement:

```text
metadata.lua
BackendListVersions
BackendInstall
BackendExecEnv
```

with one hardcoded test tool.

Confirm private GitLab installation.

---

## Phase 2 — Catalog Abstraction

Implement:

```text
catalog/<tool>/tool.json
catalog/<tool>/versions.json
```

with schema validation and generic lookup logic.

No tool-specific installation code unless unavoidable.

---

## Phase 3 — Nexus Integration

Implement:

```text
URL construction
download
SHA-256 verification
archive extraction
```

Test entirely against private Nexus.

---

## Phase 4 — Representative Tools

Add:

```text
golangci-lint
glab
go
```

Cover:

- single CLI archive
- differing archive layouts
- runtime distribution

---

## Phase 5 — Short-Name Routing

Solve:

```text
vault:go
      ->
go
```

and equivalent mappings.

Verify `.tool-versions` compatibility.

Treat this as a required usability feature, not cosmetic polish.

---

## Phase 6 — Bootstrap

Create a versioned, idempotent:

```text
install.sh
```

that installs everything needed for a developer workstation.

---

## Phase 7 — CI and Offline Validation

Add:

- JSON schema validation
- artifact existence checks
- checksum verification
- real installation tests
- version-discovery tests
- private-network/offline tests

---

# 35. Expected Final Developer Experience

A new developer should need approximately:

```bash
git clone -q --depth 1 -b v1.0.0 \
  https://gitlab.company.example/devtools/mise-vault.git /tmp/mise-vault-bootstrap
/tmp/mise-vault-bootstrap/install.sh
```

Then:

```bash
git clone <application>
cd <application>

mise install
```

If the repository contains:

```toml
[tools]
go = "1.26.0"
golangci-lint = "2.4.1"
```

the developer should not need to know how those tools reach the machine.

The resulting resolution should be:

```text
repo
 |
 | "go 1.26.0"
 v
mise
 |
 v
mise-vault
 |
 +--> approved catalog
 |
 | go / 1.26.0 / linux-amd64
 v
Private Nexus
 |
 | SHA-256 verified artifact
 v
mise installation directory
 |
 v
go
```

---

# 36. Core Project Principle

The project should enforce a clean division of responsibility:

> **Repositories declare what they need.**

> **mise decides when the tool is needed.**

> **mise-vault decides which versions are approved and how to install them.**

> **Private Nexus stores the approved immutable artifacts.**

> **Private GitLab stores the reviewed source, backend implementation, and approval catalog.**

The result should feel to developers like ordinary mise usage while enforcing a completely private, centrally governed software supply chain underneath.