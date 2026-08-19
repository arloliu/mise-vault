# mise-vault — Research Synthesis & Experiment Report

Date: 2026-08-18.
Consolidates three research documents
plus live empirical results from the Docker experiment environment in `experiment/`:

- [mise-backend-plugin-mechanics.md](mise-backend-plugin-mechanics.md)
  — verified against **mise v2026.8.8** (docs + pinned-commit source + local CLI)
- [gitlab-simulation-and-auth.md](gitlab-simulation-and-auth.md)
  — GitLab/git/netrc auth mechanics + local simulation options
- [nexus-docker-experiment.md](nexus-docker-experiment.md)
  — Nexus 3 CE in Docker (**read its addendum**: several body claims were empirically refuted)

Design proposal under review: `tmp/mise-vault-design-proposal.md`.

---

## 1. Verdict on the design proposal

**The architecture is viable as designed.**
Every load-bearing assumption in the proposal checks out against mise v2026.8.8,
with two significant caveats that must reshape parts of the design:

1. **Authentication is the hidden fourth component.**
   The proposal (§26) defers auth to "approved corporate mechanisms",
   but *none of the standard mechanisms reach the two code paths mise-vault actually uses by default*:
   - `mise plugin install <git-url>` clones via **gix + reqwest** (pure Rust), not the git CLI
     — `~/.netrc`, credential helpers, and `insteadOf` do **not** apply
     unless bootstrap sets `gix = false` and `libgit2 = false`
     (both must be false; the branch is an OR).
   - The Lua `http` module inside plugin hooks is a separate reqwest client
     with **no netrc wiring at all**
     — the plugin must read a token itself (e.g. `os.getenv("MISE_VAULT_TOKEN")`)
     and set headers explicitly.
2. **There is no checksum primitive in the Lua plugin API.**
   `archiver.decompress` handles tar.gz/tar.xz/tar.bz2/zip natively,
   but SHA-256 verification — which the proposal makes mandatory (§12) — must be hand-built:
   shell out via `cmd.exec("sha256sum ...")`
   or route installs through mise's own `http:` backend machinery (see §4 below).

Neither caveat blocks the design;
both must be decided explicitly rather than discovered during implementation.

---

## 2. Answers to the proposal's open questions (§33)

| # | Question | Answer | Confidence |
|---|---|---|---|
| 1 | Cleanest short-name mapping mechanism | `[tool_alias]` section (renamed from `[alias]`): `go = "vault:go"`. Redirects the *backend*, not just the version. Works for installed `plugin:tool` backends. | **Proven** — empirically verified end-to-end on v2026.8.8 |
| 2 | Central install without touching repos | Yes. `[tool_alias]` in `/etc/mise/config.toml` (machine) or `~/.config/mise/config.toml` (user) merges into the global alias map; zero per-repo changes. `install.sh` can write either. | **Proven** empirically |
| 3 | asdf `golang` → `go` | Hardcoded in mise (`unalias_backend`: golang→go, nodejs→node, dotnet-core→dotnet). Runs *before* alias lookup, so aliasing `go` covers `golang` automatically. Not configurable — alias the post-fold name. | **Proven** (source + unit test + empirical) |
| 4 | `.tool-versions` unchanged | Yes. Chain verified live: `.tool-versions` `golang 1.21.0` + global `[tool_alias] go = "<backend>"` → resolves to the aliased backend with the requested version. | **Proven** empirically |
| 5 | Pinning the plugin to an immutable tag | `mise plugin install vault <url>#<tag-or-sha>`. Also declarable in `[plugins]` config section with `#ref` (affects new installs only — not a lockfile). Plugin auto-update is a **documented no-op** in v2026.8.8; updates are explicit `mise plugin update`. | High (docs + source) |
| 6 | Checksum / extraction API | Extraction: built-in `archiver.decompress` (tar.gz, tar.xz, tar.bz2, zip; `strip_components` supported). Checksum: **absent** — plugin must `cmd.exec("sha256sum")` or equivalent. | High (source-verified absence) |
| 7 | OS/arch info in hooks | `RUNTIME.osType` ∈ `linux/darwin/windows`, `RUNTIME.archType` ∈ `amd64/arm64` (Rust consts remapped). **Exactly matches the proposal's §13 canonical vocabulary** — platform normalization is nearly free. `RUNTIME.envType` gives `gnu`/`musl` on Linux (may be nil). `RUNTIME.pluginDirPath` = plugin's own checkout (how the plugin reads its bundled catalog). | High |
| 8 | Runtime distributions (Go) | `BackendExecEnv` returns `{env_vars = {{key="PATH", value=install_path.."/bin"}, {key="GOROOT", value=install_path}}}`. mise treats `PATH` specially (merged as bin dirs, not literal override); other keys pass through literally. Mechanism confirmed in source; **no public backend plugin does this yet** — PoC must prove it. | Medium — needs PoC |
| 9 | `mise outdated` / `ls-remote` offline | For backend plugins, both are sourced **100% from `BackendListVersions`** — no public registry or versions-host consulted (source-verified; the versions-host layer is explicitly inert for backend plugins). | High |
| 10 | Collision with core `go` backend | Alias wins. `go` goes through the same resolution pipeline as any name; core backend is not special-cased or protected. Verified live with `go` itself as the shadowed name. | **Proven** empirically |
| 11 | Update distribution | Pin `#vX.Y.Z` at install; ship updates as new tags; `mise plugin update` (or reinstall with new ref) is the only update path today. No staged-rollout precedent exists — an org-level process to design. | High mechanics / open process |
| 12 | Machine vs user config | Full hierarchy documented: `/etc/mise/config.toml` < `~/.config/mise/config.toml` < project files. `[tool_alias]` merges across all layers. Recommendation: system file for fleet defaults; user file acceptable for opt-in rollout. `paranoid` is global-only if used. | High |

