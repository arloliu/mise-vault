# mise Backend Plugin Mechanics — Research for mise-vault

Verified against **mise v2026.8.8** (linux-x64, released 2026-08-17 — the current latest release per `gh api repos/jdx/mise/releases/latest`, and the version installed locally).
Research date: **2026-08-18**.

Source citations pin to commit [`33073d5`](https://github.com/jdx/mise/commit/33073d5e26bb82becbb3d248581d2efedf889078) (HEAD of `main` at research time) so line numbers stay valid.
Doc citations link to the live page at `mise.jdx.dev`;
where useful the underlying `docs/*.md` source path is also given at the same commit.

Two plugin systems coexist in mise and are easy to conflate — every section below states explicitly which one it is describing:

- **Backend plugins** (vfox-style, Lua, `hooks/backend_*.lua`, `plugin:tool` format) — the modern, first-class system this research targets.
- **Tool plugins** / **asdf (legacy) plugins** — the older single-tool, hook-based systems (`Available`, `PreInstall`, shell-script `bin/install` for asdf).
  Referenced only for contrast.

---

## 1. Backend plugin API (hooks, context, Lua modules, checksum/archive support)

### Architecture and required hooks

A backend plugin is a git repo (or local dir via `mise link`) written in Lua 5.1, containing `metadata.lua` plus three hook files, one function per file:

- `hooks/backend_list_versions.lua` → `PLUGIN:BackendListVersions(ctx)`
- `hooks/backend_install.lua` → `PLUGIN:BackendInstall(ctx)`
- `hooks/backend_exec_env.lua` → `PLUGIN:BackendExecEnv(ctx)`

([Backend Plugin Development](https://mise.jdx.dev/backend-plugin-development.html), `docs/backend-plugin-development.md:21-25`)

This is confirmed at the Rust implementation level: the hook files exist 1:1 in `crates/vfox/src/hooks/`: [`backend_list_versions.rs`](https://github.com/jdx/mise/blob/33073d5/crates/vfox/src/hooks/backend_list_versions.rs), [`backend_install.rs`](https://github.com/jdx/mise/blob/33073d5/crates/vfox/src/hooks/backend_install.rs), [`backend_exec_env.rs`](https://github.com/jdx/mise/blob/33073d5/crates/vfox/src/hooks/backend_exec_env.rs).
Each Rust hook wrapper does `require "hooks/backend_*"` then calls `PLUGIN:Backend*(ctx)`, matching the doc exactly.

### Context fields per hook (doc + source, cross-verified)

**`BackendListVersions(ctx)`** — struct `BackendListVersionsContext` (`crates/vfox/src/hooks/backend_list_versions.rs:8-11`):

| Field | Type | Description |
|---|---|---|
| `ctx.tool` | string | tool name, e.g. `"prettier"` |
| `ctx.options` | table | tool options from `mise.toml`, TOML types preserved as native Lua (strings stay strings, arrays become Lua sequence tables, nested tables become Lua maps) |

Return: `{versions = {...}}` (`BackendListVersionsResponse`, same file lines 13-14, 42-52).
**Must be ascending / oldest-first**, sorted semantically — mise applies no further sort (`docs/backend-plugin-development.md:47-48`).

**`BackendInstall(ctx)`** — struct `BackendInstallContext` (`crates/vfox/src/hooks/backend_install.rs:8-14`):

| Field | Type | Description |
|---|---|---|
| `ctx.tool` | string | tool name |
| `ctx.version` | string | requested version, e.g. `"3.0.0"` |
| `ctx.install_path` | string | e.g. `/home/user/.local/share/mise/installs/vfox-npm-prettier/3.0.0` |
| `ctx.download_path` | string | e.g. `/home/user/.local/share/mise/downloads/vfox-npm-prettier/3.0.0` |
| `ctx.options` | table | tool options |

Return: `{}` (empty table; `BackendInstallResponse` is a marker — any table is accepted, `crates/vfox/src/hooks/backend_install.rs:53-63`).

**`BackendExecEnv(ctx)`** — struct `BackendExecEnvContext` (`crates/vfox/src/hooks/backend_exec_env.rs:8-13`):

| Field | Type | Description |
|---|---|---|
| `ctx.tool` | string | tool name |
| `ctx.version` | string | version |
| `ctx.install_path` | string | install directory |
| `ctx.options` | table | tool options |

Return: `{env_vars = {{key=..., value=...}, ...}}` — an ordered list of `{key, value}` tables (`EnvKey`, `crates/vfox/src/hooks/env_keys.rs:10-13`, consumed by `BackendExecEnvResponse` in `backend_exec_env.rs:16-17, 32-41`).

(Doc cross-reference for all three: [Backend Plugin Development § Context Variables](https://mise.jdx.dev/backend-plugin-development.html#context-variables), `docs/backend-plugin-development.md:225-259`.)

### Available Lua helper modules

Confirmed both by docs and by the module list actually registered in Rust (`crates/vfox/src/lua_mod/mod.rs:1-22`, `pub use archiver::…, cmd::…, env::…, file::…, html::…, http::…, json::…, log::…, semver::…, strings::…`) — exactly 10 modules, available identically in backend plugins and tool plugins ([Plugin Lua Modules](https://mise.jdx.dev/plugin-lua-modules.html), `docs/plugin-lua-modules.md:5-18`):

`cmd`, `json`, `http`, `file`, `env`, `strings`, `semver`, `html`, `archiver`, `log`.

- **`http`**: `get`, `head`, `download_file`, plus non-raising `try_get`, `try_head`, `try_download_file` variants (the raising forms throw a Lua error on transport failure; `try_*` returns `(nil, err_string)` instead because `pcall()` cannot catch async-function errors in this runtime) (`docs/plugin-lua-modules.md:20-111`).
- **`archiver`**: `archiver.decompress(src, dest[, {strip_components=N}])`.
  Supports **tar.gz, tar.xz, tar.bz2, zip** (`docs/plugin-lua-modules.md:425-459`).
  This is genuine archive-extraction support built into the plugin runtime — a plugin does **not** need to shell out to `tar`/`unzip` for these four formats.
- **`cmd`**: `cmd.exec(command[, {cwd=, env=, timeout=}])` for shelling out when needed (`docs/plugin-lua-modules.md:583-676`).
- **`file`**: `join_path`, `read`, `symlink`, `exists`, `list`, `glob`, `move` (`docs/plugin-lua-modules.md:482-546`).
- **`semver`**: `compare`, `parse`, `sort`, `sort_by` — ascending sort only; plugins reverse the result themselves for hooks that want newest-first (`docs/plugin-lua-modules.md:227-334`).
- **`log`**: `trace/debug/info/warn/error`, routed through Rust's `log` crate and gated by `MISE_DEBUG`/`MISE_TRACE`.
  `print()` is overridden to route through `log.info` (`docs/plugin-lua-modules.md:811-865`).

### Checksum verification: **no built-in Lua module** — plugin must implement it itself

There is **no `checksum`/`hash` module** in the Lua API.
The registered module list in `crates/vfox/src/lua_mod/mod.rs` is exhaustive (11 `mod` declarations, 10 exported to Lua — `hooks` is internal) and contains no checksum/hash primitive.
The docs' own "Download with verification" example says outright:

> "Note: SHA256 verification would need additional implementation — This is a simplified example" (`docs/plugin-lua-modules.md:735-736`).

So a backend plugin's `BackendInstall` must either shell out (`cmd.exec("sha256sum ...")`) or implement hashing itself if it wants to verify a download it fetched via `http.download_file`.
This is a real gap relative to mise's own downloader: mise's **built-in** backends (http:, aqua:, github:, and non-backend vfox tool plugins where mise downloads the URL the plugin returns) get automatic `checksum`/`checksum_url`/`checksum_expr` verification ([HTTP Backend § checksum](https://mise.jdx.dev/dev-tools/backends/http.html#checksum), `docs/dev-tools/backends/http.md:96-194`) — but that automatic verification happens in mise's own Rust downloader, which a backend plugin's Lua-driven `http.download_file()` call does **not** go through (see §9 for the same finding applied to auth headers).
vfox.md's marketing claim that "archive extraction... out of the box" (true) sits next to no equivalent claim for checksums — confirmed absent by source inspection, not merely undocumented.

### Runtime info (`RUNTIME` global) — see §7 for full detail; summarized here as it's part of the "context" surface

`RUNTIME.osType`, `RUNTIME.archType`, `RUNTIME.envType`, `RUNTIME.version` (vfox runtime version, currently `"0.6.0"`), `RUNTIME.pluginDirPath` — the last field is the primary-source answer to "how does a plugin locate its own bundled files" (its install directory on disk), exposed via `crates/vfox/src/runtime.rs:73-77`.

### Template repo

[jdx/mise-backend-plugin-template](https://github.com/jdx/mise-backend-plugin-template) ships LuaCATS type defs, stylua, hk lint config, and all three hooks pre-wired — the recommended starting point (`docs/backend-plugin-development.md:3-4`).

---

## 2. Plugin installation & pinning

### Install from an arbitrary git URL

```
mise plugin install <name> <git-url>
```

works for any git repo, a local zip-over-HTTPS URL, or (`mise plugin link`) a local directory ([Using Plugins](https://mise.jdx.dev/plugin-usage.html), `docs/plugin-usage.md:38-63`).
CLI help (verified empirically with mise v2026.8.8: `mise plugin install --help`) shows the exact grammar and confirms git-ref pinning:

```
$ mise plugins install poetry https://github.com/mise-plugins/mise-poetry.git#11d0c1e
```

i.e. append `#<ref>` (branch, tag, or commit SHA) to the URL.

### Declaring/pinning a plugin in config (shareable, not just one-shot)

The `[plugins]` section of `mise.toml` (or the global/system config) maps a short name to a URL, optionally pinned to a ref, and optionally prefixed with a backend-type hint:

```toml
[plugins]
elixir = "https://github.com/my-org/mise-elixir.git"
node = "https://github.com/my-org/mise-node.git#DEADBEEF"   # pinned gitref
"vfox-backend:myplugin" = "https://github.com/jdx/vfox-npm"  # explicit type hint
```

If the `asdf:`/`vfox:`/`vfox-backend:` type prefix is omitted, mise clones the plugin first and detects its type from the installed files ([Configuration § `[plugins]`](https://mise.jdx.dev/configuration.html#plugins-specify-custom-plugin-repository-urls), `docs/configuration.md:238-274`).
This section **only affects new plugin installs** — it is not a lockfile; an existing plugin install is left as-is unless you `mise plugins install --force <name>` (same doc range).
This is the documented replacement for the deprecated `settings.shorthands_file` / `MISE_SHORTHANDS_FILE` mechanism (`docs/configuration.md:273-274`).

### Updates and auto-update

`mise plugin update [<name>|--all]` updates a plugin's git checkout to the latest commit on its tracked ref (verified empirically: `mise plugin update --help` — "note: this updates the plugin itself, not the runtime versions").
There is **no live auto-update to disable**: the one settings key that looks relevant, `plugin_autoupdate_last_check_duration` (env `MISE_PLUGIN_AUTOUPDATE_LAST_CHECK_DURATION`, default `7d`), carries this description verbatim in `settings.toml:2053-2057`:

> "How long to wait before updating plugins automatically (**note this isn't currently implemented**)."

So plugin updates today are strictly a manual/explicit `mise plugin update` action — there is no background auto-update behavior in v2026.8.8 that would need disabling.
(Do not assert "mise never auto-updates plugins" as a permanent architectural guarantee — the setting's presence signals intent to add this later; state it as "not implemented as of v2026.8.8.")

### On-disk checkout location

Plugins are cloned into `$MISE_DATA_DIR/plugins/<name>` — default `~/.local/share/mise/plugins/` on Linux/macOS (troubleshooting section, `docs/plugin-usage.md:224-234`, and `MISE_DATA_DIR` definition in `docs/configuration.md:558-566`).
Empirically (mise v2026.8.8, no plugins currently installed) `mise cache` (config subcommand) confirms `MISE_CACHE_DIR=~/.cache/mise`, and the docs' stated default data dir (`~/.local/share/mise`) matches `$XDG_DATA_HOME` conventions on this machine.

Inside a running hook, a plugin should use `RUNTIME.pluginDirPath` (`crates/vfox/src/runtime.rs:77`) rather than hard-coding the data dir, to read its own bundled catalog files (e.g. a private tool→URL manifest shipped inside the plugin repo) — this is the correct primary-source mechanism for "the plugin can read its own bundled catalog files," and it is environment/user-independent.

---

## 3. Short-name routing / aliases

### `[tool_alias]` — "Aliased Backends" (the mechanism the task asks about)

Renamed from `[alias]` in a recent version; the old `[alias]` key is deprecated but still works ([Tool Aliases](https://mise.jdx.dev/dev-tools/aliases.html), `docs/dev-tools/aliases.md:1-8`).
The doc gives exactly the pattern needed:

```toml
# ~/.config/mise/config.toml
[tool_alias]
node = 'github:company/our-custom-node'
erlang = 'aqua:company/our-custom-erlang'
```

(`docs/dev-tools/aliases.md:15-19`).
This redirects the *backend* a short tool name resolves to, not just a version string.

**Does this extend to a private `plugin:tool` backend (e.g. `vault:go`), not just built-in backend types?**
Yes — verified at the source level, not just inferred from the doc's `github:`/`aqua:` examples.
`BackendArg::backend_type()` (`src/cli/args/backend_arg.rs:384-419`) resolves an alias value like `"vault:go"` through `plugin_backend_type()` (`src/cli/args/backend_arg.rs:213-226`), which — independent of the simpler `BackendType::guess()` heuristic used only for an internal `explicit` bookkeeping flag — checks the **installed plugin registry** (`install_state::get_plugin_type("vault")`) and returns `BackendType::VfoxBackend("vault")` when a plugin named `vault` is installed.
So `[tool_alias] go = "vault:go"` is architecturally sound, **provided the `vault` plugin is installed first** (or auto-installs on first use, per `mise plugin install --help`'s own note that `mise install cmake@3.30` will autoinstall the `cmake` plugin — the same should apply to a first `go` use that resolves to `vault:go`, though this specific auto-install-of-backend-plugin path was not independently exercised — see Key risks).

**Machine-wide, without touching per-repo `mise.toml`?**
Yes, confirmed both by doc and by source.
`docs/configuration.md:392-395` states `/etc/mise/config.toml` "works like `~/.config/mise/config.toml`... for all users on the system."
At the source level, `system_config_files()` (`src/config/mod.rs:2331-2339`, reading `dirs::SYSTEM_CONFIG` = `/etc/mise` by default, overridable via `MISE_SYSTEM_CONFIG_DIR`/`MISE_SYSTEM_CONFIG_FILE`) is unconditionally folded into `config.config_files` (`src/config/mod.rs:1921, 1939, 2181`), which feeds `config.aliases = load_aliases(&config.config_files)` at `src/config/mod.rs:298`.
So a `[tool_alias]` entry in `/etc/mise/config.toml` is merged in exactly the same way as one in `~/.config/mise/config.toml`, and project `mise.toml`/`.tool-versions` files need no changes at all.

**Empirical proof of the full chain** (verified empirically with mise v2026.8.8): a scratch dir with `.tool-versions` containing `golang 1.21.0` and `MISE_GLOBAL_CONFIG_FILE` pointed at a config containing `[tool_alias]\ngo = "aqua:hashicorp/terraform"` (an intentionally unmistakable redirect target) produced:

```
$ mise tool go
Backend:            aqua:hashicorp/terraform
...
Active Version:     1.21.0
Requested Version:  1.21.0
Config Source:      .../.tool-versions
```

This is a full end-to-end proof of `.tool-versions` `golang` → `unalias_backend("golang")` → `"go"` → `[tool_alias] go = "<redirect>"` → resolved backend, using only a global/system config file and zero per-repo changes.
(Terraform was used only as an unmistakable stand-in; the same mechanism applies to `go = "vault:go"`, contingent on the `vault` plugin being installed as discussed above.)

### `[tool_alias.<tool>.versions]` — version aliases (different mechanism, don't conflate)

A **separate** feature: mapping a symbolic version name to a concrete version for one already-resolved tool/backend, e.g. `lts-iron -> 20` for node (`docs/dev-tools/aliases.md:36-56`).
Not what routes short names to backends.

### `MISE_BACKENDS_<TOOL>` env var override

Highest-priority override, above registry and alias config:

```sh
export MISE_BACKENDS_PHP='vfox:mise-plugins/vfox-php'
```

Tool name in SHOUTY_SNAKE_CASE ([Registry § Environment Variable Overrides](https://mise.jdx.dev/registry.html#environment-variable-overrides), `docs/registry.md:96-106`; also documented in `docs/dev-tools/backend_architecture.md:99-107`).
Useful for a CI-only or per-machine override that shouldn't live in any config file at all.

### `disable_backends` setting

`mise settings disable_backends=asdf` (or a vfox-backend plugin name) removes that backend from consideration **for new installs only** — existing installs using it are untouched (`settings.toml:485-491`, [Registry § Backends Priority](https://mise.jdx.dev/registry.html#backends-priority), `docs/registry.md:84-92`).
Not itself a short-name router, but relevant alongside `[tool_alias]` when you want to force everyone off the public `asdf`/community `vfox` shorthand entirely (see §6).

### What happens when an alias shadows a core backend tool like `go`

Nothing structurally prevents it — `go` is resolved through the exact same `unalias_backend` → alias-lookup → `backend_type()` pipeline as any other tool short name (`src/config/mod.rs:467-477`, `get_backend_alias_opts`), and the empirical test above used `go` itself as the shadowed name.
The core `go` backend is not special-cased or protected; whichever backend the alias points to wins for every subsequent reference to `go`, including `.tool-versions` (`golang`), `mise.toml`, and bare CLI `mise use go`.

### Config file precedence order (full hierarchy)

Confirmed from [Configuration § Configuration Hierarchy](https://mise.jdx.dev/configuration.html#configuration-hierarchy) (`docs/configuration.md:29-75`), lowest → highest precedence:

1. `/etc/mise/{conf.d/*.toml, config.toml, config.<env>.toml}` — system-wide
2. `~/.config/mise/{conf.d/*.toml, config.toml, config.<env>.toml, config.local.toml, config.<env>.local.toml}` — user-wide
3. Project-tree `mise.toml` files, walked from the ceiling down to cwd, each level overriding the one above (`~/work/mise.toml` overridden by `~/work/myproj/mise.toml` overridden by `~/work/myproj/backend/mise.toml`, etc.)
4. Within one directory: `mise.local.toml` > `mise.toml` > `mise/config.toml` > `.mise/config.toml` > `.mise/conf.d/*.toml` > `.config/mise.toml` > `.config/mise/config.toml` > `.config/mise/conf.d/*.toml` (`docs/configuration.md:7-16`)

`[tools]`/`[env]`/`[settings]` merge additively with override-on-conflict across all these layers;
`[tasks]` replace wholesale per-name;
`[tool_alias]` was traced above to merge the same way `[settings]` does (all levels folded into one `AliasMap`).
Run `mise config` to see the actual resolved file list and order for a given cwd (`docs/configuration.md:121-123`).

---

## 4. `.tool-versions` compatibility

mise reads `.tool-versions` (asdf's format) as a first-class alternative to `mise.toml` ([Configuration § `.tool-versions`](https://mise.jdx.dev/configuration.html#tool-versions), `docs/configuration.md:397-420`), including scopes (`ref:`, `prefix:`, `path:`, `sub-N:`) and comments.

### `golang` → `go` mapping: hardcoded, not user-configurable

This is **not** `[tool_alias]` and is **not** the registry — it's a fixed table in Rust:

```rust
// src/backend/mod.rs:4898-4905
pub fn unalias_backend(backend: &str) -> &str {
    match backend {
        "dotnet-core" => "dotnet",
        "nodejs" => "node",
        "golang" => "go",
        _ => backend.trim_start_matches("core:"),
    }
}
```

Confirmed by a co-located unit test asserting exactly `unalias_backend("golang") == "go"` (`src/backend/mod.rs:4908-4913`).
`mise_toml.rs` independently documents this as "hardcoded aliases (`nodejs`, `golang`, `dotnet-core`)" distinct from a `core:`-qualified name or a user alias (comment found via `gh search code` over `src/config/config_file/mise_toml.rs`; exact line not re-verified by direct fetch — treat the three-entry list itself as fully confirmed via `backend/mod.rs`, and this framing comment as corroborating but secondary).

`unalias_backend` is called from every tool-name entry point that matters: `BackendArg::from` (`src/cli/args/backend_arg.rs:60-64`), `src/cli/plugins/link.rs`, `install.rs`, `uninstall.rs`, `src/config/mod.rs`, and `src/toolset/tool_request_set.rs` — i.e. it applies uniformly regardless of whether "golang" came from `.tool-versions`, `mise.toml`, or a bare CLI argument.

### Can an alias make `golang 1.26.0` in `.tool-versions` resolve to a private backend?

**Yes — empirically confirmed** (§3): `unalias_backend("golang")` runs first (hardcoded, always "golang"→"go"), and the resulting `"go"` short name is then looked up in `[tool_alias]` exactly like any other tool name.
The order is fixed and not configurable (you cannot alias `"golang"` directly to bypass the hardcoded fold — you alias the post-fold name, `"go"`).

---

## 5. `mise outdated` / `mise ls-remote` — backend hook vs. public metadata

**For backend plugins specifically: purely the plugin's own `BackendListVersions` hook — no public registry or "mise-versions host" fallback is consulted.**
Confirmed at the source level in `src/backend/vfox.rs::_list_remote_versions` (`src/backend/vfox.rs:153-183`):

```rust
if this.is_backend_plugin() {
    // ...
    let versions = vfox
        .backend_list_versions(&this.pathname, tool_name, opts)
        .await
        .wrap_err("Backend list versions method failed")?;
    return Ok(versions.into_iter().map(|v| VersionInfo { version: v, ..Default::default() }).collect());
}
// (only traditional, non-backend vfox plugins fall through to `list_available_versions`)
```

`mise outdated` (`src/cli/outdated.rs`) and `mise ls-remote` both go through `ToolVersion::latest_version[_with_opts]` (`src/toolset/outdated_info.rs:108-113`), which ultimately calls the same per-backend `list_remote_versions`/`_list_remote_versions` — so both commands are, for a backend plugin, 100% sourced from the plugin's own hook.

Nuances that matter for design/caching, not for the "is it private" question:

- There **is** a `mise-versions host` — a mise-hosted cache used to reduce GitHub API rate-limit pressure for *some* backends (GitHub-release-based ones).
  `mise ls-remote --help` exposes `--no-versions-host` to bypass it (verified empirically).
  Source comments in `src/backend/vfox.rs:144-151` explicitly note that vfox/backend-plugin version listing currently has no hook into this host at all ("keep versions-host behavior unchanged until there is a real contract") — so this caching layer is simply inert for backend plugins, not a privacy leak.
- Results are cached locally (`mise ls-remote --help`: "results may be cached, run `mise cache clean` to clear"), and `offline`/`prefer_offline` gate whether the hook is invoked at all for a given command (§6).

---

## 6. Disabling public fallback — exact setting names

All of the following are real, current settings (source: `settings.toml` at the pinned commit; env var names and one-line descriptions quoted verbatim).

| Setting | Env var | Effect |
|---|---|---|
| `offline` | `MISE_OFFLINE` | "Disable all HTTP requests. Tools will only use locally cached data." Also a `--offline` CLI flag. Verified at call sites gating `list_remote_versions` in `src/backend/mod.rs:2105`, and separately in `src/http.rs`, `src/backend/aqua.rs`, `src/backend/github.rs`, `src/versions_host.rs`. (`settings.toml:1947-1961`) |
| `prefer_offline` | `MISE_PREFER_OFFLINE` | Weaker: prefers cache but still falls back to network. Auto-enabled for `hook-env`, `activate`, `exec`, `env`, `ls`, `current`, `where`, `which`, shims. (`settings.toml:2059-2069`) |
| `paranoid` | `MISE_PARANOID` | Broad hardening umbrella (see [Paranoid](https://mise.jdx.dev/paranoid.html)); `global_only = true` in `settings.toml:2001-2007` — **can only be set in global/system config, not per-project**. Notably: community (non-first-party) plugins cannot be installed by short-name under paranoid — full git URL required (`docs/paranoid.md:44-58`). Does **not** by itself block all outbound HTTP (only forces HTTPS where mise would otherwise use HTTP for non-sensitive lookups, plus re-verifies provenance) — it is a trust/verification control, not a network kill-switch (`docs/paranoid.md:60-83`). |
| `disable_backends` | `MISE_DISABLE_BACKENDS` (comma list) | "Backends to disable for new installs, such as `asdf`, `pipx`, or a vfox-backend plugin name." Does not uninstall/disable already-installed tools. (`settings.toml:485-491`) |
| `disable_default_registry` | `MISE_DISABLE_DEFAULT_REGISTRY` | "Disable the default mapping of short tool names like `php` -> `asdf:mise-plugins/asdf-php`." **Important, easy-to-miss scope note in the setting's own description: "This parameter disables only for the backends `vfox` and `asdf`."** It does not disable the aqua/github default-registry mappings. (`settings.toml:493-497`) |
| `locked` | `MISE_LOCKED` | "Require lockfile URLs to be present during installation" — with a lockfile, blocks live API calls (GitHub, aqua registry, etc.) entirely for install; equivalent to `mise install --locked`. (`settings.toml:1414-1440`) |
| `locked_verify_provenance` | `MISE_LOCKED_VERIFY_PROVENANCE` | Forces re-verification of SLSA/cosign/minisign/attestation provenance at every install even when the lockfile already has it; auto-enabled by `paranoid`. (`settings.toml:1442-1460`) |
| `netrc` | `MISE_NETRC` | Default `true`; use `~/.netrc` for HTTP Basic auth. See §9 for its actual (limited) scope. (`settings.toml:1614-1636`) |

No single setting is a one-flag "never contact GitHub" switch for backend plugins specifically, because a backend plugin's Lua code can make arbitrary `http.get`/`http.download_file` calls that are **not gated by `offline` at all** at the Lua-module level (see §9 and Key Risks) — `offline` is enforced by mise's Rust orchestration layer around *its own* remote-version-listing and download logic, not inside the vfox Lua HTTP client.
For a fully airtight "never talks to the public internet" guarantee, the actual guarantee has to come from what the plugin's own Lua code chooses to call, plus `disable_backends`/`disable_default_registry` to keep mise itself from ever selecting a public backend for a given tool name.

---

## 7. Platform info exposed to Lua hooks (`RUNTIME`)

Source: `crates/vfox/src/runtime.rs:71-79` (Lua `UserData` field getters) and `crates/vfox/src/config.rs:32-45` (`os()`/`arch()` functions that seed the static `RUNTIME`).

| Field | Source | Exact values |
|---|---|---|
| `RUNTIME.osType` | `os()` = Rust `std::env::consts::OS` with `"macos"` remapped to `"darwin"`; everything else passed through (so `"linux"`, `"darwin"`, `"windows"`, and any other Rust target OS string mise is compiled for) | `"linux"`, `"darwin"`, `"windows"` |
| `RUNTIME.archType` | `arch()` = Rust `std::env::consts::ARCH` with `"aarch64"`→`"arm64"` and `"x86_64"`→`"amd64"`; everything else passed through | `"amd64"`, `"arm64"`, and raw Rust arch strings otherwise (e.g. `"x86"`) — **not** `"x86_64"` for amd64 |
| `RUNTIME.envType` | libc detection | `"gnu"` on glibc Linux, `"musl"` on musl Linux, `nil` on Windows/macOS/undetected (`docs/backend-plugin-development.md:427`) |
| `RUNTIME.version` | hardcoded | `"0.6.0"` (vfox runtime compat version — `crates/vfox/src/runtime.rs:21`) |
| `RUNTIME.pluginDirPath` | plugin install path | absolute path to the plugin's own install/checkout dir |

`with_platform(os, arch)` (`crates/vfox/src/runtime.rs:36-42`) is used when mise cross-resolves for a platform other than the host (e.g. `mise lock` building a multi-platform lockfile) — in that path `envType` is deliberately `nil` because "target libc is unknown in cross-platform context."
Backend plugin authors should not assume `envType` is always populated on Linux.

The separately-documented `http:` backend's `os()`/`arch()` **template functions** use a *different* vocabulary (`macos`/`linux`/`windows` and `x64`/`arm64`, not `darwin`/`amd64`) — do not conflate the two; `RUNTIME.osType`/`archType` (Lua plugin context) and `os()`/`arch()` (http-backend URL templates) are separate namespaces with separate spellings (`docs/dev-tools/backends/http.md:52-54`).

---

## 8. Runtime distributions — GOROOT-style env vars and PATH

`BackendExecEnv` returns `{env_vars = {{key=..., value=...}, ...}}` (§1).
The consuming Rust code in `src/backend/vfox.rs:376-408` treats the `PATH` key **specially**, distinct from every other key:

```rust
// list_bin_paths (src/backend/vfox.rs:376-394)
// pulls the PATH entry out of the exec_env response, splits it on the
// platform path separator, and returns it as a list of bin directories —
// these get added to mise's own PATH composition (prepended per-tool),
// not written as a literal PATH= override.

// exec_env (src/backend/vfox.rs:396-408)
// filters OUT the PATH key before returning the remaining env_vars —
// PATH never reaches the "regular literal env var" path.
```

So:

- Returning `{key = "PATH", value = install_path .. "/bin"}` does **not** clobber the process/shell `PATH` — mise treats it as "these are this tool's bin directories," splits on `:`/`;`, and merges them into its own managed `PATH` the same way it does for every other tool/backend.
  Multiple directories can be returned by joining them with the platform path separator before returning (mirrors how any other `PATH`-producing backend works).
- Any other key (e.g. `GOROOT`, `JAVA_HOME`) is passed through **literally** as a plain environment variable, unmodified.
- If `BackendExecEnv` returns no `PATH` key at all, mise defaults to `tv.runtime_path().join("bin")` (`src/backend/vfox.rs:391-393`).

This is exactly the mechanism needed for a "full runtime" tool (Go-like):

```lua
function PLUGIN:BackendExecEnv(ctx)
    return {
        env_vars = {
            {key = "PATH", value = ctx.install_path .. "/bin"},
            {key = "GOROOT", value = ctx.install_path},
        }
    }
end
```

**Precedent for full-runtime tools in backend plugins specifically: none found in primary sources.**
The only documented, real-world backend-plugin example is `vfox-npm` ([jdx/vfox-npm](https://github.com/jdx/vfox-npm), `docs/backend-plugin-development.md:142-221`), which is a package-manager shim (installs npm packages into `node_modules/.bin`), not a full runtime with a `*_HOME`-style env var.
The `embedded-plugins/vfox-*` plugins bundled in the `crates/vfox` crate (e.g. `vfox-ant`, `vfox-vlang`, `vfox-scala`, `vfox-aapt2` — found via `gh search code 'require("http")'`) are **tool plugins** (traditional single-tool hook system: `Available`/`PreInstall`/`EnvKeys`), not backend plugins — so they are not evidence for backend-plugin runtime-env precedent either, only for the general vfox Lua runtime's capability to do this kind of thing.
Treat "a GOROOT-style backend plugin works" as architecturally sound from the mechanism above, but **not battle-tested by an existing public example** — flagged in Key Risks.

---

## 9. HTTP auth for downloads — headers, GitHub token, `.netrc`

### Explicit headers — always available

`http.get`/`http.head`/`http.download_file` all accept a `headers` table (`docs/plugin-lua-modules.md:26-47`), so a plugin can inject a bearer token or any custom header explicitly:

```lua
http.get({ url = "...", headers = { ["Authorization"] = "Bearer " .. token } })
```

### GitHub token auto-injection — real, but narrowly scoped to `api.github.com`

Source: `crates/vfox/src/lua_mod/http.rs:134-178` (`github_token()`, `add_default_headers()`).
If a request's URL host is `api.github.com` (or `api.*.ghe.com`) **and** no `Authorization` header was already set, mise injects `Authorization: Bearer <token>` where the token is resolved from (in order) a registered Lua callback, a registered string, then env vars `MISE_GITHUB_TOKEN` / `GITHUB_API_TOKEN` / `GITHUB_TOKEN`.
The code comment is explicit about *why* this is host-restricted: sending auth to `github.com` release-download URLs causes a 302 redirect to `objects.githubusercontent.com`, which then 401s once the cross-origin redirect strips the header — so this mechanism deliberately does **not** apply to generic release-asset downloads, only the REST API host.

### `url_replacements` — does apply to the Lua http module, with a credential caveat

The vfox backend "honors mise's `url_replacements` setting for both tool artifact downloads and requests made through the plugin's built-in Lua HTTP module.
This includes `http.get`, `http.head`, `http.download_file`, and their `try_*` variants." (`docs/dev-tools/backends/vfox.md:106-110`).
Confirmed at source level: the Lua http module calls a `rewrite_url()` function (`crates/vfox/src/lua_mod/http.rs:260-262` and call sites at lines 282, 304, 340, 365, 402, 438) that invokes a registered Lua callback under the registry key `URL_REWRITER_REGISTRY_KEY` (`crates/vfox/src/http.rs:13`) — i.e. mise's Rust side injects the `url_replacements` logic into the Lua sandbox as a callable, and every Lua http call routes through it.

`docs/url-replacements.md` (fetched, 178 lines) carries an explicit **security warning**: replaced-URL requests **keep** any auth headers generated for the original URL (e.g. a GitHub bearer token), "by design," so `url_replacements` targets must be trusted — an untrusted replacement host would receive leaked credentials.
It also documents `~/.netrc` interaction: "Replacements are applied *before* the netrc lookup, so you should use the hostname of the *replaced* URL in your netrc file," and ".netrc credentials take precedence over and will overwrite any default authentication headers (such as those from `MISE_GITHUB_TOKEN`)."

### `.netrc` — **the doc's netrc/url_replacements interaction describes mise's own Rust HTTP client, not the Lua `http` module used inside backend-plugin hooks**

This is the one place doc prose and source code appear to diverge, and it matters a lot for a `BackendInstall`-hook download flow:

- The `netrc`/`netrc_file` settings and the actual netrc-header-injection logic live in `src/netrc.rs` and `src/http.rs::netrc_headers()` (found via `gh search code "netrc" --repo jdx/mise`) — this is **mise's own** HTTP client (`reqwest`-based, used by mise's Rust code directly: http:/aqua:/github: backends, self-update, etc.).
- The Lua-exposed `http` module used inside plugin hooks (`crates/vfox/src/lua_mod/http.rs`) uses a **separate** `reqwest::Client` defined in `crates/vfox/src/http.rs:6-11` (`pub static CLIENT`).
  Searching the entire `lua_mod/http.rs` file (1352 lines) for `netrc` returns **zero matches** — there is no netrc wiring in the Lua HTTP client at all.
  The only auth mechanisms found there are the explicit `headers` table and the narrow GitHub-API-token auto-injection described above.

So: `MISE_NETRC`/`.netrc` is real and does inject HTTP Basic auth for mise's own downloads (the http:/aqua:/github: backends, and — per the url-replacements doc — for whatever mise's own Rust code fetches after a `url_replacements` rewrite).
**It does not automatically apply inside a Lua `BackendInstall` hook's own `http.get`/`http.download_file` calls.**
A backend plugin author who needs `.netrc`-style credential injection for an authenticated artifact server must either (a) pass headers explicitly (e.g. read the token via `os.getenv(...)` and build the `Authorization` header in Lua), or (b) shell out via `cmd` to a tool that itself honors `.netrc` (e.g. `curl -n`).
This is a genuinely surprising gap relative to what the docs' netrc section implies at first read, and should be flagged loudly in the mise-vault design: **do not assume `.netrc` "just works" for a private backend plugin's own downloads.**

### `MISE_HTTP_*` env vars — scope

Only three exist in the current settings schema: `MISE_HTTP_TIMEOUT`, `MISE_HTTP_DOWNLOAD_TIMEOUT`, `MISE_HTTP_RETRIES` (`settings.toml` grep, lines 1216, 1243, 1254) — timeouts/retry tuning only, no `MISE_HTTP_HEADERS`/`MISE_HTTP_AUTH`-style generic-auth-injection setting exists.
Confirmed absent, not merely undocumented.

---

## 10. `http:` backend and tool stubs as alternatives to a full plugin

### `http:` backend

Installs a single tool from a direct/templated URL, with real built-in security/UX features a hand-written Lua plugin would have to reimplement: `checksum`/`checksum_url`/`checksum_expr`, `size` verification, `strip_components` (with auto-detection), `bin`/`rename_exe`, `version_list_url` + `version_regex`/`version_json_path`/`version_expr` for `ls-remote` support, and a shared content-addressed cache under `$MISE_DATA_DIR/http-tarballs/` ([HTTP Backend](https://mise.jdx.dev/dev-tools/backends/http.html), `docs/dev-tools/backends/http.md`, full doc fetched — 536 lines).

**Why it doesn't by itself satisfy "central catalog + short names + no per-repo config":** each `http:<name>` entry is declared per-tool in `[tools]` (`mise.toml`/global config), one entry per tool-version-URL combination — there's no single place a fleet of `http:` tool definitions becomes a *catalog* the way a backend plugin's `BackendListVersions`/`BackendInstall` can programmatically serve an arbitrary and growing set of tool names from one plugin.
It's a good fit for **one or a handful** of specific pinned tools, not for "any tool in our internal catalog by short name."

**A real, undertested middle-ground worth a PoC**: `[tool_alias]` values support the same `[opts]`-in-brackets syntax as `mise.toml` tool entries — confirmed by `get_backend_alias_opts()` calling `split_bracketed_opts(backend)` on the alias's `backend` string (`src/config/mod.rs:467-477`, `split_bracketed_opts` defined in `src/cli/args/backend_arg.rs:108+`).
That means something like

```toml
[tool_alias]
mytool = 'http:mytool[url=https://vault.internal/mytool-{{version}}-{{os()}}-{{arch()}}.tar.gz,version_list_url=https://vault.internal/mytool/versions.json]'
```

in a machine-wide config could give a short name backed entirely by the `http:` backend (full checksum/lockfile support, no Lua at all) without per-repo config.
This was **not** exercised end-to-end (no working internal artifact server to test against) — flag as a promising alternative worth a PoC before committing to a full backend-plugin build, not as confirmed working.

### Tool stubs (`mise generate tool-stub`, `mise tool-stub`)

An executable file with an embedded TOML config and a `#!/usr/bin/env -S mise tool-stub` shebang; installs/lazy-loads on first execution ([Tool Stubs](https://mise.jdx.dev/dev-tools/tool-stubs.html), `docs/dev-tools/tool-stubs.md`, 385 lines fetched).
`mise generate tool-stub` (verified empirically: `--help` output) supports `--checksum-algorithm blake3|sha256`, `--lock` (embeds resolved lockfile data), `--fetch` (back-fills checksums for an existing stub), and multi-platform stubs via repeated `--platform-url`.

**Why it doesn't satisfy "central catalog + short names + no per-repo config":** a tool stub is a standalone **file per tool** that must be generated, committed, and distributed somewhere on `PATH` (or per-repo, e.g. `./bin/mytool`) — it is not consulted through mise's tool-name resolution (`[tools]`/`.tool-versions`/aliasing) at all; running it directly *is* the UX.
It's the opposite shape from what's being asked for: great for "ship one lazily-installed pinned binary as a script," bad for "give every developer `go`/`golangci-lint` by short name from a single central definition."

---

## Deprecated / surprising

- **asdf-style (legacy) plugins vs. vfox backend plugins are architecturally distinct systems, not versions of the same thing.**
  Legacy asdf plugins are shell-script based (`bin/install`, `bin/list-all`), Linux/macOS only, and per the registry's acceptance policy **new asdf/vfox community entries are no longer accepted** into mise's bundled registry "for supply-chain security reasons" — use `aqua:`/`github:` instead (`docs/registry.md:77-82`).
  This doesn't block a private org from writing its own asdf-style or vfox (non-backend) plugin; it only affects acceptance into mise's *public, bundled* registry — irrelevant to a private `mise-vault` plugin, but worth knowing so the design doesn't accidentally target a system mise itself is steering third parties away from.
- **`ubi:` backend is deprecated** — migrate any `ubi:owner/repo` usage to `github:owner/repo` (`docs/dev-tools/backend_architecture.md:66-77`).
- **Backend plugins do not currently support attestation verification** (SLSA/cosign/GitHub artifact attestations) — that's a tool-plugin-only feature today (`docs/dev-tools/backends/vfox.md:13`).
  If supply-chain attestation matters for mise-vault's catalog, a backend plugin cannot get it "for free" the way a tool plugin (or the aqua backend) can.
  Correspondingly, `mise.lock` "rolling version checksums" for backend plugins are limited to whatever the plugin's `BackendInstall` chooses to write via `install_state::write_checksum` (`src/backend/vfox.rs:367-370`) — there's no attestation-type recorded for backend-plugin installs.
  `locked_verify_provenance`/paranoid's provenance re-verification therefore has nothing to re-verify for a backend-plugin-sourced tool.
- **`disable_default_registry` only covers `vfox`/`asdf` short-name mappings**, not aqua/github/core defaults — its own description says so explicitly (`settings.toml:493-497`).
  Easy to misread as a blanket "disable the registry" switch.
- **Plugin auto-update is a documented no-op today** (§2) — the setting exists, the feature doesn't, per the setting's own description.
- **`paranoid` is `global_only`** in the settings schema (`settings.toml:2004`) — cannot be set per-project, only in global/system config.
  Consistent with the design intent (a project shouldn't be able to weaken an org's paranoid posture), but a possible surprise if someone tries `[settings] paranoid = true` in a repo `mise.toml`.
- **`.netrc` does not reach the Lua `http` module** (§9) — the most operationally important surprise found in this research, since it directly affects how mise-vault's plugin must authenticate to an internal artifact store.
- **No built-in checksum/hash Lua module** (§1/§9) despite `archiver` (extraction) and `semver` being fully built in — an asymmetry worth designing around explicitly (e.g. mise-vault's plugin should shell out to `sha256sum`/use `cmd.exec` and compare, or prefer routing installs through a mechanism that gets mise's own checksum verification "for free," per the `[tool_alias] ... http:...[checksum_url=...]` idea in §10).

---

## Key risks / unknowns (need hands-on PoC, not verifiable from primary sources alone)

1. **Auto-install of a backend plugin referenced only via `[tool_alias]`.**
   `mise plugin install --help` documents auto-install for `mise install cmake@3.30` (registry-driven), but this research did not find/exercise primary-source confirmation that the *first* reference to an aliased name (e.g. `go` → `vault:go` before `vault` is ever installed) triggers an automatic `mise plugin install vault <url>`, versus erroring out asking the user to install the plugin first.
   This is the single most operationally important unknown for a zero-touch developer experience and needs an actual PoC with a real (even trivial) backend plugin installed from a private git URL.
2. **Whether `offline=true` blocks a backend plugin's own Lua HTTP calls during `BackendInstall`/`BackendExecEnv`, not just `BackendListVersions`.**
   §5/§6 confirmed `offline` gates the remote-version-listing cache layer in `src/backend/mod.rs`.
   It was **not** confirmed whether mise checks `offline` before even invoking `BackendInstall` for a tool that needs installing, nor whether the Lua `http` module itself has any offline awareness (source inspection of `crates/vfox/src/lua_mod/http.rs` found none).
   If a plugin's `BackendInstall` calls `http.download_file` unconditionally, `offline=true` may not stop it.
   Needs an empirical test: set `MISE_OFFLINE=1`, force an install of an aliased backend-plugin tool not yet installed, and see whether it errors before or after the Lua HTTP call fires.
3. **GOROOT-style full-runtime backend plugin — no existing public example.**
   §8 traced the exact mechanism (return `PATH` + `GOROOT` from `BackendExecEnv`) from source, and it should work per the `list_bin_paths`/`exec_env` split behavior found in `src/backend/vfox.rs`, but no shipped backend plugin doing this was found (`vfox-npm` is the only public backend-plugin example and isn't a runtime).
   Build and exercise a minimal real backend plugin exporting a `*_HOME`-style var before relying on this for mise-vault's Go/JDK-style tools.
4. **`.netrc` gap workaround correctness.**
   §9's finding that the Lua `http` module has no netrc wiring was established by absence-of-evidence in a 1352-line file plus a separate, netrc-free `CLIENT` definition — strong, but still absence-based.
   Confirm with a live authenticated endpoint (even a local test HTTP server requiring Basic auth) that (a) `.netrc` indeed does nothing inside a plugin's `http.get`, and (b) an explicit `Authorization` header built in Lua from `os.getenv(...)` works as expected end-to-end through `BackendInstall`.
5. **Checksum-verification ergonomics inside a Lua-only download flow.**
   Confirmed no built-in hash module exists; not yet prototyped is the actual pattern mise-vault should use — shelling out via `cmd.exec` to `sha256sum`/`b3sum` (adds a runtime dependency on the install host) vs. routing the artifact download itself through mise's own `http:`-backend-style checksum machinery via the `[tool_alias] ... http:...[checksum_url=...]` pattern floated in §10 (which sidesteps Lua entirely for tools simple enough to be single-binary/archive downloads).
   Needs a design decision plus a PoC of whichever path is chosen.
6. **`[tool_alias]` + bracketed opts (`http:name[url=...]`) as a full alternative to writing any Lua at all.**
   Mechanically plausible from source (`split_bracketed_opts` in `get_backend_alias_opts`), never exercised against a real artifact server.
   If it works cleanly, it may remove the need for a Lua backend plugin altogether for tools that are simple archive/binary downloads (leaving Lua only for tools needing dynamic version discovery beyond what `version_list_url`/`version_regex`/`version_json_path`/`version_expr` can express, or multi-tool `plugin:tool` fan-out that a single `http:` alias per tool can't provide).
7. **Whether `mise plugin install --force` / `[plugins]` section changes are sufficient for a controlled internal plugin *update* rollout** (as opposed to install) at fleet scale — the docs describe the mechanics (§2) but nothing was found describing a recommended pattern for staged rollout / rollback of a plugin pin across an organization; this is a process question, not purely a mise-mechanics question, and falls outside what primary sources can answer.
