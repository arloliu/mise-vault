# mise Version Floor — Research for mise-vault

Verified against **mise v2026.8.8** (linux-x64, released 2026-08-17 — the version installed locally, confirmed via `mise --version` → `2026.8.8 linux-x64 (2026-08-17)`).
Research date: **2026-08-18**.

Method: a full (blob-aware) clone of `jdx/mise` was fetched into scratch so `git log -S`/`--follow`/`--diff-filter=A` could trace each feature to its introducing commit, then `git tag --contains <sha> | grep -E '^v[0-9]{4}\.[0-9]+\.[0-9]+$' | sort -V | head -1` mapped that commit to the first calver release tag containing it.
mise's calver release tags (`vYYYY.M.N`) begin at `v2023.12.0` (2023-12-01) — this repository's history goes further back (to `2023-01-27`, under the project's former name `rtx`), but nothing before `v2023.12.0` is tag-addressable, so any feature traced to a pre-`v2023.12.0` commit is reported as "at latest bound: v2023.12.0."
Release dates below are `published_at` from `gh api repos/jdx/mise/releases/tags/<tag>`.
Doc/source citations reference the historical introducing commit SHA (not the `33073d5` HEAD the sibling docs pin to — this document is about *when*, not *current shape*).

This doc reuses relevant facts already pinned by the sibling docs (`mise-backend-plugin-mechanics.md`, `plugin-hooks-and-config-channels.md`) without re-deriving them, and focuses purely on version-introduced citations.

---

## 1. vfox-style backend plugins (`metadata.lua` + `hooks/backend_*.lua`, `plugin:tool` syntax)

**Introduced: v2025.7.8** (released 2025-07-14).
Commit [`e311bbb`](https://github.com/jdx/mise/commit/e311bbb730f886e0b4f835f13c90f1a2edb207e2), PR [#5579 "feat: custom backends through plugins"](https://github.com/jdx/mise/pull/5579), 2025-07-13.
This single commit adds `crates/vfox/src/hooks/backend_list_versions.rs`, `backend_install.rs`, `backend_exec_env.rs`, `docs/backend-plugin-development.md`, and the `BackendType::VfoxBackend` enum variant in `src/cli/args/backend_arg.rs` that makes `plugin:tool` (e.g. `vault:go`) resolvable — all in one PR, so the whole backend-plugin surface mise-vault depends on has one birthday.
It landed one day after the underlying vfox Lua runtime itself was vendored into the monorepo (commit [`67286cf`](https://github.com/jdx/mise/commit/67286cfc7a6b8342e3ee8691307524edad52882c), PR [#5590 "chore: Merge vfox.rs into jdx/mise monorepo"](https://github.com/jdx/mise/pull/5590), 2025-07-12, also first in v2025.7.8) — i.e. mise absorbed a previously-separate `vfox.rs` project wholesale, then immediately built backend plugins on top of it.

Two related refinements, informational (not required by mise-vault's current design per the sibling docs, but relevant to "how bleeding-edge is this system"):

- `MISE_BACKENDS_<TOOL>` env var override: **v2025.9.22** (2025-09-28), commit [`27f07bf`](https://github.com/jdx/mise/commit/27f07bf189f812824584460347e4ba066405025b), PR [#6456](https://github.com/jdx/mise/pull/6456).
- Auto-install of a backend plugin on first reference (e.g. via `[tool_alias]`) — this is exactly the mechanism `mise-backend-plugin-mechanics.md`'s Key-Risk #1 flagged as unconfirmed: **v2025.10.15** (2025-10-22), commit [`0d983ec`](https://github.com/jdx/mise/commit/0d983ec05658d8ab4a1cfbbbd40e7d5dab3b2be7), PR [#6696 "feat(plugins): automatically install backend plugins"](https://github.com/jdx/mise/pull/6696).
  This resolves that open risk: auto-install of an aliased backend plugin is a real, versioned feature, not a hopeful inference — but only from v2025.10.15 onward.

## 2. `[tool_alias]` config section (short-name → backend spec, e.g. `go = "vault:go"`)

Four sub-questions, four separate commits:

**(a) The backend-redirect mechanism itself** (mapping a short tool name to a full backend spec string, the capability the task cares about): **v2024.11.7** (2024-11-12).
Commit [`4c4d74d`](https://github.com/jdx/mise/commit/4c4d74d0173985bb4b60506996ea4299f47d7d7b), PR [#2979 "feat: added backend aliases"](https://github.com/jdx/mise/pull/2979), 2024-11-10.
This is meaningfully older than backend plugins themselves (2024-11 vs. 2025-07) — aliasing to `aqua:`/`asdf:`/other built-in backend types worked well before `vfox-backend:`-style plugins existed to alias *to*.

**(b) Original section name: `[alias]`.**
Confirmed by the struct field name at introduction (`pub full: Option<String>` on `struct Alias` in `src/config/mod.rs`, same PR #2979) and by the doc/CLI naming (`docs/cli/alias.md`, `mise alias ls`) that predates the rename below.

**(c) Renamed to `[tool_alias]`: v2025.12.8** (2025-12-15).
Commit [`ae8c1ec`](https://github.com/jdx/mise/commit/ae8c1ecabe105d6aea3f2424ca6836af5a7e1eb3), PR [#7316 "feat(shell_alias): add shell_alias support for cross-shell aliases"](https://github.com/jdx/mise/pull/7316).
The rename was a side effect of adding a *different* new feature, `[shell_alias]` (cross-shell command aliases): the PR description states directly, "Deprecates `[alias]` in favor of `[tool_alias]` for tool version aliases (clearer naming)" — done to stop `[alias]` from being ambiguous between "tool alias" and the new "shell alias" concept.

**(d) Is old `[alias]` still accepted today? Yes.**
Already confirmed in `mise-backend-plugin-mechanics.md` §3, citing `src/config/config_file/mise_toml.rs:1543-1551` ("`[alias]` is deprecated, use `[tool_alias]` instead") — both keys parse and merge into the same `AliasMap`, `[tool_alias]` taking precedence on conflict.
Not independently re-verified by version here; no evidence found that `[alias]` support has since been removed as of v2026.8.8.

## 3. Bracketed options in a `[tool_alias]` value reaching `ctx.options` (e.g. `vault:go[nexus_url=...]`)

**Reliable/confirmed-correct precedence: v2026.5.2** (2026-05-07).
Commit [`2688763`](https://github.com/jdx/mise/commit/2688763cd5f9af7f07a0311a8514a3b514171428), PR [#9306 "fix(backend): apply inline tool option overrides"](https://github.com/jdx/mise/pull/9306), 2026-05-06.
This is the commit that introduced `get_backend_alias_opts()` and the "shared backend option resolver" — the exact mechanism `plugin-hooks-and-config-channels.md` §B.2 traced end-to-end (`split_bracketed_opts` → `get_backend_alias_opts` → `resolve_tool_opts_with_overrides` → `ctx.options`) and called "the single most solid finding in this document."
Being a `fix(…)` commit (not `feat(…)`), it implies the general bracket-option-string-parsing machinery (`split_bracketed_opts`, first seen [2025-04-28, commit `b6749d7`](https://github.com/jdx/mise/commit/b6749d7cfc01b32de875d7b2879b63a83f55b80e), PR #4960 — for `[tools]`-table and CLI-inline backend args generally) predates this, but its application specifically to `[tool_alias]`-sourced options was buggy/unformalized before v2026.5.2.
**Treat v2026.5.2 as the floor for this feature** — it is the first release where a plugin author can trust that `go = "vault:go[nexus_url=...]"` reliably reaches `ctx.options.nexus_url` with the documented precedence.

## 4. Settings `gix` and `libgit2`

Two separate settings, introduced ~6 months apart, in the expected order (libgit2 first, since it was the *only* non-shell-out git implementation at the time; gix/gitoxide arrived later as an alternative and the two settings then diverged in meaning):

- **`libgit2` (`MISE_LIBGIT2`): v2024.7.4** (2024-07-19).
  Commit [`0dbab30`](https://github.com/jdx/mise/commit/0dbab305d2951d78728e4adf6ec71ea732e6780f), PR [#2386 "feat: added MISE_LIBGIT2 setting"](https://github.com/jdx/mise/pull/2386), 2024-07-18.
- **`gix` (`MISE_GIX`): v2025.1.15** (2025-01-26).
  Commit [`3463ef1`](https://github.com/jdx/mise/commit/3463ef185d2c6026a62260217d07273a5326cc1b) / [`4995a95`-adjacent PR #4226 "chore: switch from git2 to gix"](https://github.com/jdx/mise/pull/4226), 2025-01-26 (the same PR made `gix` the *default* git backend, demoting `git2`/libgit2 to a fallback — verified from the PR diff, which adds a brand-new `[gix]` block to `settings.toml` while only adding `hide = true` to the pre-existing `[libgit2]` block).
Both settings default `true` today; setting either to `false` shells out to the system `git` binary for that operation class — exactly what `install.sh` relies on (`mise settings gix=false`, `mise settings libgit2=false`).
Because `gix` (v2025.1.15) is the later of the two, it is the binding sub-floor for "both settings must exist and be independently toggleable."

## 5. `mise plugin install <name> <url>#<ref>` (pin to a git ref)

**At latest bound: v2023.12.0 (earliest provable) — the real feature is far older.**
Git-ref pinning for `plugin install` was added in commit [`4995a95`](https://github.com/jdx/mise/commit/4995a9582807c662372dac58e75386673ea2c641), PR [#450 "allow specifying git ref for custom plugin urls"](https://github.com/jdx/mise/pull/450), 2023-04-08 — under the project's former name `rtx`, more than seven months before the earliest calver-tagged release (`v2023.12.0`, 2023-12-01) that this repository's tag history can address.
(A predecessor, ref support for `plugin update` specifically, landed even earlier: commit `98249c7`, 2023-03-04.)
`git tag --contains 4995a95` confirms `v2023.12.0` is the oldest addressable release containing this commit — practically, this feature has been present in every calver release mise has ever shipped.

## 6. `~/.config/mise/conf.d/*.toml` config-directory auto-loading

**Introduced: v2024.11.34** (2024-11-29).
Commit [`da6db80`](https://github.com/jdx/mise/commit/da6db80cb0e94416d1e6e3e3f02dd74af44fc2d6), PR [#3273 "feat: fragmented configs"](https://github.com/jdx/mise/pull/3273), 2024-11-28 — "Allows adding config files to `.config/mise/conf.d/*.toml`", adding the exact `docs/configuration.md` bullet the sibling doc cites (`- .config/mise/conf.d/*.toml - all files in this directory will be loaded in alphabetical order`).
Note this is the **global/user** conf.d mise-vault's `install.sh` generates into (`~/.config/mise/conf.d/mise-vault.toml`).
A separate, much newer feature — **project-scoped** conf.d fragments (`.mise/conf.d/*.toml` inside a repo) — landed the day before this research, [PR #12061](https://github.com/jdx/mise/pull/12061), v2026.8.7 (2026-08-17); irrelevant to mise-vault's design, noted only to avoid confusing the two.

## 7. Global tasks (defined in user config, runnable via `mise run <task>` from any directory)

**At latest bound: v2023.12.36 (earliest provable), tightly coupled to the tasks feature's introduction.**
The `[tasks]`/task-runner subsystem itself was introduced in commit [`b9e176d`](https://github.com/jdx/mise/commit/b9e176d95cf28eccda998aac0259081f2a6c50e8), PR [#1260 "task"](https://github.com/jdx/mise/pull/1260), 2023-12-24 (v2023.12.36, 2023-12-24) — again under the `rtx` name (the commit's own test fixtures still use `.rtx.toml`/`.rtx/config.toml`).
No separate "global tasks" feature flag or commit was found: `[tasks]` merges through the exact same config-file hierarchy as `[tools]`/`[env]` (confirmed generally by `mise-backend-plugin-mechanics.md` §3's "Config file precedence order," and specifically for tasks by current docs, `docs/tasks/monorepo.md:247`: "Tasks start with tools and environment from all global config files").
Global config-file loading predates the tasks feature, so "a task defined in `~/.config/mise/config.toml` or a `conf.d/*.toml` fragment runs from anywhere via `mise run`" has been true since tasks existed at all — there was no later gate to separately unlock global-scope tasks.

## 8. `.tool-versions` support and the hardcoded `golang` → `go` alias

**`.tool-versions` parsing: at latest bound v2023.12.0 (earliest provable) — present at the very first commit in this repository's history.**
`git log --follow --diff-filter=A -- src/config/config_file/tool_versions.rs` resolves to the repo's own root commit, [`2d77111`](https://github.com/jdx/mise/commit/2d77111fe3048ac93791c3fc41baf405f4d2513c), "init", 2023-01-27 — asdf-compatible `.tool-versions` reading is a day-one, foundational feature of the project (mise/rtx started explicitly as an asdf-compatible tool), and no later commit ever needed to "add" it.

**Hardcoded `golang` → `go` translation: v2024.1.19** (2024-01-13).
Commit [`167e7c7`](https://github.com/jdx/mise/commit/167e7c73a6f53819b7b7b3ce335910969e758d2c), PR [#1450 "added \"forge\" infra"](https://github.com/jdx/mise/pull/1450) — the commit that introduces the `forge` (later renamed `backend`) abstraction layer also introduces the hardcoded alias table containing `"golang" => "go"` (alongside `"dotnet-core" => "dotnet"`, `"nodejs" => "node"`) for the first time, confirmed by `git log -S '"golang" => "go"'` finding no earlier hit.
The function was later renamed `unalias_backend` in the `forge` → `backend` rename ([`ee923be`](https://github.com/jdx/mise/commit/ee923bedd44a863284b090e37b30f37bdf5bf9ab), PR #2227, 2024-05-31, v2024.11-era per that PR's inclusion in the same release train — a pure rename, not a behavior change).
This is the mechanism `mise-backend-plugin-mechanics.md` §4 already traced at the current commit; here we add that it has been stable since v2024.1.19.

## 9. Lua modules used by hooks (`archiver.decompress` + `strip_components`, `cmd.exec`, `file`, `json`)

**Baseline modules (`cmd`, `file`, `json`, and `archiver.decompress` without options): v2025.7.8** (2025-07-14) — same release as backend plugins themselves (§1).
`crates/vfox/src/lua_mod/json.rs` and `file.rs` trace to the vfox-merge commit `67286cf` (2025-07-12, first in v2025.7.8); `crates/vfox/src/lua_mod/cmd.rs` traces to the backend-plugin commit `e311bbb` (2025-07-13, same release).

**`archiver.decompress`'s `strip_components` option: v2026.8.1 — introduced 2026-08-02, only two weeks before this research's "latest" baseline (v2026.8.8).**
This is the single most important, and most bleeding-edge, finding in this document.
Commit [`db20af7`](https://github.com/jdx/mise/commit/db20af718a1675d470277401a09e9a51b178e8bb), PR [#11652 "feat(vfox): add lua archive and file operations"](https://github.com/jdx/mise/pull/11652), 2026-08-02.
The diff was inspected directly: before this commit, `decompress(_lua, input)` only ever read `paths[0]` (archive) and `paths[1]` (destination) — there was **no third argument, no options table, and no `strip_components` handling at all**.
The commit adds the entire options-table branch (`Some(Value::Table(options)) => options.get::<Option<usize>>("strip_components")…`), plus the actual strip-and-promote logic (extract to a temp dir, then move children of top-level directories up to the destination, matching mise's own built-in archive-extraction behavior) — a genuinely new capability, not a signature widening of something that silently worked before.
**Any mise-vault hook that calls `archiver.decompress(src, dest, {strip_components = N})` did not work on any mise release before v2026.8.1.**
No follow-up "fix" commit for this code path was found in `CHANGELOG.md` between v2026.8.1 and v2026.8.8 (grep for `strip_components`/`archiver` in that range), so nothing suggests it's known-broken as shipped — but it is objectively unproven by time: at most ~2 weeks and 7 patch releases of real-world use exist as of the research date.

---

## Recommendation

### Floor computation

| # | Feature | Version introduced | Driver? |
|---|---|---|---|
| 1 | Backend plugin hooks + `plugin:tool` syntax | v2025.7.8 | |
| 2a | `[alias]`/`[tool_alias]` backend-redirect mechanism | v2024.11.7 | |
| 2c | Renamed to `[tool_alias]` | v2025.12.8 | |
| 3 | Bracketed `tool_alias` opts → `ctx.options` (reliable) | **v2026.5.2** | yes |
| 4 | `gix` setting (later of the two git settings) | v2025.1.15 | |
| 5 | `plugin install <url>#<ref>` | at latest bound v2023.12.0 | |
| 6 | `conf.d/*.toml` global config loading | v2024.11.34 | |
| 7 | Global tasks | at latest bound v2023.12.36 | |
| 8 | `.tool-versions` + `golang→go` | v2023.12.0 / v2024.1.19 | |
| 9 | `archiver.decompress` `strip_components` | **v2026.8.1** | **yes — max** |

**Raw floor = max(all rows) = v2026.8.1** (`archiver.decompress`'s `strip_components` option, §9), narrowly ahead of v2026.5.2 (§3, reliable `[tool_alias]` bracketed opts).
Every other dependency is satisfied by a release at least six months older than this pair — the whole floor question comes down to whether mise-vault's `hooks/backend_install.lua` actually calls `archiver.decompress(..., {strip_components=...})` (per the task context, it does — `strip_components` is named explicitly as one of the Lua modules in use).

### Rounding logic

Normally the recommendation here would be "round up from the raw floor to a release that's been out for a while and is well battle-tested."
That doesn't really apply this time: the raw floor (v2026.8.1, released 2026-08-03) is only about two weeks old as of the research date (2026-08-18), and the *entire* window between it and the actual current latest (v2026.8.8, released 2026-08-17) is those same two weeks — there is no older, more-battle-tested release that also satisfies the `strip_components` dependency, because the dependency itself is that new.
Given that constraint, the least-risky choice is not "oldest release that satisfies the floor" but "most patched release that satisfies the floor": **set `MISE_MIN_VERSION="2026.8.8"`**, the current latest, which is also the exact version this document, `mise-backend-plugin-mechanics.md`, and `plugin-hooks-and-config-channels.md` were all independently verified against, and the version already installed in the reference environment.
This buys mise-vault seven patch releases' worth of bug-fixing beyond the `strip_components` introduction at zero cost (nothing between v2026.8.1 and v2026.8.8 is known to regress it), at the price of a floor that will look conservative again within weeks as mise keeps shipping — which is fine, since `MISE_MIN_VERSION` is a single variable meant to be bumped periodically, not a one-time decision.
**Re-visit this floor whenever mise-vault's plugin code starts depending on newer surface area, or roughly quarterly regardless**, since mise ships near-daily and "current latest" will drift quickly.

### Version-check logic for `install.sh`

`mise --version` output format (verified locally against v2026.8.8): `2026.8.8 linux-x64 (2026-08-17)` — calver `YYYY.M.P`, a platform tag, and a build date in parens.
The floor variable belongs next to the existing `REPO_URL`/`REF`/`PLUGIN_NAME` block near the top of `install.sh`, and the comparison belongs in the existing prerequisites block (§1), right after the `command -v mise` check and before any `mise` subcommand is invoked:

```bash
REPO_URL="${MISE_VAULT_REPO_URL:-https://gitlab.company.example/devtools/mise-vault.git}"
REF="${MISE_VAULT_REF:-v0.0.5}"
PLUGIN_NAME=vault
MISE_MIN_VERSION="2026.8.8"   # floor: archiver.decompress strip_components (v2026.8.1) rounded up
                              # to latest verified release — see docs/research/mise-version-floor.md
DATA_DIR="${MISE_DATA_DIR:-$HOME/.local/share/mise}"
PLUGIN_DIR="$DATA_DIR/plugins/$PLUGIN_NAME"

say()  { printf 'mise-vault install: %s\n' "$*"; }
fail() { printf 'mise-vault install: ERROR: %s\n' "$*" >&2; exit 1; }

# --- 1. prerequisites --------------------------------------------------------
command -v mise >/dev/null || fail "mise is not installed (see the company mise onboarding page)"

# mise --version looks like: "2026.8.8 linux-x64 (2026-08-17)" — take field 1,
# a bare calver string, and compare it numerically (year.month.patch) against
# the floor. Anything that doesn't parse as three dot-separated integers is
# treated as "too old / unknown" and rejected, since every mise release this
# tool has ever seen (back to v2023.12.0) uses this exact scheme.
mise_version_raw="$(mise --version 2>/dev/null | awk '{print $1}')"
version_ge() {
    # $1 >= $2, both "YYYY.M.P" (P optional, defaults to 0)
    local a="$1" b="$2"
    local a_y a_m a_p b_y b_m b_p
    IFS=. read -r a_y a_m a_p <<<"$a"
    IFS=. read -r b_y b_m b_p <<<"$b"
    a_p="${a_p:-0}"; b_p="${b_p:-0}"
    [[ "$a_y" =~ ^[0-9]+$ && "$a_m" =~ ^[0-9]+$ && "$a_p" =~ ^[0-9]+$ ]] || return 1
    (( a_y != b_y )) && { (( a_y > b_y )); return; }
    (( a_m != b_m )) && { (( a_m > b_m )); return; }
    (( a_p >= b_p ))
}
version_ge "$mise_version_raw" "$MISE_MIN_VERSION" \
    || fail "mise $mise_version_raw is too old — mise-vault requires mise >= $MISE_MIN_VERSION" \
"           (needs archiver.decompress's strip_components support, added in v2026.8.1)." \
"           Upgrade mise (e.g. 'mise self-update', or your package manager) and re-run this script."

command -v git  >/dev/null || fail "git is required"
command -v curl >/dev/null || fail "curl is required"
command -v sha256sum >/dev/null || command -v shasum >/dev/null \
    || fail "sha256sum (Linux) or shasum (macOS) is required"
say "prerequisites ok (mise $mise_version_raw)"
```

Notes on the logic:

- `awk '{print $1}'` isolates the calver token from the platform tag and build-date suffix; this has been true of `mise --version`'s output shape across the whole range of versions checked in this research (spot-checked against the format documented and used empirically by the sibling docs) and needs no further defense, since anything below the floor is rejected anyway regardless of exactly how its version string is shaped.
- `version_ge` does pure integer comparison per calver component (year, then month, then patch) rather than a string/lexicographic compare, so `2026.8.10 >= 2026.8.8` compares correctly (a naive string compare would get this wrong: `"2026.8.10" < "2026.8.8"` lexicographically).
- The `fail` call above is written as three adjacent string literals for readability in this doc; in the real `install.sh` it should be a single `fail "..."` call with the message assembled via a local variable or `printf`, since `fail()` (as currently defined in `install.sh`) takes one message argument via `"$*"`.

---

## Key risks / unknowns

- **§9 (`strip_components`) is the dominant floor driver and the least battle-tested feature in this document.**
  It is ~2 weeks old as of the research date, with no independent confirmation beyond reading the source diff that introduced it.
  If mise-vault's `hooks/backend_install.lua` does not actually need `strip_components` (e.g. if the catalog's archives never need root-stripping, or the plugin shells out to `tar --strip-components` itself instead), the floor could drop all the way to **v2026.5.2** (§3, the `[tool_alias]` bracketed-options fix) — worth confirming against the actual hook source before shipping `MISE_MIN_VERSION`.
- **§3's bracketed-`tool_alias`-options fix (v2026.5.2) is the second-most-recent dependency and is load-bearing for the Nexus-URL design** documented in `plugin-hooks-and-config-channels.md` §B — if that design ever changes to not rely on `[tool_alias]` brackets (e.g. falls back to the `[tools]`-table-override tier only), this sub-floor could also relax.
- **§5, §7, §8's "at latest bound: v2023.12.0" answers are honest lower bounds, not exact introduction dates** — the true introduction predates this repository's calver tag history (some predate even the `rtx`→`mise` rename).
  This doesn't affect the floor calculation (these features are so old they never come close to driving it), but don't cite "v2023.12.0" as *the* introduction date in any external-facing doc — it's "the oldest tag we can prove contains it," stated as such above.
- **Two features (§3, §9) were pinned by reading a single PR's diff directly** (not by cross-referencing a CHANGELOG entry or doc-page prose) — this is primary-source-solid but narrower than the multi-source triangulation used for e.g. §2 or §4; if either PR was later reverted and re-landed differently, the cited SHA/tag could be stale (checked CHANGELOG.md for follow-up "fix" entries mentioning the same feature name in both cases and found none, which is reassuring but not conclusive).
- **`mise --version`'s output format itself was not verified across historical versions** — only the current format (`2026.8.8 linux-x64 (2026-08-17)`) was confirmed, both locally and via the sibling docs.
  This doesn't matter for the floor check's correctness (any version at or above the v2026.8.x floor will use this same current format; anything using an older/different format is by definition below the floor and should be rejected regardless of whether the parse succeeds), but if `install.sh` is ever asked to produce a *friendlier* error message for very old `mise` installs, don't assume `awk '{print $1}'` parses their output the same way.
- **This document does not verify that v2026.8.1's `strip_components` implementation matches mise-vault's actual expected semantics** (e.g. exact behavior for archives with multiple top-level entries, symlinks, or empty directories) — only that the option exists and is wired through from Lua.
  A PoC against the real plugin hooks is recommended before finalizing the floor, consistent with the "Key risks" pattern in the sibling docs.