**Two settings hygiene notes for the bootstrap** (proposal §21):

- `disable_default_registry` only disables `vfox`/`asdf` short-name mappings — **not** aqua/github/core.
  Do not rely on it as a blanket "private-only" switch.
- `MISE_OFFLINE`/`offline=true` gates mise's own Rust HTTP layer,
  **not** the plugin's Lua `http` calls.
  Fail-closed (§24/§31) must be enforced by the plugin constructing *only* Nexus URLs
  — there is no runtime sandbox to lean on.

---

## 3. Authentication: the decision that shapes everything

Empirically verified against the live experiment stack
(GitLab CE @ localhost:8929, Nexus CE @ localhost:8081):

| Path | Mechanism | netrc? | Verified |
|---|---|---|---|
| `git clone` (real git CLI) | libcurl sets `CURL_NETRC_OPTIONAL` unconditionally | ✅ automatic | ✅ live: private clone succeeded with netrc only |
| `mise plugin install` (default gix) | gix + reqwest, no libcurl | ❌ | source-verified; live test pending PoC |
| `mise plugin install` (`gix=false, libgit2=false`) | shells out to real git | ✅ | mechanism = row 1 |
| GitLab `/-/raw/<ref>/<path>` | **CORRECTED: no token auth works** — basic/netrc, `PRIVATE-TOKEN` header, and `?private_token=` all 302 to sign-in (earlier "pass" was a 302-empty-body false positive; re-probed with status codes) | ❌ | ✅ live re-probe with `-w %{http_code}` |
| GitLab `/api/v4/.../raw` | `PRIVATE-TOKEN` header only; rejects Basic auth (404 on this instance) | ❌ | ✅ live: header 200, netrc 404 |
| Nexus `/repository/<repo>/<path>` | HTTP Basic (CE has no user tokens — Pro only) | ✅ with `curl -n` / any Basic-auth client | ✅ live: developer read ok, anonymous rejected, write denied |
| Lua `http.download_file` in plugin hook | explicit `headers` table only | ❌ never | source-verified (vfox Go module); live test = PoC item |

**Consequences for the design:**

1. **CORRECTED (see §11):** the `curl .../-/raw/... | sh` bootstrap of proposal §15 is NOT viable
   against a private project — no token auth reaches the `/-/raw/` web route.
   Bootstrap goes through git instead (netrc works there):
   `git clone --depth 1 -b vX.Y.Z <repo> /tmp/b && /tmp/b/install.sh`;
   CI alternative: the `/api/v4/.../repository/files/install.sh/raw` endpoint with a `PRIVATE-TOKEN` header.
2. Bootstrap should write `gix = false` and `libgit2 = false` into the machine/user mise config
   so plugin install/update rides the standard git credential chain
   (netrc / credential helper / SSO helpers).
   Otherwise the org is betting on gix's younger credential path.
3. For Nexus artifact downloads inside `BackendInstall`, pick one:
   - **(a) Plugin-managed token**:
     plugin reads `MISE_VAULT_NEXUS_TOKEN` (or tool options)
     and sets Basic/Bearer headers on `http.download_file`.
     Works everywhere,
     but token provisioning becomes part of bootstrap.
   - **(b) Anonymous read + network ACL**:
     Nexus allows anonymous read;
     the private network boundary is the control.
     Simplest plugin code;
     acceptable where the network truly is the perimeter
     (proposal §27 already models "Developers: read approved artifacts").
   - **(c) `cmd.exec("curl -n ...")`**:
     rides netrc but shells out;
     least clean.
4. **netrc port gotcha** (verified live):
   `machine` entries match hostname only
   — `machine localhost` sent GitLab credentials to Nexus on another port.
   In production GitLab and Nexus have distinct hostnames so this vanishes,
   but the *experiment* should mimic that
   (add `gitlab.local` / `nexus.local` to `/etc/hosts`)
   before doing serious netrc testing.

---

## 4. Architecture alternative worth one PoC day: `[tool_alias]` + `http:` backend, zero Lua

The research surfaced a middle path the proposal doesn't consider.
`[tool_alias]` values accept bracketed options
(source-verified: `split_bracketed_opts` runs on alias values),
so a machine-level config could declare:

```toml
[tool_alias]
golangci-lint = 'http:golangci-lint[url=https://nexus.../devtools/golangci-lint/{{version}}/golangci-lint-{{version}}-linux-{{arch()}}.tar.gz,checksum_url=...,version_list_url=https://gitlab.../-/raw/vX/catalog/golangci-lint/versions.txt]'
```

