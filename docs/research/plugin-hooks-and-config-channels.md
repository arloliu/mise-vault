# Plugin-Install Triggers and Nexus-URL Config Channels — Research for mise-vault

Verified against mise v2026.8.8 (linux-x64, released 2026-08-17 — installed locally as `mise --version`).
Research date: 2026-08-18.

Source citations pin to commit [`33073d5`](https://github.com/jdx/mise/commit/33073d5e26bb82becbb3d248581d2efedf889078) (HEAD of `jdx/mise` `main` at research time, cloned shallow to a scratch dir for this research — same commit used in `docs/research/mise-backend-plugin-mechanics.md`).
Doc citations link to the live page at `mise.jdx.dev`;
the underlying `docs/*.md` source path at the same commit is given alongside.
Empirical output is labeled "(empirical)" and comes from the locally installed `mise 2026.8.8`.

---

## Question A — Can plugin install/update trigger a script that regenerates `[tool_alias]` config?

**Short answer: no.**
No mise hook, no vfox/backend-plugin lifecycle hook, and no documented plugin-ecosystem convention fires anything on `mise plugin install` or `mise plugin update`.
The only viable channels are voluntary ones: a shell command the user/bootstrap runs, or a mise task the user invokes with `mise run`.

### A.1 — mise's global hook system (`[hooks]` in mise.toml)

The hook enum is a closed, five-member set, defined in one place:

```rust
// src/hooks.rs:46-52 (commit 33073d5)
pub enum Hooks {
    Enter,
    Leave,
    Cd,
    Preinstall,
    Postinstall,
}
```
Source: [`src/hooks.rs#L46-L52`](https://github.com/jdx/mise/blob/33073d5e26bb82becbb3d248581d2efedf889078/src/hooks.rs#L46-L52).

There is no `PluginInstall`, `PluginUpdate`, or startup/init hook variant.
The doc page confirms the same five, with the same semantics: cd/enter/leave require `mise activate`; preinstall/postinstall do not.
"You cannot use these without the `mise activate` shell hook installed in your shell—except the `preinstall` and `postinstall` hooks."
Source: [mise.jdx.dev/hooks.html](https://mise.jdx.dev/hooks.html), doc source [`docs/hooks.md`](https://github.com/jdx/mise/blob/33073d5e26bb82becbb3d248581d2efedf889078/docs/hooks.md).

Critically, **preinstall/postinstall fire on *tool version* installs, not plugin installs.**
Every call site that schedules or runs `Hooks::Preinstall`/`Hooks::Postinstall` is inside the tool-install path, never the plugin-install path:

```
src/toolset/toolset_install.rs:184  hooks::run_one_hook_with_context(..., Hooks::Preinstall, ...)
src/toolset/toolset_install.rs:291  hooks::run_one_hook_with_context(..., Hooks::Postinstall, ...)
src/toolset/toolset_install.rs:308  hooks::run_one_hook_with_context(..., Hooks::Postinstall, ...)
src/cli/install.rs:579-582          hooks::run_one_hook_with_context(..., Hooks::Postinstall, ...)
```
Source: grep of `schedule_hook|run_one_hook` across `src/` at commit 33073d5.
`toolset_install.rs` backs `mise install <tool>@<version>`, `src/cli/install.rs` backs the top-level `mise install` command.

`src/cli/plugins/install.rs` (`mise plugins install`) and `src/cli/plugins/update.rs` (`mise plugins update`) were read in full: neither imports `hooks`, calls `schedule_hook`, or calls `run_one_hook*` anywhere.
`install_plugin()` just resolves the plugin type, sets the remote URL, and calls `plugin.ensure_installed(...)` (a git clone);
`Update::run()` just calls `plugin.update(pr, ref_)` (a git pull/checkout).
Source: [`src/cli/plugins/install.rs#L135-L166`](https://github.com/jdx/mise/blob/33073d5e26bb82becbb3d248581d2efedf889078/src/cli/plugins/install.rs#L135-L166), [`src/cli/plugins/update.rs#L31-L67`](https://github.com/jdx/mise/blob/33073d5e26bb82becbb3d248581d2efedf889078/src/cli/plugins/update.rs#L31-L67).

Empirical (`mise plugins install --help`) confirms the doc/source read: the only documented side effect of `plugins install` is "mise can automatically install plugins when you install a tool";
nothing about running scripts on install.

**Implication:** even if mise-vault shipped a `[hooks] postinstall = "..."` in its own generated conf.d file, it would not fire on `mise plugin update mise-vault` — it only fires around `mise install <tool>@<version>`, and only for config files already loaded into that mise invocation's config tree.
Global/user config qualifies, since preinstall/postinstall hooks are not directory-scoped the way enter/leave/cd are — see `src/hooks.rs:410-416`, which skips directory matching for `Preinstall|Postinstall` and instead only checks CWD-under-root for non-global hooks.
That's a real, working trigger for "when the user next installs *any* tool," but not for "when the plugin itself updates."

### A.2 — vfox/backend-plugin lifecycle hooks

The vfox reimplementation lives in `crates/vfox` (a first-party Rust crate mise vendors, not the upstream Go vfox project) and defines a much larger hook surface than the three Backend* hooks:

```
crates/vfox/src/hooks/available.rs
crates/vfox/src/hooks/backend_exec_env.rs
crates/vfox/src/hooks/backend_install.rs
crates/vfox/src/hooks/backend_list_versions.rs
crates/vfox/src/hooks/env_keys.rs
crates/vfox/src/hooks/mise_env.rs
crates/vfox/src/hooks/mise_path.rs
crates/vfox/src/hooks/package.rs
crates/vfox/src/hooks/parse_legacy_file.rs
crates/vfox/src/hooks/post_install.rs
crates/vfox/src/hooks/pre_install.rs
crates/vfox/src/hooks/pre_uninstall.rs
crates/vfox/src/hooks/pre_use.rs
```
Source: `find crates/vfox -iname "*.rs"` at commit 33073d5.

All of these except the three Backend* hooks belong to the **traditional (single-tool, asdf-equivalent) vfox plugin type**, not backend plugins.
`PostInstall`/`PreInstall` in this list are *per-tool-version* install hooks (they receive `runtimeVersion`, mirroring asdf's `bin/install`), confirmed by the context struct:

```rust
// crates/vfox/src/hooks/post_install.rs:19-23
pub struct PostInstallContext {
    pub root_path: PathBuf,
    pub runtime_version: String,
    pub sdk_info: BTreeMap<String, SdkInfo>,
}
```
Source: [`crates/vfox/src/hooks/post_install.rs#L19-L23`](https://github.com/jdx/mise/blob/33073d5e26bb82becbb3d248581d2efedf889078/crates/vfox/src/hooks/post_install.rs#L19-L23).

Backend plugins are explicitly gated away from this hook set at the call site.
`src/backend/vfox.rs` checks `self.is_backend_plugin()` before calling any non-Backend* hook, and skips it otherwise — e.g. uninstall:

```rust
// src/backend/vfox.rs:414-421 (uninstall_version_impl)
if self.is_backend_plugin() || !self.plugin.is_installed() {
    return Ok(());
}
... vfox.pre_uninstall(...) ...
```
Source: [`src/backend/vfox.rs#L414-L429`](https://github.com/jdx/mise/blob/33073d5e26bb82becbb3d248581d2efedf889078/src/backend/vfox.rs#L414-L429).
`pre_uninstall` (and by the same pattern, `available`/`mise_env`/`pre_install`/`pre_use`/etc.) only runs for the legacy plugin type, never for backend plugins.

The doc page for backend plugins is explicit and matches the source: "They use three main backend methods... `hooks/backend_list_versions.lua`... `hooks/backend_install.lua`... `hooks/backend_exec_env.lua`."
No fourth hook, no install/update-time hook, no startup hook is documented for backend plugins.
Source: [mise.jdx.dev/backend-plugin-development.html](https://mise.jdx.dev/backend-plugin-development.html), doc source [`docs/backend-plugin-development.md`](https://github.com/jdx/mise/blob/33073d5e26bb82becbb3d248581d2efedf889078/docs/backend-plugin-development.md).

`metadata.lua` (`PLUGIN = {...}`) capabilities were also checked directly: `Metadata::try_from(Table)` parses `name`, `legacyFilenames`, `depends`, `version`, `description`, `author`, `license`, `homepage`, `systemDependencies`.
No lifecycle-callback field, no "on install" script reference.
Source: [`crates/vfox/src/metadata.rs#L64-L92`](https://github.com/jdx/mise/blob/33073d5e26bb82becbb3d248581d2efedf889078/crates/vfox/src/metadata.rs#L64-L92).

Finally, the plugin-install code path itself (`src/plugins/vfox_plugin.rs::ensure_installed`) was read: it does a git clone/checkout, records the plugin in `install_state`, and returns.
It never constructs a `Vfox`/`Plugin` Lua runtime or calls any hook function during install.
Source: [`src/plugins/vfox_plugin.rs#L244-L306`](https://github.com/jdx/mise/blob/33073d5e26bb82becbb3d248581d2efedf889078/src/plugins/vfox_plugin.rs#L244-L306).

### A.3 — Other trigger channels

- **mise tasks**: confirmed the standard mechanism for "user-invoked regeneration."
  Tasks defined in *any* merged config file — including `~/.config/mise/conf.d/*.toml`, which is a first-class, alphabetically-loaded config-fragment location — become part of the global task registry and are runnable from anywhere with `mise run <name>` (alias `mise r`).
  Source: [mise.jdx.dev/configuration.html](https://mise.jdx.dev/configuration.html) §"`mise.toml`", doc source [`docs/configuration.md#L13-L16`](https://github.com/jdx/mise/blob/33073d5e26bb82becbb3d248581d2efedf889078/docs/configuration.md#L13-L16): "`.config/mise/conf.d/*.toml` - all non-hidden TOML files in this directory will be loaded in alphabetical order."
  Task hooks (`[hooks] enter = { task = "setup" }`) exist but are still gated by the same five-hook enum from A.1: a task can be *referenced by* a hook, it doesn't add a new trigger point.
  Source: [`docs/hooks.md`](https://github.com/jdx/mise/blob/33073d5e26bb82becbb3d248581d2efedf889078/docs/hooks.md) §"Task hooks".
- **`mise generate`**: this subcommand exists (`mise generate` / `mise gen`, confirmed in `mise --help` (empirical)) but it is a one-shot scaffolding generator (task docs, git-ignore-style config, JSON schema, etc.), not a lifecycle hook.
  It's invoked by a human/CI, never automatically by mise itself.
  Not investigated further since it has no bearing on automatic triggering — it's the same shape as a manual task.
- **"Plugin post-install script" convention**: no such convention exists in mise's or vfox's plugin ecosystem.
  asdf plugins have a `bin/install` script, but that runs per-tool-version (equivalent to vfox's `PostInstall`, confirmed A.2), not per-plugin-repo-update.
  No first-party or community mise/vfox plugin was found (nor documented) that regenerates host config on its own install/update.

### A.4 — Fallback designs (no automatic trigger exists)

Given A.1–A.3, here is a pros/cons read on the three fallback shapes named in the brief:

**(a) Bootstrap installs a `vault-sync` shell command (from the plugin repo) that does git-checkout-new-tag + regenerate conf.d file.**
- Pros: works from any shell, no mise-specific machinery, easy to wire into cron/CI for unattended refresh, trivially testable in isolation.
- Cons: fully manual/out-of-band — nothing tells the user it's stale.
  Needs its own install step (PATH entry, or a wrapper) separate from `mise plugins install`, so it's one more thing to document and one more thing that can drift from the plugin version.

**(b) A mise task defined in the generated conf.d file itself, so `mise run vault-sync` works.**
- Pros: uses mise's own discovery — no extra install step, appears in `mise tasks` automatically, works the moment the conf.d file exists, consistent with how any mise user already invokes maintenance tasks in this ecosystem.
  Confirmed viable per A.3 (conf.d files support `[tasks]` like any other mise.toml).
- Cons: bootstrapping problem — the very-first bootstrap (before the conf.d file exists) can't rely on this task.
  Still fully manual (`mise run vault-sync` doesn't fire itself);
  if the conf.d file is ever hand-deleted or corrupted the task disappears with it, which is arguably a feature (fail loud) but worth flagging.
- This is the cheapest, most idiomatic-to-mise option of the three: (a) requires a separate installed binary and (c) requires hooking a data-fetch call into a side-effecting write.

**(c) `BackendListVersions` opportunistically warns when the alias file is stale.**
- Pros: fires on a genuinely common path (`mise ls-remote`, `mise install`, `mise use` all call it — confirmed at [`src/backend/vfox.rs#L163-L183`](https://github.com/jdx/mise/blob/33073d5e26bb82becbb3d248581d2efedf889078/src/backend/vfox.rs#L163-L183)), so it's the closest thing to "automatic" available.
  A plugin using `vfox-npm`'s pattern already shells out via `cmd.exec`/`require("cmd")` in this hook (confirmed in the doc's real-world example), so a `stat`/version-check call is unremarkable there.
- Cons on "can a hook write files / is that sane?": technically yes but awkward.
  The Lua `file` module exposed to plugins has `read`, `symlink`, `join_path`, `exists`, `stat`, `list`, `glob`, `move` — **no `write`** — confirmed by enumerating every entry registered in `mod_file()`.
  Source: [`crates/vfox/src/lua_mod/file.rs#L22-L54`](https://github.com/jdx/mise/blob/33073d5e26bb82becbb3d248581d2efedf889078/crates/vfox/src/lua_mod/file.rs#L22-L54).
  A plugin could still shell out via `cmd.exec`/`os.execute` (both exposed, confirmed [`crates/vfox/src/lua_mod/cmd.rs#L8-L12`](https://github.com/jdx/mise/blob/33073d5e26bb82becbb3d248581d2efedf889078/crates/vfox/src/lua_mod/cmd.rs#L8-L12)) to write the file that way, but this means every `mise ls-remote`/`mise install`/`mise use` call pays the cost of a stat + possible warn.
  A hook that *writes user config as a side effect of listing versions* is a surprising, hard-to-reason-about design — most users don't expect `ls-remote` to mutate `~/.config/mise/conf.d/*.toml`.
  A warn-only version (no write) is safer and still useful.

**Recommendation for A**: combine (b) as the primary mechanism (a task in the generated conf.d file — zero extra install surface, idiomatic) with a lightweight, warn-only version of (c) (BackendListVersions checks a version marker and prints "run `mise run vault-sync` to pick up N new tools," never writes).
Skip (a) as a separate installed binary unless there's a concrete need to run sync from outside a shell that has mise/plugin access — the mise task can shell out to the same underlying logic mise-vault would put in a standalone script, so (a)'s logic and (b)'s trigger are not mutually exclusive;
the write side is the same script either way.

---

## Question B — How can the Nexus base URL be configured/overridden?

### B.1 — Does `os.getenv()` in a plugin hook see mise's `[env]` section?

**No, not reliably, and not by default.**
This required tracing the actual environment-plumbing code, since neither doc addresses it directly.

`os.getenv` and `os.execute` in vfox Lua plugins are **not** stock Lua — mise replaces them:

```rust
// crates/vfox/src/lua_mod/cmd.rs:100-106
fn os_getenv(lua: &Lua, key: String) -> LuaResult<Option<String>> {
    if let Ok(mise_env) = lua.named_registry_value::<Table>("mise_env") {
        return lookup_env_table(&mise_env, &key);
    }
    Ok(std::env::var(key).ok())
}
```
Source: [`crates/vfox/src/lua_mod/cmd.rs#L100-L106`](https://github.com/jdx/mise/blob/33073d5e26bb82becbb3d248581d2efedf889078/crates/vfox/src/lua_mod/cmd.rs#L100-L106).
The surrounding comment explains why: "Route Lua's `os.execute` and `os.getenv` through mise's sanitized env (registry `mise_env`)... During a combined `mise install`, [the raw process env] can carry stale `tools = true` values...
Plugins that shell out via `os.execute` would otherwise use the stale value and fail.
When `mise_env` is unset, `os.execute`/`os.getenv` behave like stock."
Source: same file, lines 82-95, referencing mise issues #10282/#10711.

So there are two regimes:
1. **`mise_env` registry table is set** (the common case for backend hooks, see below): `os.getenv` reads *only* from that constructed table, ignoring the real process env entirely.
2. **`mise_env` unset**: falls back to `std::env::var`, i.e. the raw OS environment mise's own process was launched with (which is not the same thing as mise's resolved `[env]` config section).

For backend plugins, the `mise_env` table is populated per hook call site, and **what it contains differs by hook**:

- **`BackendListVersions`** (`_list_remote_versions`, used by `mise ls-remote`, `mise install`, `mise use`): `cmd_env` is set to `dependency_env(config)` only — dependency-tool `PATH` entries, built via `full_env_without_tools` specifically *to avoid* triggering `tools = true` env-module directives.
  Source: [`src/backend/vfox.rs#L153-L161`](https://github.com/jdx/mise/blob/33073d5e26bb82becbb3d248581d2efedf889078/src/backend/vfox.rs#L153-L161), [`src/backend/mod.rs#L3680-L3690`](https://github.com/jdx/mise/blob/33073d5e26bb82becbb3d248581d2efedf889078/src/backend/mod.rs#L3680-L3690).
  **A plain `[env] MISE_VAULT_NEXUS_URL = "..."` entry in mise.toml is never included here.**
- **`BackendInstall`** (`install_version_`): `cmd_env` is built from dependency env + tool options (see B.2) + `tv.install_env()` + a narrow "tools=true value directive" pass, and finally a `restore_config_tool_option_env` step that copies back **only** keys matching `MISE_TOOL_OPTS__*`/`RTX_TOOL_OPTS__*` from the full resolved config env.
  `tv.install_env()` is a **per-tool `[tools]` option**, not the global `[env]` section — `self.request.options().core.install_env`, source [`src/toolset/tool_version.rs#L239-L241`](https://github.com/jdx/mise/blob/33073d5e26bb82becbb3d248581d2efedf889078/src/toolset/tool_version.rs#L239-L241).
  ```rust
  // src/backend/vfox.rs:73-80
  fn is_tool_option_env_key(key: &str) -> bool {
      let matches = |key: &str| key.starts_with("MISE_TOOL_OPTS__") || key.starts_with("RTX_TOOL_OPTS__");
      ...
  }
  ```
  Source: [`src/backend/vfox.rs#L73-L92`](https://github.com/jdx/mise/blob/33073d5e26bb82becbb3d248581d2efedf889078/src/backend/vfox.rs#L73-L92).
  The "tools=true value directive" pass (lines 232-273) is filtered by `ToolsFilter::ToolsOnlyVals`, which requires the directive be a plain `Val` **and** explicitly marked `tools = true`:
  ```rust
  // src/config/env_directive/mod.rs:481-483
  ToolsFilter::ToolsOnlyVals => {
      directive.options().tools && matches!(directive, EnvDirective::Val(..))
  }
  ```
  Source: [`src/config/env_directive/mod.rs#L365-L377`](https://github.com/jdx/mise/blob/33073d5e26bb82becbb3d248581d2efedf889078/src/config/env_directive/mod.rs#L365-L377) and [`#L481-L483`](https://github.com/jdx/mise/blob/33073d5e26bb82becbb3d248581d2efedf889078/src/config/env_directive/mod.rs#L481-L483).
  **A plain `[env] MISE_VAULT_NEXUS_URL = "https://..."` (no `tools = true` marker) is excluded by this filter too.**
  Only `[env] MISE_VAULT_NEXUS_URL = { value = "https://...", tools = true }` would pass, and even then only reaches `BackendInstall`, never `BackendListVersions`.

**Conclusion for B.1**: mise's `[env]` config section is deliberately *not* a general channel into vfox backend-plugin Lua code.
The plumbing that does exist (`mise_env` registry table) is scoped to dependency-tool PATHs and a narrow `tools=true`-marked value-directive case for `BackendInstall` only.
Relying on `os.getenv("MISE_VAULT_NEXUS_URL")` picking up a plain `[env]` entry is **not confirmed to work and source evidence says it won't**, for either hook mise-vault would use.
This reading is from source only — no PoC plugin was built/run to double-check empirically;
recommend a throwaway PoC plugin before committing to any env-based design (see "Key risks / unknowns").

### B.2 — `ctx.options` for backend plugins: do bracketed alias opts flow through?

**Yes, confirmed by source, exactly as the design proposes.**

`split_bracketed_opts` parses a trailing `[...]` block off any backend-arg-shaped string, with quote-aware parsing (so `nexus_url` values containing commas/brackets in quotes are safe):

```rust
// src/cli/args/backend_arg.rs:110-113
/// Split a string like `"http:hello[url=...,bin=bin]"` into `("http:hello", "url=...,bin=bin")`.
pub fn split_bracketed_opts(s: &str) -> Option<(&str, &str)> { ... }
```
Source: [`src/cli/args/backend_arg.rs#L110-L139`](https://github.com/jdx/mise/blob/33073d5e26bb82becbb3d248581d2efedf889078/src/cli/args/backend_arg.rs#L110-L139).

`[tool_alias]` is the current (non-deprecated) TOML key — `[alias]` is the deprecated predecessor, merged with `tool_alias` taking precedence.
Source: [`src/config/config_file/mise_toml.rs#L1543-L1551`](https://github.com/jdx/mise/blob/33073d5e26bb82becbb3d248581d2efedf889078/src/config/config_file/mise_toml.rs#L1543-L1551) ("`[alias] is deprecated, use [tool_alias] instead`").
Also visible empirically: `mise tool-alias --help` (empirical) exposes `get`/`ls`/`set`/`unset` subcommands for exactly this table.

`Config::get_backend_alias_opts` reads the alias's `backend` string (i.e., the right-hand side of `tool_alias.go = "vault:go[nexus_url=...]"`), splits off the bracketed opts, and parses them into `ToolVersionOptions`:

```rust
// src/config/mod.rs:467-477
fn get_backend_alias_opts(&self, backend_arg: &BackendArg) -> Option<ToolVersionOptions> {
    if backend_arg.has_env_backend_override() { return None; }
    let short = backend::unalias_backend(&backend_arg.short);
    self.all_aliases
        .get(short)
        .and_then(|alias| alias.backend.as_deref())
        .and_then(|backend| split_bracketed_opts(backend).map(|(_, opts)| opts))
        .map(crate::toolset::parse_tool_options)
}
```
Source: [`src/config/mod.rs#L467-L477`](https://github.com/jdx/mise/blob/33073d5e26bb82becbb3d248581d2efedf889078/src/config/mod.rs#L467-L477).

These `alias_opts` feed into `resolve_tool_opts_with_overrides`, which layers option sources in this precedence order (later call wins): registry opts → install-manifest opts → (only if no alias opts) the alias's own "full opts" → **alias opts (bracketed, from `[tool_alias]`)** → `[tools]`-table config opts → inline backend-arg opts (e.g. `mise install vault:go[nexus_url=...]@1.2` typed on the CLI).
Source: [`src/config/mod.rs#L429-L465`](https://github.com/jdx/mise/blob/33073d5e26bb82becbb3d248581d2efedf889078/src/config/mod.rs#L429-L465).
**Note the precedence: `[tools]`-table config opts and inline CLI opts both override alias-bracketed opts.**
A bracketed default on `[tool_alias]` acts as a *fallback*, not a hard override, which matches "generated conf.d default" rather than "forced value."

This resolved option map is what actually reaches `ctx.options` in Lua for both hooks mise-vault needs:

```rust
// src/backend/vfox.rs:167-175 (_list_remote_versions / BackendListVersions)
let opts = config.get_tool_opts_with_overrides(&this.ba).await?
    .into_backend_options().into_map();
let versions = vfox.backend_list_versions(&this.pathname, tool_name, opts).await?;
```
Source: [`src/backend/vfox.rs#L166-L175`](https://github.com/jdx/mise/blob/33073d5e26bb82becbb3d248581d2efedf889078/src/backend/vfox.rs#L166-L175).
The `BackendInstall` path resolves the same way via `tool_options_for_tv` before calling `vfox.backend_install(...)` at [`src/backend/vfox.rs#L218-L296`](https://github.com/jdx/mise/blob/33073d5e26bb82becbb3d248581d2efedf889078/src/backend/vfox.rs#L218-L296).

On the Lua side, `BackendListVersionsContext`/`BackendInstallContext` serialize the options map straight into `ctx.options` (a Lua table), types preserved (`toml::Value` → native Lua string/array/table).
Confirmed both by the struct definitions ([`crates/vfox/src/hooks/backend_list_versions.rs#L7-L9`](https://github.com/jdx/mise/blob/33073d5e26bb82becbb3d248581d2efedf889078/crates/vfox/src/hooks/backend_list_versions.rs#L7-L9), [`crates/vfox/src/hooks/backend_install.rs#L9-L15`](https://github.com/jdx/mise/blob/33073d5e26bb82becbb3d248581d2efedf889078/crates/vfox/src/hooks/backend_install.rs#L9-L15)) and by the doc: "Option values preserve their TOML types as native Lua equivalents... `channels = ["conda-forge", "robostack"]` in `mise.toml` becomes a Lua table you can iterate with `ipairs(ctx.options.channels)`."
Source: [mise.jdx.dev/backend-plugin-development.html](https://mise.jdx.dev/backend-plugin-development.html) §"Context Variables".

**Conclusion for B.2**: `go = "vault:go[nexus_url=https://nexus.corp.com]"` in `[tool_alias]` is a confirmed, working channel into `ctx.options.nexus_url` for both `BackendListVersions` and `BackendInstall`.
This is the single most solid finding in this document — it's traced end-to-end through source with no gaps or fallback branches to worry about, unlike B.1.

### B.3 — Plugin-scoped config file conventions

No `[plugins.<name>]` settings namespace exists in mise — searched `src/config/*.rs` and the full `docs/` tree for any such key;
nothing was found.
There is no mise-blessed convention for a plugin to read its own config file either — `Config::get_backend_alias_opts` and the tool-options machinery are the only "config reaches the plugin" paths mise provides.

A plugin *can* still read an arbitrary file of its own choosing via the Lua `file` module (`file.read`, `file.exists`, confirmed present at [`crates/vfox/src/lua_mod/file.rs#L22-L54`](https://github.com/jdx/mise/blob/33073d5e26bb82becbb3d248581d2efedf889078/crates/vfox/src/lua_mod/file.rs#L22-L54)), e.g. `~/.config/mise-vault/config.toml`, and parse it itself.
No built-in TOML/JSON parser was found registered as a Lua module besides `json` — confirmed the module list is `log, hooks, json, http, strings, archiver, semver, file, cmd, html, env`, source: `crates/vfox/src/lua_mod/mod.rs` file listing above.
This is a plugin-repo-invented convention, not something mise recognizes or merges — it competes with, rather than integrates into, mise's own config-resolution/precedence system (mise.toml chain, `mise cfg`, `MISE_ENV`, etc.), so a value set there wouldn't show up in `mise cfg` or be overridable the way `[tools]`/`[tool_alias]` opts are.

### B.4 — Recommended precedence design

Given the confirmed/unconfirmed split above, recommend:

1. **Per-tool bracketed option on `[tool_alias]`** (confirmed, B.2) — the generated conf.d file's default, e.g. `go = "vault:go[nexus_url=https://nexus.corp.com]"`.
   This is the mechanism to build the "generated conf.d default" tier on, since it's mise-native, shows up in `mise cfg`, and is overridable per the documented precedence.
2. **`[tools]`-table override** (confirmed, B.2, same machinery — `config_opts` layered after `alias_opts` in `resolve_tool_opts_with_overrides`) — lets a user override the default per-project without touching the generated file, e.g. `[tools] "vault:go" = { nexus_url = "https://staging-nexus.corp.com" }`.
3. **Inline CLI bracketed opt** (confirmed, B.2, highest-precedence `InlineBackendArg` source) — e.g. `mise install vault:go[nexus_url=...]@1.2` for one-off overrides/debugging.
4. **Env var** (`MISE_VAULT_NEXUS_URL` or similar) — **not confirmed**, and source evidence in B.1 says it will *not* reach `os.getenv()` for a plain `[env]` entry in either hook mise-vault needs.
   Do not build a load-bearing design around this without a PoC.
   If a PoC confirms a workable channel (e.g. relying on regime 2 in B.1 — the raw-process-env fallback, which only works if the *actual invoking shell* already has the var exported, such as via a real `export MISE_VAULT_NEXUS_URL=...` in `.bashrc`/`.profile`, independent of mise's own `[env]` machinery), treat that as a "for users who set real shell env vars" escape hatch, not a mise-config-driven one.
5. **Plugin-repo default file** (B.3, e.g. a `nexus_url` hardcoded in metadata.lua or a bundled default) — lowest precedence, ships-with-the-plugin fallback.

Net recommendation: build the real design around tiers 1-3 (all confirmed via source), since they compose naturally through mise's existing `ToolOptionSource` precedence chain (`Registry < InstallManifest < BackendAlias < Config < InlineBackendArg`, [`src/config/mod.rs#L429-L465`](https://github.com/jdx/mise/blob/33073d5e26bb82becbb3d248581d2efedf889078/src/config/mod.rs#L429-L465)) and require zero new plumbing.
Treat env-var support as a stretch goal pending a PoC, not a documented feature, until verified.

---

## Key risks / unknowns

- **B.1 env-var channel is source-derived, not empirically verified.**
  No throwaway backend plugin was built/installed to actually call `os.getenv("MISE_VAULT_NEXUS_URL")` from `BackendListVersions`/`BackendInstall` and observe the result under a real `[env]` entry (plain, and `tools = true`-marked).
  The source reading is unambiguous but a PoC would catch anything version-specific or any code path this research missed (e.g. a different call path for `mise use` vs `mise install` vs `mise ls-remote` that wasn't individually traced).
- **A.4(c)'s "does a hook writing config files misbehave with mise's own config cache/watch behavior?"** was not investigated.
  mise caches parsed config per-process (and possibly across the `ALL_HOOKS`/`OnceCell` seen in `src/hooks.rs:312-341`);
  a hook-triggered write mid-command could interact oddly with in-process caching or with `mise watch_files`.
  If (c) is pursued even as warn-only, keep the write path (if ever added) confined to option (b)'s explicit task, not the passive `BackendListVersions` hook.
- **Global-hook directory scoping details** (`src/hooks.rs:378-419`) were read closely enough to confirm preinstall/postinstall aren't directory-scoped the way enter/leave/cd are, but the exact interaction between `global: true` hooks and monorepo/nested-project configs was not fully traced — worth a second pass if mise-vault ever leans on `[hooks] postinstall` as part of the design (currently not recommended, see A.4).
- **`mise generate` subcommands** were not enumerated one-by-one (confirmed only that the top-level command exists and is scaffolding-oriented, empirically via `mise --help`).
  If a future design wants to lean on `mise generate` for anything, it needs its own pass.
- This document did not attempt to install a private Nexus-backed vfox plugin end-to-end.
  All findings are static-source/doc analysis plus local `mise --help`/`mise settings ls`/`mise tool-alias --help` empirical spot-checks against the installed mise 2026.8.8 binary, not a running mise-vault plugin.

## Recommended design

- **Config regeneration (Question A)**: no automatic trigger exists on `mise plugin install`/`update`.
  Ship a mise task in the generated `~/.config/mise/conf.d/*.toml` file (e.g. `[tasks.vault-sync]`) as the primary, idiomatic-to-mise mechanism (`mise run vault-sync`), backed by the same script logic option (a) would use, so both can share one implementation.
  Optionally add a warn-only staleness check inside `BackendListVersions` (no file writes from that hook) pointing the user at the task.
  Document the task prominently since nothing will remind the user automatically beyond that warning.
- **Nexus URL (Question B)**: use `[tool_alias] <tool> = "vault:<tool>[nexus_url=https://...]"` as the generated default (confirmed end-to-end via `split_bracketed_opts` → `get_backend_alias_opts` → `resolve_tool_opts_with_overrides` → `ctx.options`), let `[tools]`-table entries and inline CLI brackets override it (same confirmed precedence chain), and treat an env-var override as unverified/future work pending a PoC rather than a documented supported path.

---

## Correction (2026-08-19) — the PoC this document asked for was run, and B.1's source reading does not hold empirically

"Key risks / unknowns" above flagged that B.1 was source-derived
and recommended a throwaway PoC plugin before committing to any env-based design.
That PoC was run against the installed mise 2026.8.8:
instrumented `BackendListVersions` and `BackendInstall` hooks in an isolated `$HOME`,
probing `os.getenv` directly.
Observed, in BOTH hooks:

- a plain shell-exported variable (`MISE_VAULT_NEXUS_URL`, plus an unprefixed control variable)
  IS returned by `os.getenv`;
- a plain `[env] VAR = "value"` entry in a trusted `mise.toml` IS returned by `os.getenv`
  when the command runs inside that project directory — no `{ tools = true }` marker needed;
- ordinary process variables (`HOME`, `PATH`, `USER`) are visible as well;
- subprocesses spawned via the `cmd` module see the same values.

So on the currently installed mise,
`os.getenv` in these two hooks behaves like the stock function reading the (config-augmented) process environment.
The sanitized `mise_env` registry-table behavior traced from source at commit 33073d5e either changed in a later release
or does not gate these code paths the way the trace concluded.
Per the repository's verification discipline the experiment wins:
the env-var channel IS usable.

Consequence:
D6's "env-var override is NOT a supported path" is amended (see SYNTHESIS.md section 18) —
`MISE_VAULT_NEXUS_URL` is now the highest-precedence Nexus URL channel,
validated like every other channel in `lib/common.lua` and covered by poc-test.
The B.1/B.4 text above is retained unedited as the record of what the source trace concluded.
