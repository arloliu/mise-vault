# Plugin Rollout Strategies — Research

Date: 2026-08-18.

## The question

mise-vault ships as a private git repo with immutable tags (v1.2.0, v1.3.0, ...).
`scripts/vault-sync <tag>` re-pins the plugin
(`mise plugin install -f vault <url>#<tag>`, a full re-clone at that ref)
and regenerates `~/.config/mise/conf.d/mise-vault.toml` from the new catalog.
mise has no plugin auto-update
(documented no-op as of v2026.8.8 — see
[mise-backend-plugin-mechanics.md](mise-backend-plugin-mechanics.md) §2,
verified against `settings.toml`'s own description of
`plugin_autoupdate_last_check_duration`).
There is no fleet agent, no guaranteed MDM, hundreds of Linux/macOS workstations,
and a private GitLab with scheduled-pipeline capability.

How should an update to the plugin/catalog reach those workstations,
staged rather than all-at-once,
and how should a bad update be pulled back?
This document surveys prior art from projects that solve adjacent problems,
then proposes and recommends a concrete scheme.

---

## 1. Ring/canary-based rollout models

| Project | Mechanism | Trigger | Staging granularity |
|---|---|---|---|
| Chrome Enterprise (ChromeOS) | Admin-console **staged rollout schedule**: a percentage of devices per stage, days-to-wait per stage, final deadline | Background updater on the device; no login script needed — Chrome "downloads updates in the background… you only need to relaunch the browser" ([Chrome release channels, developer.chrome.com](https://developer.chrome.com/docs/web-platform/chrome-release-channels)) | Devices are **chosen at random for each new rollout** — no per-device registry or agent list is consulted, the randomization happens as part of the staged-rollout policy itself ([Manage updates on ChromeOS devices](https://support.google.com/chrome/a/answer/3168106?hl=en)) |
| Chrome release channels (desktop) | Four channels — Canary (daily), Dev (1–2×/week), Beta (~weekly, major every 4 weeks), Stable (every 2–3 weeks, major every 4 weeks) | Same background updater; channel choice is a policy/build choice, not a runtime toggle | Google's enterprise guidance recommends keeping ≥5% of devices (and ≥5% of each hardware type) on Beta at all times, ~95% on Stable ([Chrome Enterprise release channels — Understanding Chrome Release Channels](https://www.androidenterprise.community/best-practices-with-chrome-enterprise-46/understanding-chrome-release-channels-2526)) |
| VS Code extensions | `--pre-release` flag at publish time; user opts a given extension into the pre-release channel in the Marketplace UI | **Fully automatic**, no shell hook: "VS Code will automatically update extensions to the highest version available" — even a pre-release opt-in gets silently overtaken by a higher-numbered stable release ([Publishing Extensions, code.visualstudio.com](https://code.visualstudio.com/api/working-with-extensions/publishing-extension)) | Per-extension binary flag (pre-release or not); no percentage/ring mechanism is documented at the extension-host level — this is the load-bearing fact for §2's supply-chain incident below |
| Nix channels | A channel is a named URL pointing at a Nixpkgs evaluation; `nix-channel --update` fetches it and creates a new **generation** | Fully manual — `nix-channel --update`, typically run from a shell or a cron/CI job someone wires up themselves | Channel *name* is the ring (`nixos-stable`, `nixos-unstable`, "small" channels trade fewer binaries for faster updates); no percentage rollout — subscribing to a channel is binary per machine ([nix-channel, nix.dev manual](https://nix.dev/manual/nix/2.34/command-ref/nix-channel.html)) |
| Homebrew | **No staging model at all.** | `brew update` runs automatically before `brew install`/`upgrade`/`tap` unless `HOMEBREW_NO_AUTO_UPDATE=1` is set ([Homebrew docs discussion, github.com/orgs/Homebrew/discussions/3394](https://github.com/orgs/Homebrew/discussions/3394)) | Homebrew explicitly rejects mixed versions: "everything a formula depends on, and everything that depends on it in turn, needs to be upgraded to the latest version as that's the only combination of formulae we test" ([Homebrew FAQ, docs.brew.sh](https://docs.brew.sh/FAQ)) — the only per-formula controls are `brew pin` (freeze) and `HOMEBREW_NO_AUTO_UPDATE` (defer), neither of which is a ring |
| Internal devtools platforms (Uber/Airbnb/Spotify/Meta) | — | — | **Thin/no result.** Searches turned up Uber's rollout tooling for *service* deployments (monorepo change risk, ML-serving cohort rollouts) and generic engineering-blog listicles, but no first-party post specifically about staging a CLI/devtool *update to developer workstations*. Reported honestly rather than stretched to fit — this sub-question does not have a citable primary source. |

**Takeaway**: only Chrome documents a genuine percentage/day-staged ring mechanism,
and it depends on a background updater process the OS runs for you
— exactly the "central agent" mise-vault's constraints rule out.
VS Code's model is closer to mise-vault's shape
(a CLI-adjacent tool with no fleet agent),
but it resolves the staging question by *not staging at all at the client*:
everyone auto-updates to the newest published version, full stop,
which is also the source of the incident in §2.
Nix and Homebrew both push staging into a human-typed command,
which is closest to what mise-vault already has via `vault-sync`.

---

## 2. Git-native distribution patterns

### Floating channel refs vs immutable tags

| | Floating ref (branch / moving tag) | Immutable tag/SHA (mise-vault's model) |
|---|---|---|
| Determinism | Two clones of "stable" on different days can differ | Same tag always resolves to the same tree — reproducible builds, auditable MRs |
| Rollback | Force-push the ref backward; every consumer that re-syncs gets the old state automatically | Consumer must be told to re-pin to an older tag explicitly |
| Update latency | Zero — next `git pull`/`git fetch` sees it | Bounded only by when the consumer chooses to re-pin |
| Audit trail | Weak — `git log` on the ref shows history, but "what commit was `stable` at 10:03 UTC last Tuesday" requires reflog/CI archaeology | Strong — the tag *is* the audit record; a CI pipeline log referencing `v1.3.0` is meaningful forever |

Git's own documentation frames tags as advisory, not enforced-immutable:
nothing in git core prevents `git tag -d` + `git tag <same-name> <new-commit>` + `git push -f`,
and hosting platforms that want real immutability (e.g. GitHub) have had to build a *separate* feature for it
— GitHub's "Immutable Releases" ties a release's tag down so it "can't be deleted or moved,"
explicitly because plain git tags do not guarantee that on their own
([GitHub Docs, Immutable releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases)).

A documented demonstration of the failure mode:
a write-up walked through tagging a benign commit `v0.1`,
then `git tag -d v0.1 && git tag v0.1 <malicious-commit> && git push -f`
— a downstream CI pipeline that references the tag (not the SHA)
silently built the malicious commit on its next run,
with the author's conclusion:
"Through no fault of our own and without any changes to the build dependencies,
we're now building using a different underlying dependency despite keeping the release number the same,"
and the explicit recommendation to reference commit SHAs, not tags, in CI
([The Scale Factory, "Compromise by Git Tags," 2021](https://scalefactory.com/blog/2021/02/18/compromise-by-git-tags/)).
This is directly relevant: mise-vault's `#<tag>` pinning is only as immutable
as GitLab's branch/tag protection rules make it
— nothing in `git` or in mise enforces it.

### Version managers that distribute via git refs

| Project | Pin mechanism | Update mechanism | Rollback |
|---|---|---|---|
| **asdf** plugins | `asdf plugin add <name> <git-url>` — asdf-plugins is a shortname→URL registry, not a version pin | `asdf plugin update <name> [<git-ref>]` fetches "the latest commit on the default branch of the origin" by default; if you'd pinned to a specific SHA via a previous `update <name> <ref>` call, a bare `asdf plugin update <name>` or `--all` **overwrites that pin** with latest-default-branch | Not documented — "versioned plugins" (i.e. reliable pin/rollback) was, per the docs, still an open feature request at the time of writing, not a supported workflow ([Plugins, asdf-vm.com](https://asdf-vm.com/manage/plugins.html)) |
| **oh-my-zsh** | N/A — always tracks its own repo's default branch | Auto-checks on every shell start via `check_for_upgrade.sh`, cadence controlled by `UPDATE_ZSH_DAYS` (default 13 days); prompts unless `DISABLE_UPDATE_PROMPT=true`, in which case it silently `git pull`s; fully disabled via `DISABLE_AUTO_UPDATE=true` ([ohmyzsh update system, DeepWiki summary of github.com/ohmyzsh/ohmyzsh source](https://deepwiki.com/ohmyzsh/ohmyzsh/3.5-update-and-upgrade-system)) | `git` reflog / manual checkout — no first-class rollback command |
| **lazy.nvim** | First-class: `plugin.pin = true` freezes at current commit; `plugin.commit`, `plugin.tag`, or `plugin.version` (semver range) pin explicitly; resolution order is pinned → lockfile → explicit commit → tag → version → branch | `:Lazy update`; a generated `lazy-lock.json` records the exact resolved commit per plugin after every update and is meant to be checked into version control | Restoring the previous `lazy-lock.json` and re-running sync reverts every plugin to its previous locked commit — closest thing in this survey to a real lockfile-based rollback ([Lockfile, lazy.folke.io](https://lazy.folke.io/usage/lockfile), [Versioning, lazy.folke.io](https://lazy.folke.io/spec/versioning)) |
| **tfenv** | `.terraform-version` file (project or home dir) pins the resolved version; `tfenv pin` writes the currently-active version into it | `tfenv install <version>` / `tfenv list-remote` — always an explicit, human-typed action | Overwrite `.terraform-version` with an older value and `tfenv install` that version — versions are cached locally per-version (asdf-style), so a rollback never needs network access if already installed ([tfutils/tfenv, github.com](https://github.com/tfutils/tfenv)) |

**Pattern across all four**: none of them do automatic, unattended, unpinned updates by default except oh-my-zsh
(which nags interactively unless explicitly silenced)
— the dominant convention in this class of tool is an explicit, human-triggered update,
with pinning as an opt-in escape hatch layered on top of a floating default.
mise-vault's `vault-sync <tag>` model
— explicit, immutable-tag-driven, human- or pipeline-triggered —
already sits at the safe end of this spectrum by construction
(see D5 in SYNTHESIS.md: "no automatic trigger exists" for plugin updates in mise itself).

### A documented supply-chain incident involving silent auto-update

The **Nx Console VS Code extension compromise** (May 2026) is the sharpest example found
of exactly the risk an unattended update path creates.
A contributor's GitHub token
— itself stolen in an earlier, separate supply-chain attack —
was used to publish a malicious build of Nx Console (v18.95.0, ~2.2M installs) to the VS Code Marketplace;
it stayed live roughly 18 minutes on the Marketplace and ~36 minutes on OpenVSX.
Because `extensions.autoUpdate` defaults to on,
"the install happens in the background with no prompt"
— victims were infected purely by having their editor poll the marketplace during the exposure window,
with no click, no approval, no visible signal.
The malicious extension running on a GitHub employee's machine was the entry point for a follow-on breach,
in which GitHub reported attackers accessed roughly 3,700 internal repositories the next day
([Aikido Security, "The Wild West of VS Code extensions and how a poisoned extension breached GitHub"](https://www.aikido.dev/blog/vs-code-extension-github-breach);
corroborated independently by
[CISA's advisory on the related Nx/npm compromise wave](https://www.cisa.gov/news-events/alerts/2026/05/28/supply-chain-compromises-impact-nx-console-and-github-repositories)).
This is the concrete argument against giving mise-vault a fully unattended,
self-triggering update path with no human or CI gate in front of it
— see the Recommendation below.

---

## 3. Detection/nudging without an agent

| Mechanism | How it works | Blocking? |
|---|---|---|
| **rustup** toolchain staleness notice | On opt-in (asked at install time), rustup checks for updates in the background whenever a `rustup` or `cargo` (via the rustup proxy) command runs, with a short timeout; if the check completes it prints e.g. `Rustup notice: Update available for the 'stable' toolchain… Run 'rustup update -N' to complete the update`, otherwise it defers the message to the next invocation ([discussion citing rustup's update-notification behavior, rust-lang/rustup issue tracker and Rust Internals](https://internals.rust-lang.org/t/keeping-rust-toolchain-up-to-date-with-automatic-reminders-for-available-updates/20395)) | No — pure nudge, never auto-installs |
| **Homebrew** `brew outdated` / auto-update-on-install | `brew update` (the metadata refresh) runs automatically before `install`/`upgrade`/`tap`; `brew outdated` then lists what's behind. Nudging is folded into the command you were already running rather than a separate watcher ([Homebrew FAQ](https://docs.brew.sh/FAQ)) | The metadata refresh is automatic; the actual package *upgrade* is not — `brew outdated` only reports |
| **oh-my-zsh** login-shell check | `check_for_upgrade.sh` runs on every new shell, throttled by `UPDATE_ZSH_DAYS` | Configurable — prompts by default, can be silent-auto or fully off |
| **nvm** | No documented staleness nudge found — `nvm install <version>` is purely on-demand, and the project's own README does not describe any background version-check ([nvm-sh/nvm README](https://github.com/nvm-sh/nvm/blob/master/README.md)). Reported honestly as a non-finding rather than assumed. | N/A |
| **CI enforcing a floor version** | Not vendor-documented as a named pattern, but this is exactly what mise-vault already plans: D12 in SYNTHESIS.md commits to `install.sh` enforcing a minimum mise version, and the same technique generalizes to a downstream repo's CI failing a pipeline if the local catalog/plugin tag is older than an org-declared floor | Yes, by design — this is the one mechanism in this survey that can *block* (a merge/pipeline), as opposed to merely nudging a human |
| MDM/config-management (Ansible/Chef/Puppet) driving a sync command on schedule | Generic capability of any of the three (a scheduled playbook/run driving `mise run vault-sync <tag>`), not something this research found a specific first-party "how we roll out devtool updates to N machines" engineering post about | N/A — mechanism is real and well-established for config management generally, but the specific devtool-rollout use case is not separately documented by any vendor found |
| "Config drift at scale" published engineering guidance | **Thin.** Searches surfaced only vendor marketing content (Puppet, Harness, Coder, Faronics) describing configuration drift in generic terms, not a first-party "how a real engineering org solved developer-tool version drift across hundreds of laptops" post. No citation is offered here that would meet the primary-source bar — this sub-question is honestly unresolved by public prior art. | — |

**Takeaway**: every credible non-agent nudge mechanism found (rustup, Homebrew, oh-my-zsh)
is triggered by **something the developer was already about to run**
— a shell start, a `cargo`/`rustup` invocation, a `brew install`.
None of them poll independently in the background the way a real agent would.
That constraint maps directly onto mise-vault:
the only trigger points available without an agent are shell activation
(mise already hooks the shell) and explicit invocation of `vault-sync` itself.
CI-side enforcement is the one place a hard *block* is achievable without any workstation-side mechanism at all.

---

## 4. Rollback mechanics

With immutable tags, rollback is definitionally "re-pin to an older tag":
`mise plugin install -f vault <url>#v1.2.0` followed by `vault-sync`'s conf.d regeneration.
For that to be safe, three things must hold,
each checked against mise's own mechanics and this project's prior research:

1. **The catalog is data-only, not code with side effects.**
   Confirmed: `catalog/<tool>/{tool.json,versions.json}` are pure JSON,
   and mise-vault's own catalog-schema decisions (SYNTHESIS.md D7–D9) reinforce this
   — `versions.json` is a plain ordered array with no executable content,
   and even the sidecar-hash generation tooling only feeds catalog *authoring*, never install-time behavior.
   Re-pinning the plugin repo therefore cannot itself execute anything destructive on downgrade
   — the only executable surface is `metadata.lua` + the three `Backend*` hooks,
   and rolling back to an older *tagged* release of those hooks just means running
   slightly older (previously-shipped, previously-tested) Lua, not untested code.

2. **Previously-installed tool versions remain cached and available regardless of the current catalog.**
   mise installs tools to a content-addressed path, `~/.local/share/mise/installs/<plugin>-<tool>/<version>`,
   and that directory is not managed or touched by the plugin-repo checkout at `~/.local/share/mise/plugins/vault/`
   — they are separate directories under `MISE_DATA_DIR`
   (verified in [mise-backend-plugin-mechanics.md](mise-backend-plugin-mechanics.md),
   `ctx.install_path` example and plugin-clone-path citation).
   Re-pinning the plugin to an older tag changes what `BackendListVersions`/`BackendInstall`
   will *offer or accept going forward*;
   it does not delete or invalidate anything already on disk.

3. **A rolled-back catalog can list only older approved versions than what a machine already has installed**
   — and this is the hazardous case.
   Concretely: a developer has `tool@2.0` installed and referenced in a project's `.tool-versions`;
   the catalog is rolled back to a `versions.json` whose newest entry is `1.5`.
   Two sub-cases, reasoned from mise-vault's own **fail-closed** design
   (SYNTHESIS.md §9: unknown tool, unapproved version, and checksum mismatch all abort with explicit errors)
   rather than from an external citation,
   since no other surveyed system combines immutable-tag distribution
   with a fail-closed approved-version gate the way mise-vault does:
   - **If `2.0` is already installed and mise trusts the local cache**
     (does not re-validate an already-present install against the current `BackendListVersions`
     before using it — the general, but for mise-vault **not yet empirically verified**,
     behavior of version managers in this class; flagged explicitly in Key risks below):
     the developer keeps working uninterrupted,
     because mise never calls back into the (now catalog-rolled-back) plugin for a version it already has on disk.
   - **If the cache is ever invalidated**
     — a fresh clone, a new hire's laptop, a CI runner, `mise uninstall` + reinstall,
     or (per mise-vault's fail-closed model) any code path that *does* re-validate against `versions.json` —
     installing `2.0` now fails closed with "unapproved version,"
     even though it is the exact version the project's `.tool-versions` names
     and the exact version a teammate is currently running successfully.
   This is a **reproducibility regression masquerading as a security control**:
   the catalog rollback was presumably issued because `2.0` had a real problem,
   but the failure surfaces as a confusing, unexplained install failure
   for anyone *not already holding a warm cache*,
   rather than as a clear "this version was pulled, here's why" message.
   No comparable system in this survey has to solve exactly this,
   because none of them combine (a) immutable-tag/version pinning,
   (b) an allow-list that can shrink on rollback,
   and (c) a fail-closed install gate, all at once
   — Homebrew's "only ever support latest" model sidesteps it by never supporting an old version at all;
   asdf/tfenv/lazy.nvim have no allow-list concept, only availability;
   Chrome's staged rollout only ever moves a device *forward or to a pinned target*,
   never revokes a version's install-ability outright.
   **Recommendation for mise-vault specifically**: a catalog rollback that is meant to revoke a specific bad *version*
   (not the whole tool) should be expressed as removing just that entry from `versions.json`
   while leaving newer-but-unaffected entries and older entries intact,
   rather than truncating the array back to an earlier release wholesale
   — this avoids accidentally un-approving versions that were never the problem.
   This is a design recommendation, not something verified against mise's own behavior;
   the underlying "does mise trust an already-installed version without re-checking the backend" question
   is listed as an open unknown below and should get a PoC before this hazard is treated as fully understood.

---

## Proposed schemes

### Scheme A — Nudge + staged approval manifest + CI floor (recommended)

- **Trigger**: `vault-sync` is never invoked automatically on a schedule.
  A lightweight staleness check
  (same shape as oh-my-zsh's `check_for_upgrade.sh` — cheap, cached, throttled)
  runs on shell activation (mise already hooks the shell for every developer)
  and compares the locally pinned tag against a `rollout-manifest.json` fetched from the GitLab repo's default branch,
  with a short TTL cache so it never blocks shell startup on network latency.
  If stale, it prints one line naming the exact command to run (`mise run vault-sync v1.4.0`) — never runs it.
  Downstream project CI pipelines additionally enforce a floor (D12-style)
  so a PR from a laggard machine fails loudly instead of silently drifting.
- **Staging/ring structure**: the manifest carries named pointers
  — `{"ring0": "v1.4.0", "ring1": "v1.3.0", "stable": "v1.2.0"}` —
  promoted by a GitLab **scheduled pipeline** on a cadence
  (mirroring Chrome's day-staged model: e.g. ring0 for 2 days, ring1 for 3 more, then promote to `stable`).
  Ring assignment is computed **client-side**, deterministically,
  from a stable per-machine value (e.g. hostname hash mod N)
  — no server-side device registry is needed, avoiding anything that looks like a fleet inventory/agent.
- **Rollback**: edit `rollout-manifest.json` (pipeline job or a human with a `git revert`)
  to point the affected ring(s) back at an older tag;
  the next shell-hook check on every affected machine picks up the new target
  and nudges the same way it nudges for a forward update.
  Urgent rollback is broadcast out-of-band (Slack/email)
  with the same `mise run vault-sync <tag>` command developers already know.
- **Failure modes**: nudge fatigue (developer ignores the message)
  — bounded blast radius per machine, and caught by the CI floor check before it reaches anything shared;
  manifest fetch failing at shell startup — must fail silent/cached, never block the shell;
  a promotion race where the pipeline advances the manifest while a rollback is in flight
  — mitigated by making promotion and rollback the same code path
  (both are just "set ring X to tag Y").
- **What needs to be built**: the staleness-check script
  (added to the mise activation hook or a small script sourced by it);
  `rollout-manifest.json` schema + a GitLab scheduled-pipeline job
  that promotes it on a timer with configurable bake-time per ring;
  a CI template snippet other repos include to enforce the floor tag;
  docs describing the ring cadence and the manual override/rollback procedure.

### Scheme B — Wave-bucketed local scheduler, self re-pinning

- **Trigger**: `install.sh` additionally installs a **per-user, per-machine** unattended scheduled task
  — a `cron` entry on Linux, a `launchd` LaunchAgent on macOS —
  that runs `vault-sync` in an unattended mode on a cadence (e.g. daily).
  This is explicitly *not* a fleet agent:
  it is local OS-scheduler configuration written once at bootstrap,
  with no phone-home, no central controller,
  and no persistent process beyond what cron/launchd already provides on every Unix machine.
- **Staging/ring structure**: identical `rollout-manifest.json` + scheduled-pipeline promotion as Scheme A,
  but consumed unattended: each machine's local timer checks its wave's approved tag,
  and if it differs from the currently pinned tag **and** the promotion's bake-time has elapsed,
  `vault-sync` re-pins itself automatically and appends to a local log file.
- **Rollback**: same manifest edit as Scheme A;
  every affected machine self-heals to the older tag within one scheduler interval,
  with no developer action required
  — faster and more uniform convergence than Scheme A's nudge.
- **Failure modes**: this is the riskier scheme,
  and the risk is concrete, not hypothetical
  — it is structurally the same shape as the Nx Console incident in §2
  (an unattended process pulling and applying an update with no human gate),
  the difference being that mise-vault's catalog is data reviewed via MR
  rather than an arbitrary marketplace publish.
  Specific failure modes: a bad tag reaches every machine within one scheduler cycle before anyone notices
  (no bake-time gate can fully prevent a fast-breaking issue, only shrink the window);
  machines asleep/off miss a cycle and silently fall behind
  (self-heals on next wake, but staggered, defeating the "uniform convergence" benefit);
  silent sync failures (network down, GitLab unreachable) accumulate with no fleet visibility to catch it,
  since there is no agent reporting home by design.
- **What needs to be built**: everything in Scheme A,
  plus a cron/launchd unit template in `install.sh`;
  an unattended-mode flag for `vault-sync`
  (idempotent, quiet, logs to a local file, honors a developer-droppable pause-flag file to opt out temporarily);
  bake-time logic in the promotion pipeline;
  and, because there is no fleet visibility,
  a much stronger CI-floor backstop than Scheme A needs,
  since it is the only place blast radius can be observed centrally at all.

### Scheme C — Fully manual, comms-driven, CI-gated only

- **Trigger**: 100% human-typed `mise run vault-sync vX.Y.Z`, announced via release notes/Slack
  — no automated promotion, no manifest, no shell-hook nudge.
  This is the direct extension of what mise-vault already has (D5's explicit-task design)
  with zero new client-side mechanism.
- **Staging/ring structure**: soft rings by communication order only
  — notify a pilot group first, wait N days, then broadcast org-wide —
  mirroring how Homebrew's "no staging model" pushes the entire staging problem
  onto humans deciding when to type the command,
  and how Nix channel subscription is a binary per-machine choice with no automated promotion.
- **Rollback**: identical manual command with an older tag; zero new infrastructure.
- **Failure modes**: slowest uptake of the three schemes
  (worst-case: a developer who never reads the announcement stays on an old tag indefinitely).
  But also the smallest blast radius and the simplest mental model.
  The CI-floor check (shared with Scheme A) is the only automated enforcement,
  and it only catches drift when a laggard's code actually reaches a gated pipeline.
- **What needs to be built**: only the CI-floor-check template and a documented comms process
  — no manifest, no pipeline job, no scheduler unit.

---

## Recommendation

**Scheme A** (nudge + staged approval manifest + CI floor),
with Scheme C's manual-override path always available as the emergency rollback lever
and Scheme B's ring/bake-time *design* reused for the manifest promotion logic
even though its *unattended auto-repin* is rejected.

Reasoning tied to the constraints:

- **No guaranteed MDM, hundreds of Linux+macOS machines** rules out anything that assumes
  a central push mechanism exists on every machine
  — Scheme A needs nothing beyond what mise already installs (the shell hook)
  and what GitLab already offers (scheduled pipelines),
  so it works uniformly across the whole fleet rather than only on the MDM-covered subset.
- **The Nx Console incident (§2) is the deciding evidence against Scheme B's unattended auto-repin.**
  An unattended, self-triggering update path is exactly the mechanism
  that turned one compromised publish into a fleet-wide, zero-click compromise in 18–36 minutes
  with no human gate anywhere in the path.
  mise-vault's catalog changes go through MR review,
  which is a real mitigation Nx Console's publish flow lacked
  — but Scheme B still removes the one thing every other credible non-agent mechanism surveyed in §3 keeps
  (rustup, Homebrew, oh-my-zsh): a human present at the moment the update is applied.
  Given hundreds of machines and no fleet visibility to catch a bad unattended rollout quickly,
  the downside is asymmetric
  — the small latency win of auto-repinning is not worth removing the human gate.
- **The git-tag-mutability finding (§2) argues for keeping the CI floor check regardless of scheme.**
  A `#<tag>` pin is only as strong as GitLab's tag-protection settings;
  a CI job that independently verifies the resolved catalog/tag on every pipeline run
  is a cheap, scheme-independent backstop against both a moved tag and ordinary drift,
  and every scheme above already assumes it exists.
- **Scheme C alone is too slow for hundreds of machines**
  — comms-only rollout has no way to accelerate a security-driven update beyond how fast people read Slack,
  and no client-side signal at all for a developer who missed the announcement.
  Scheme A keeps Scheme C's manual command as the literal rollback/override mechanism
  (same `vault-sync <tag>` invocation either way) while adding a low-risk automated nudge on top.
- **GitLab scheduled pipelines are exactly the right tool for the one piece of server-side automation this design needs**
  — promoting `rollout-manifest.json` through rings on a timer —
  because that job only ever writes to the git repo;
  it never needs to reach into a workstation, sidestepping the "no agent" constraint entirely.

If the org later gains real MDM/Ansible coverage for some subset of the fleet,
that subset can safely layer Scheme B's unattended cron/launchd trigger on top of Scheme A's manifest
without changing the manifest or promotion design at all
— the two schemes share the same server-side state,
they differ only in what triggers the client-side apply.

---

## Key risks / unknowns

- **Whether mise re-validates an already-installed tool version against the current `BackendListVersions`/catalog
  before using it.**
  This is the load-bearing assumption behind §4's claim that a catalog rollback
  doesn't break an already-installed, already-pinned version
  — it was not found documented in mise's own docs
  and was not empirically re-verified in this research pass
  (the project's existing PoC matrix, SYNTHESIS.md §6/§9, tests fail-closed behavior for *new* installs,
  not for *already-cached* ones under a since-shrunk catalog).
  Needs a targeted PoC: install `tool@2.0`, shrink `versions.json` to top out at `1.5` via a re-pin,
  then attempt `mise install`/`mise exec` for the already-installed `2.0` on the same machine
  and observe whether it still works.
- **No first-party engineering-blog precedent exists for staging a git-distributed devtool update
  across a developer fleet without an agent.**
  §1 and §3 both turned up thin or empty on this specific combination
  — the schemes above are original synthesis grounded in adjacent prior art
  (Chrome's staged-rollout percentages/bake-time, rustup/oh-my-zsh's nudge triggers, lazy.nvim's lockfile),
  not a direct precedent that was found and could be copied.
- **Ring assignment via hostname-hash is unverified against real-world fleet distribution.**
  If workstation hostnames are not sufficiently random/unique across the fleet
  (e.g. sequential asset tags),
  the hash-mod-N bucketing in Scheme A/B could produce lopsided rings;
  should be checked against actual hostname conventions before committing to the mechanism.
- **GitLab's own tag-protection guarantees were not independently re-verified in this pass**
  — the §2 finding that plain git tags are mutable is well-established for git in general,
  but this research did not re-confirm exactly which GitLab protected-tag settings mise-vault's repo currently has enabled;
  that should be checked directly against the repo's project settings, not assumed from general GitLab documentation.
- **The CI-floor-check mechanism (leaned on heavily in the Recommendation) is not yet built**
  — it is referenced as already-planned (SYNTHESIS.md D12, for the mise-version floor)
  but the analogous catalog/plugin-tag floor check for downstream repos does not exist yet
  and is scoped as new work under "What needs to be built" above, not something already validated.