| | A: Lua backend plugin (proposal) | B: alias + `http:` backend |
|---|---|---|
| Checksum verification | hand-rolled (`cmd.exec sha256sum`) | **built-in** (`checksum_url`/`checksum_expr`, lockfile support) |
| Download auth | explicit headers in Lua | mise's Rust client — **honors netrc** |
| Version discovery | catalog files in plugin checkout (fully offline) | `version_list_url` fetch (needs reachable endpoint + auth) |
| Catalog update | new plugin tag (atomic, auditable — proposal §17/§28) | regenerate machine config (bootstrap-managed; atomicity weaker) |
| Runtime tools (Go/GOROOT) | `BackendExecEnv` — flexible | limited; no per-tool env var story |
| Complexity | Lua code + tests | pure data |

**Assessment:**
B is not a full replacement
(weak on runtime distributions and catalog-as-release semantics,
and it was never exercised end-to-end — flagged as unverified),
but it could carry the "simple archive CLI" tool class
with *better* security properties than hand-rolled Lua.
A hybrid is plausible:
backend plugin for runtimes (`go`),
`http:` aliases generated *from the same catalog* for plain CLIs.
Decide after Phase-1 PoC data;
do not commit now.

---

## 5. Experiment environment — built, provisioned, verified

`experiment/` (see its README for credentials):

```
docker compose up -d
scripts/provision-nexus.sh     # idempotent — verified by re-run
scripts/provision-gitlab.sh    # idempotent
scripts/seed-artifacts.sh      # public internet used here ONLY (simulates trusted build output)
```

| Component | Status | Verified behaviors |
|---|---|---|
| Nexus 3 CE (`mv-nexus`, :8081) | ✅ healthy, provisioned | EULA via REST; raw hosted `devtools` (ALLOW_ONCE = immutable); anonymous read **disabled**; `developer` read-only user: download+sha256 ✓, write denied ✓, anonymous denied ✓ |
| GitLab CE (`mv-gitlab`, :8929) | ✅ healthy, provisioned | private `devtools/mise-vault` project; root PAT + `developer` Reporter PAT seeded via `gitlab-rails runner`; anonymous clone denied ✓; `oauth2:<PAT>@` clone ✓; netrc-only clone ✓; `/-/raw/` Basic-auth + PRIVATE-TOKEN ✓ |
| Seeded artifacts | ✅ | go 1.26.6 / 1.25.13 (sha256 cross-checked against go.dev), golangci-lint 2.12.2 / 2.12.1, glab 1.113.0 — layout exactly per proposal §10; manifest in `experiment/artifacts.manifest` |

Gotchas hit and fixed (now encoded in the scripts):

- **Nexus CE EULA**:
  writes 403 until `POST /service/rest/v1/system/eula` acceptance (CE ≥3.77).
- **GitLab password policy**:
  `initial_root_password` rejecting "commonly used word combinations" fails the *entire first boot*
  (rails migration dies, container exits).
  Use a strong random-looking password;
  wipe volumes before retry.
- Nexus research doc's claims
  that password-change/anonymous-access lack REST APIs
  were **wrong** — see the addendum in that doc.

The seeded tool set intentionally covers the proposal's three PoC classes (§29):
runtime distribution (go),
multi-version archive (golangci-lint),
different naming convention (glab uses `glab_1.113.0_linux_amd64`, underscores).

---

## 6. Recommended PoC test matrix (next step)

Ordered by information value;
items 1–3 are the highest-risk unknowns:

1. **Skeleton backend plugin**
   (metadata.lua + 3 hooks, catalog for golangci-lint)
   pushed to the local GitLab;
   `mise plugin install vault http://localhost:8929/devtools/mise-vault.git#v0.0.1`
   under both git paths (default gix vs `gix=false`+netrc).
   Then `mise ls-remote vault:golangci-lint`
   and `mise install vault:golangci-lint@2.12.2` against local Nexus.
2. **Short-name chain with auto-install question**:
   on a machine state where the `vault` plugin is *not yet installed*,
   does `[tool_alias] go = "vault:go"` + `mise install go@1.26.6` auto-install the plugin,
   or error?
   (Determines whether bootstrap must always pre-install the plugin — probably should regardless.)
3. **Go as runtime distribution**:
   `BackendExecEnv` returning PATH+GOROOT;
   verify `go version`, `go env GOROOT`, shims,
   and `.tool-versions` with `golang 1.26.6`.
4. **Fail-closed matrix** (proposal §24):
   unknown tool, unapproved version, missing platform,
   corrupted artifact (flip a byte in Nexus copy → sha mismatch must abort),
   Nexus down.
5. **Offline test**:
   `docker network disconnect`-style isolation or firewall the workstation namespace;
   confirm ls-remote/install work with only the two containers reachable,
   and that `MISE_OFFLINE` semantics behave as documented
   (Lua http not gated — verify empirically).
6. **Architecture B probe**:
   one `[tool_alias] ... http:...[...]` entry for glab
   against Nexus with netrc + checksum_url;
   measure how much of §4's promise holds.
7. **Auth variants for Nexus download inside the hook**:
   explicit header from env token vs anonymous-read mode.

Supporting environment improvement before 5/6:
add `gitlab.local` / `nexus.local` `/etc/hosts` entries
and switch provision scripts' URLs,
so netrc entries are per-service.

---

## 7. Design deltas to fold back into the proposal

1. **§15 Bootstrap** must additionally:
   set `gix=false`/`libgit2=false` (or consciously accept gix),
   write `[tool_alias]` for every catalog tool,
   pre-install the plugin pinned to a tag,
   and (if token-based Nexus auth is chosen) provision the workstation token.
   Bootstrap also documents `curl -fsSLn` (netrc) as the authenticated fetch form.
2. **§12 Installation flow**:
   add an explicit "checksum implementation" decision
   — `cmd.exec sha256sum`
   (adds a host dependency: present on Linux, `shasum -a 256` on macOS)
   since no Lua hash module exists.
3. **§24 Fail-closed**:
   note that enforcement is by construction
   (plugin only ever builds Nexus URLs),
   not by any mise sandbox/offline setting.
4. **§26 Authentication**:
   name the three viable Nexus-download auth models
   (token-in-env / anonymous+network-ACL / cmd curl -n)
   and pick one;
   note CE has no user tokens (Pro feature),
   so "Nexus machine credentials" means Basic auth user/password in CE.
5. **§32 Future — signing/attestation**:
   backend plugins currently get **no** attestation verification
   (tool-plugin/aqua-only feature),
   and `locked_verify_provenance` has nothing to verify for them
   — internal signing would be entirely plugin-implemented.
6. **New section: catalog→`[tool_alias]` generation.**
   Whichever architecture wins,
   the alias block is derived data from the catalog;
   bootstrap (and later config-refresh) should generate it,
   never hand-maintain it.

---

## 8. Decisions from design discussion (2026-08-18)

| # | Decision | Rationale |
|---|---|---|
| D1 | **Bootstrap writes user-scoped mise config with `gix = false`, `libgit2 = false`.** Plugin install/update stays on `mise plugin install vault <url>#<tag>`. | Runtime setting, no recompile; system git rides the standard credential chain (netrc / credential helpers). Cleaner than having install.sh clone+link the plugin itself. |
| D2 | **Artifact download + checksum via `cmd.exec`: `curl -n` + `sha256sum`** (macOS fallback `shasum -a 256`). Lua `http` module not used for authenticated downloads. | Checksum already forces a shell-out, so coreutils is assumed anyway; adding curl is near-zero cost and gets netrc for free. Prerequisites documented in README/bootstrap check. |
| D3 | **Architecture A (Lua backend plugin) selected; B (`http:` alias) rejected as primary.** | B forces a choice between determinism (pin catalog tag in every URL → config churn per release) and freshness (floating URL → breaks §2.4 reproducibility). A absorbs the high-frequency event (new versions) into plugin updates; machine config changes only on the rare new-tool event. |
| D4 | Aliases live in a **generated file** (`~/.config/mise/conf.d/mise-vault.toml`), never hand-edited. | Regenerated from the plugin catalog by bootstrap/update tooling. |

Resolved by [plugin-hooks-and-config-channels.md](plugin-hooks-and-config-channels.md):

| # | Decision | Rationale |
|---|---|---|
| D5 | **Alias regeneration = explicit `mise run vault-sync` task, shipped inside the generated conf.d file.** Optional warn-only staleness check in `BackendListVersions`. | No automatic trigger exists: mise's hook enum is a closed 5-member set (enter/leave/cd/preinstall/postinstall) firing on tool-version installs, never on `mise plugins install/update` (source-verified). Backend plugins are hard-gated to exactly their three Backend* hooks — no PostInstall/MiseEnv available. A task inside the conf.d file needs no extra install surface and shares its script with bootstrap. |
| D6 | **Nexus URL precedence: `[tools]`-table / inline opts > `[tool_alias]` bracketed opt (generated conf.d default) > plugin-repo default file.** Env-var override is NOT a supported path for now. | Bracketed alias opts confirmed end-to-end into `ctx.options` (`split_bracketed_opts` → `get_backend_alias_opts` → `resolve_tool_opts_with_overrides`), with `[tools]`/CLI opts correctly overriding. Surprise finding: Lua `os.getenv()` reads a mise-constructed `mise_env` registry table, not the raw process env — `[env]` and shell exports do not reliably reach hooks (source-derived; PoC should confirm). |

---

## 9. PoC results (2026-08-18) — 20/20 passed

Skeleton plugin implemented and pushed to the local GitLab
(`devtools/mise-vault`, tags `v0.0.1` / `v0.0.2`);
full matrix in `experiment/scripts/poc-test.sh`,
run in an isolated `$HOME` against the experiment stack.
Loopback trick: Nexus addressed as `127.0.0.2`, GitLab as `127.0.0.3`,
so `~/.netrc` machine entries stay per-service without `/etc/hosts` changes.

Every previously flagged unknown now has an empirical answer:

| Risk / unknown | Result |
|---|---|
| gix vs git CLI auth (Key Risk #1 of gitlab research) | ✅ `gix=false` + netrc: `mise plugin install vault <url>#v0.0.1` clones a private repo with no token in the URL |
| GOROOT-style runtime backend plugin (no public precedent) | ✅ `go version` → go1.26.6; `GOROOT` exported and valid; `mise exec` PATH correct |
| `cmd.exec` env inheritance (netrc reachability for `curl -n`) | ✅ hooks' `cmd.exec` subprocesses see the real `$HOME`; `curl -n` found the isolated netrc — D2 holds |
| Alias auto-install of missing plugin (mise-mechanics Key Risk #1) | ❌ does **not** auto-install — errors out. Bootstrap MUST pre-install the plugin (was recommended anyway) |
| Short-name chain incl. core-`go` shadowing and `.tool-versions` `golang` | ✅ all through generated conf.d file with bracketed `nexus_url` opts (D4/D6 design validated end-to-end) |
| Fail-closed behaviors (§24) | ✅ unknown tool, unapproved version, and checksum mismatch all abort with explicit errors |
| Catalog update flow | ✅ re-pin `-f <url>#v0.0.2` surfaces the new tool immediately; `smoke` (wrong sha fixture) correctly fails install |

Not yet run:
the offline gate (§19.7 — needs network-namespace isolation; deferred to CI design)
and the darwin/arm64 platform axis (single-platform catalog so far).

Plugin source of record for the PoC lives in the experiment GitLab;
next step is formalizing it into this repository per proposal §7
(schemas, tests, CI, install.sh, vault-sync).

---

## 10. Catalog schema decisions (2026-08-18, second discussion round)

| # | Decision | Rationale |
|---|---|---|
| D7 | **`versions.json` is an ordered ARRAY** (`[{"version": ..., "platforms": {...}}, ...]`), oldest-approved first. The plugin returns catalog order verbatim — no runtime semver sort. CI owns order/duplicate validation. | Tool version schemes vary (semver, go-style, date-based); sorting at generation time with CI validation removes runtime ambiguity. JSON objects lose key order in Lua decode; arrays keep it. MR diffs become pure appends. Re-verified: poc-test 20/20 on tags v0.0.3/v0.0.4. |
| D8 | **Artifact naming stays an explicit per-platform template string** (only `{version}` placeholder), e.g. `"golangci-lint_{version}_x86_64.tar.gz"`. No `{os}`/`{arch}` indirection layer for now. | Arch is never inferred from file names — resolution is one-way: `RUNTIME` → canonical `linux-amd64` key → per-platform entry. Real-world naming is too irregular for clean os/arch substitution (some artifacts omit the os entirely); the per-platform block already exists for `format`/`strip_components`/`bin_paths`; explicit strings make catalog MRs reviewable at a glance. `{arch}` sugar can be added back-compatibly if authoring pain appears. |
| D9 | **Nexus `.sha256sum` sidecar files feed catalog *generation* only, never install-time verification.** Install verifies exclusively against `versions.json`. | Trusting a sidecar next to the artifact is "Nexus verifying Nexus" — a compromised store swaps both files together (§23 security boundary). Generation tooling (`scripts/add-version`) uses sidecars to avoid downloading full tarballs; tools without sidecars (e.g. go) fall back to download+hash or upstream-published values recorded at intake. Sidecar parsing must accept both `<sha>  <filename>` and bare-hash formats. |

---

## 11. Bootstrap & vault-sync results (2026-08-18) — 13/13 passed

`install.sh` + `scripts/vault-sync` implemented and validated end-to-end
(`experiment/scripts/bootstrap-test.sh`, fresh isolated `$HOME`, netrc only):
prerequisites check → `gix=false`/`libgit2=false` via `mise settings` →
plugin pinned install → conf.d generation → smoke test;
re-run idempotent; `mise run vault-sync` works as a **global task** from any directory,
including the `vault-sync <ref>` form that re-pins the plugin and regenerates from the new checkout.

| # | Decision / correction | Detail |
|---|---|---|
| D10 | **Bootstrap is git-based, not `curl \| sh`.** | Empirical: GitLab's `/-/raw/` web route accepts NO token auth on private projects — basic/netrc, `PRIVATE-TOKEN` header, and `?private_token=` all 302 to sign-in. The earlier "basic auth works on `/-/raw/`" finding was a 302-empty-body false positive (probe lacked `-w %{http_code}`). Documented flow: `git clone --depth 1 -b vX.Y.Z <repo> /tmp/mise-vault-bootstrap && /tmp/mise-vault-bootstrap/install.sh`. CI alternative: `/api/v4/.../repository/files/install.sh/raw?ref=` + `PRIVATE-TOKEN` header (verified 200). Proposal §15/§16 must be amended. |
| — | **`install.sh` must be executed, not `sh`-piped.** | `sh` is dash on Debian/Ubuntu and rejects `set -o pipefail`. The script is bash; run it directly (executable bit) or via `bash`. |
| — | **Missing alias file = silent public fallback.** | Observed live: before the conf.d file existed, `mise ls-remote golangci-lint` served the FULL upstream list from mise's default registry, and `glab` resolved to `gitlab:gitlab-org/cli` (contacting gitlab.com). The generated alias file IS the private routing; tests now assert `mise tool <t>` reports `vault:<t>`. Production hardening for the §19.7 offline gate must treat "alias file absent/stale" as a failure mode, and network-level isolation remains the real §2.1 guarantee. |

---

## 12. Production policy decisions (2026-08-18, third discussion round)

| # | Decision | Status |
|---|---|---|
| D11 | **Public fallback is fully blocked by policy.** Short names not covered by the generated alias file must not reach mise's public registry. Bootstrap will additionally set the relevant disable settings (`disable_default_registry`, `disable_backends` — exact list to be finalized empirically, since these settings do not cover every backend type), and network-level isolation remains the hard guarantee. | Decided; implementation lands with the offline-gate work |
| D12 | **install.sh enforces a minimum mise version: 2026.8.1** (user decision: the exact introduction of the binding constraint — the archive extractor's `strip_components` option — without the round-up to 2026.8.8 the research suggested). Every other dependency is months-to-years older; replacing the extractor call with a tar shell-out would lower the floor to 2026.5.2 (tool-alias option passing) if ever needed. Numeric calver comparison implemented and unit-checked. Details: `mise-version-floor.md`. | **Done** (bootstrap-test 18/18) |
| D13 | **Org-wide plugin update/rollback process** — superseded by D18 (no rings; latest-or-tag). Research retained as reference: `plugin-rollout-strategies.md`. | Closed |

---

## 13. Nexus-URL configuration decisions (2026-08-18, grilled with the user)

| # | Decision |
|---|---|
| D14 | The production Nexus base URL is **committed in `config/defaults.json`** — no release-time stamping (would break "tag = deliverable"), no bootstrap-time injection. Single Nexus instance. The URL is not a secret; credentials never appear in URLs. |
| D15 | Generated aliases are **pure routing** (`go = 'vault:go'`), carrying no URL. The runtime URL comes from the installed plugin checkout's `defaults.json`, eliminating the stale-embedded-URL divergence class (e.g. `mise plugin update` run without vault-sync). Per-project `[tools]` options remain the override channel; verified: bootstrap-test 14/14, poc-test 20/20 with both channels covered. |
| D16 | Nexus migration = catalog MR updating `defaults.json` + new tag + fleet `vault-sync`; old pinned releases are covered by a **time-boxed network-layer redirect** from the old hostname, with a runbook requiring all users and CI pins to upgrade before the window closes. |
| D17 | `install.sh` **self-detects** its release tag (`git describe --tags --exact-match` on its own checkout) and repository URL (`git remote get-url origin`) — cloning tag X installs tag X, nothing to bump per release. It refuses branch checkouts without an explicit `MISE_VAULT_REF`. (Found stale hardcoded default `v0.0.5` during review — the failure mode this eliminates.) |

---

## 14. Update-model simplification (2026-08-18, user decision)

| # | Decision |
|---|---|
| D18 | **No ring-based rollout.** Every commit on the default branch IS the current version — the approval boundary is merge request + CI, not tagging. Users update with `mise run vault-sync latest` (default-branch HEAD) or pin with `vault-sync <tag>`; rollback = sync to an older tag or commit. `install.sh` installs exactly what was cloned: a tag on tagged checkouts, the exact commit on branch checkouts, env override for the checkout-less CI path. The ring/canary research (`plugin-rollout-strategies.md`) is retained as reference should fleet size later demand staging; its staleness-nudge and CI-floor ideas remain compatible with this model. Verified: bootstrap-test 16/16. |

---

## 15. Offline gate + public-fallback blocking (2026-08-18) — D11 implemented

Offline gate (`experiment/scripts/offline-test.sh`, 10/10):
a container attached only to an `internal: true` Docker network
(github.com/proxy.golang.org unreachable; only the GitLab and Nexus containers routable)
ran the complete flow — netrc bootstrap, catalog discovery, glab archive install,
go runtime install with sha verification — with zero public internet.

D11 implementation findings (all empirical, mise v2026.8.8):

- `disable_backends` accepts and enforces **every** backend type including `core`
  (`mise ls-remote node` → "none of its backends (core:node) are supported"),
  which is stronger than the earlier research suggested.
- Explicit backend specs are refused too
  (`mise install aqua:jqlang/jq@…` → "backend aqua is disabled by disable_backends").
- Listing `vfox` in `disable_backends` does **not** affect the vault plugin —
  backend plugins are addressed by their own plugin name,
  distinct from the `vfox:` remote backend type.
  Verified: full block list active, `vault:glab` installs and runs.
- `install.sh` now writes `disable_default_registry=true` plus the full
  `disable_backends` list; bootstrap-test asserts both block behaviors (18/18).
- **MISE_OFFLINE=1 does not block the plugin's own downloads**
  (they go through `cmd`-spawned curl, outside mise's HTTP layer) —
  this settles the corresponding open risk from the mechanics research:
  fail-closed is enforced by the plugin constructing only Nexus URLs, as designed.
- Test-harness gotcha: under `set -o pipefail`,
  `mise <failing-cmd> 2>&1 | grep -q <expected-error>` reports failure
  even when grep matches (mise's nonzero exit wins) — capture output first, then grep.

---

## 16. Multi-platform axis (2026-08-18)

Catalog extended to `linux-amd64` + `linux-arm64` + `darwin-arm64`
for all three tools (15 real artifacts seeded, all checksum-verified against Nexus).
The per-platform explicit artifact strings absorbed every naming difference
without code changes — including glab's OS-specific underscore naming —
confirming the no-inference platform model.
The unsupported-platform fail-closed path is now exercised
(fixture tool declaring only `darwin-arm64`, installed via `mise plugins link`
on a linux-amd64 host → "not available for linux-amd64"); poc-test 21/21.
Note: existing pre-release version records were regenerated in place to add platforms;
once the catalog is live, platform additions to an existing version
must instead be a reviewed catalog MR (append-only discipline applies to versions, not platforms —
tooling support for platform addition is future work).

---

## 17. CI pipeline live (2026-08-18)

A `gitlab-runner` container (docker executor, compose network, clone-url override,
`if-not-present` pull policy) now runs the real pipeline on the experiment GitLab:
**all four jobs green** — schema validation with the formal jsonschema engine,
artifact existence, full checksum verification (15 artifacts),
and install-test (links the checkout as the plugin,
asserts `ls-remote` equals the catalog byte-for-byte,
installs the newest golangci-lint through the backend and executes it).

Issues found only by running it for real:

- YAML: `: ` (colon-space) inside an unquoted script line breaks parsing —
  and GitLab reports the pipeline as "failed" with zero jobs and `yaml_errors: null`;
  the actual error only surfaces via the CI lint API.
- The install-test job needs a `~/.netrc` exactly like a workstation does
  (the plugin downloads with `curl -n`); it is generated from masked CI variables,
  with the machine name parsed from the effective Nexus URL.
- `NEXUS_URL` as a CI variable cleanly re-points both the verify scripts (`--nexus-url`)
  and the linked plugin (rewrite of the workspace `config/defaults.json`)
  for networks where Nexus lives under a different address than workstations use.

---

## 18. Env-var override + official plugin-install path (2026-08-19, empirical)

| # | Decision |
|---|---|
| D19 | **`MISE_VAULT_NEXUS_URL` is a supported override channel**, highest precedence: env var > per-tool `nexus_url` option > `config/defaults.json`. The PoC that D6 deferred was finally run (instrumented hooks, isolated `$HOME`, mise 2026.8.8): `os.getenv` in `BackendListVersions` AND `BackendInstall` sees plain shell exports and plain `[env]` entries from a trusted mise.toml — the source-derived "sanitized `mise_env` table" conclusion does not hold empirically (correction recorded in `plugin-hooks-and-config-channels.md`; D6's option-over-default ordering itself is unchanged). The env value passes the same URL-shape validation as every other channel. Covered by poc-test phase 5: env beats the alias option in both failure and success directions, the `[env]`-in-mise.toml channel reaches the hook, and an unsafe value is refused. |
| D20 | **`mise plugin install vault <url>` cannot replace the git-clone bootstrap for first install.** Empirical against the experiment GitLab: with netrc but WITHOUT `gix = false` + `libgit2 = false` it fails ("Failed to obtain credentials" — the built-in gix ignores netrc); embedding the token in the URL also fails over http ("Will not send credentials in clear text over http"), and would persist the token into the plugin's `.git/config` anyway, violating the no-credentials-in-files rule. With the two settings plus netrc it succeeds — but writing those settings, the netrc guidance, blocking public backends, generating aliases, and the mise version floor are exactly what `install.sh` provides, and an alias to an uninstalled plugin does not auto-install it. The official command remains a fine re-pin/update path AFTER bootstrap (poc-test phase 1 exercises it). |
| D21 | **The plugin-install entry path is the documented FIRST bootstrap method** (token-based API fetch second, git clone last). `MISE_GIX=false MISE_LIBGIT2=false mise plugin install vault <url>[#<tag>]` followed by running the cloned checkout's `install.sh` ends in exactly the state the git-clone bootstrap produces — verified in an isolated `$HOME`: settings persisted by install.sh, aliases generated, `mise tool glab` resolves to `vault:glab`, ls-remote equals the catalog, and `mise run vault-sync latest` works afterwards WITHOUT the env vars; the tag-pinned variant (`#v0.0.14`) self-detects the tag. The env vars are recognized settings channels (`mise settings get gix/libgit2` reflects them); they solve the chicken-and-egg of needing the real, netrc-capable git before install.sh has written the persistent settings. This refines D20: plugin install still cannot REPLACE install.sh, but it is now the preferred way to obtain the checkout that runs it. Covered by bootstrap-test phase 7. |

---

## 19. go-installed tools (2026-08-19, user decision + empirical)

A second tool type was added: tools installed by shelling out to
`go install <module>@v<version>` against a go module proxy, instead of
downloading a prebuilt artifact from Nexus. gocensus
(`github.com/arloliu/gocensus/cmd/gocensus`) is the worked example, seeded
with real catalog data: versions 0.2.0 (`h1:otaDYec9RJA0hc9GcuxWxFIdjcuzXy3lviT2BjamQ2E=`)
and 0.4.0 (`h1:bHafz9ZVgCl09jiiOv5Wt3+KrHawciXj00mqqtgJOCc=`), both obtained
from `go mod download -json` against the real `proxy.golang.org`, module
root `github.com/arloliu/gocensus` confirmed by the proxy's own `@v/list`
and `@latest` (the `/cmd/gocensus` suffix does not resolve as its own
module, so it is only a package path within the root).

| # | Decision |
|---|---|
| D22 | **go tools stay vault-routed, exactly like artifact tools.** Aliases remain pure routing (`gocensus = "vault:gocensus"`, no URL); the name-to-module mapping lives in `tool.json`'s `module` field, not in the alias. This keeps the routing story — one alias shape for every tool, whatever it's built from — unbroken by the new tool type. |
| D23 | **The go proxy gets its own env-var/option/default resolution ladder, deliberately separate from the Nexus one:** `MISE_VAULT_GOPROXY_URL` > per-tool `goproxy_url` option > `config/defaults.json`'s `goproxy_url`, same URL-shape validation as `nexus_url`. The plugin always overrides the subprocess's own `GOPROXY`; a developer's personal `GOPROXY` (which could point anywhere, including the public internet) must never leak into a company-tool install. Every `go` subprocess the plugin runs also gets `GOSUMDB=off` (checksum trust is the catalog's own `h1`, never the public sum database) and `GOTOOLCHAIN=local` (stops `go` from downloading a different toolchain on its own initiative, which would be exactly the kind of internet fallback this plugin must never perform). |
| D24 | **Module checksum verification (`h1`) is optional per version — a deliberate, documented exception to "checksum verification is never optional."** When present, the plugin runs `go mod download -json <module_root>@v<version>` before building and aborts on a `Sum` mismatch; when absent, the go proxy is trusted for that version. Justification: the go proxy is company infrastructure the plugin itself addresses (never the public internet, by construction of D23), and the approved-version list in `versions.json` is still the actual gate on what installs — an unlisted version cannot be installed regardless of any checksum. `scripts/add-version` records `h1` automatically whenever a go toolchain is available (`--no-h1` opts out on purpose); `scripts/verify-artifacts --checksum` re-verifies every recorded `h1` the same way. |
| D25 | **Go's own netrc-based module-proxy authentication only ever activates for `https://` proxies — verified empirically by reading the installed toolchain's source** (`cmd/go/internal/web/http.go`: the credential-lookup call is guarded by `url.Scheme == "https"`; `cmd/go/internal/auth/auth.go`'s `AddCredentials` panics if given a non-https request). The experiment Nexus, like the real Nexus this simulates, serves plain `http`, so `go install`/`go mod download` can never authenticate to it the way `curl -n` does. Fix: the experiment's go-proxy repository is carved out as the one anonymously-readable exception, narrowly scoped — the built-in `nx-anonymous` Nexus role grants read on every repository and cannot be edited, so the anonymous user is switched to a purpose-built role (`go-proxy-anon-read`) that grants read/browse on the go-proxy repository only, never the `devtools` artifact repository. This is not a security regression: the go-proxy content is public open-source module code mirrored read-only from `proxy.golang.org`, and D24 already established that the real gate is the approved-version list, not proxy access control. Verified end-to-end against the running experiment stack: anonymous `go mod download -json` and `go install` both succeed through `http://127.0.0.2:8081/repository/go-proxy`, the returned `Sum` matches the catalog's recorded `h1`, and anonymous access to the `devtools` repository still correctly fails — plus the full poc-test matrix (install, `--help` run, `mise tool` backend check, unapproved-version rejection, and an `h1`-mismatch fixture) passes with the plugin's working tree linked in. |
| D26 | **Post-implementation review hardening of the go-install path (2026-08-19).** Three review findings changed the design. (1) *Environment pinning*: setting `GOPROXY` alone is bypassable — `GOPRIVATE` doubles as the `GONOPROXY` default and sends matching modules straight to version control, and an inherited `GOFLAGS` can alter the build — so every go subprocess now pins `GONOPROXY=none`, empty `GOPRIVATE`, an explicit `GOFLAGS`, `GOSUMDB=off`, `GOTOOLCHAIN=local`. (2) *Toolchain approval gate*: the install hook refuses a go toolchain whose reported version is not in `catalog/go/versions.json` — version-string binding only, provenance is out of scope. Implementing this exposed a new empirical fact: mise strips its own managed tool paths from PATH while plugin hooks run (verified against mise v2026.8.8 — inside `BackendInstall`, `go` resolved to the system toolchain even under `mise exec go@… -- mise install …`), so the hook looks up the toolchain in two steps: the PATH `go` if approved, else mise's own install tree (`installs/go/<version>/bin/go`), newest approved version first — which also makes a plain `mise install <go-tool>` work with no PATH preparation. (3) *Nested-module shadowing*: `go install` resolves a package to the longest module path existing at the requested version, so an `h1` recorded for `module_root` would not bind to a nested module that also exists at that version; hook, add-version, and verify-artifacts all probe for and refuse that case. One finding was accepted as a documented limitation instead of fixed: go's module client follows cross-host redirects with no opt-out (unlike the artifact path's `curl --max-redirs 0`), so redirect-refusal for module fetches is impossible — network egress policy remains the enforcement, consistent with the standing rule that network isolation is the only hard guarantee. A fourth round-3 finding hardened the environment further: go trusts cached module content without refetching or rehashing it, so every plugin/tooling go invocation now also pins `GOENV=off`, clears `GOCACHEPROG`, and uses fresh per-operation `GOMODCACHE`/`GOPATH`/`GOCACHE` directories shared by the checksum preflight and the build, with any previous contents removed first (the download directory can survive via `always_keep_download`) — an inherited module cache could otherwise serve tampered source that still reports the catalogued checksum, and an inherited build cache could supply a compiled result never built from the verified source. The offline gate was strengthened to match: `offline-test` now disconnects Nexus from its upstream network for the duration, so a go-proxy cache missing any transitive dependency fails the suite instead of silently refetching. |

---
