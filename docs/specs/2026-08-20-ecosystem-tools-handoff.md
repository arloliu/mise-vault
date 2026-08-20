# Handoff: implement the ecosystem tool types (cargo, npm, pypi)

Written 2026-08-20 for a fresh conversation to start implementation.
Read this file, the design spec next to it
(`2026-08-20-ecosystem-tools-design.md`),
and AGENTS.md before writing any code.

## Where the repository stands

- `main` contains the fully landed **go-installed tool type**
  (code commit `10ee3b6`, merged fast-forward on 2026-08-20) —
  the direct template for this work.
- The active branch for this feature is `feat/ecosystem-tools`,
  branched from `main`;
  it carries the design spec, this handoff, and their amendments.
- Every gate is green at that commit:
  poc-test 41/41, run-validator-tests 42/42, run-approve-tests 46/46,
  run-harness-selftest OK, validate-catalog OK (both engines),
  bootstrap-test 28/28, offline-test 11/11.
- The experiment GitLab (`git remote experiment`) has been fast-forwarded
  to the same commit; the experiment Nexus go-proxy cache is seeded with
  the full gocensus dependency closure.
- The go feature went through nine rounds of external review;
  everything it surfaced is fixed or recorded as a documented limitation.
  The durable lessons all live in AGENTS.md ("Lessons learned") and in
  `docs/research/SYNTHESIS.md`,
  whose final entries record that hardening arc.

## What to build

The design spec is authoritative.
Summary: three new catalog tool types (`cargo`, `npm`, `pypi`) that run
the ecosystem's own installer at a pinned version into
`<install_path>/bin`, inheriting the user's environment
(registries, proxies, auth are the user's configuration, not the
plugin's), with runners chosen by
`MISE_VAULT_NPM_RUNNER` / `MISE_VAULT_PYPI_RUNNER`.
Version-pin-only integrity (no h1 analogue exists);
the approved-version list stays the boundary.
(Since amended: pypi records may now carry always-enforced artifact
hashes, and the npm/cargo version grammar accepts uppercase
prerelease/build identifiers —
the design spec's implementation notes are authoritative.)
Rollout: Phase A npm+pypi, Phase B cargo, Phase C bun runner.

All open questions at the end of the design spec were resolved with
the user on 2026-08-20 (see the spec's section 10).
The confirmed first tools are tokei (cargo), prettier (npm),
and ruff (pypi).

## Files you will touch (mirror the go-type diff of commit 10ee3b6)

- `hooks/backend_install.lua` — one branch per type
  (study `install_go_tool` first; reuse its patterns).
- `hooks/backend_exec_env.lua` — generalize the `type == "go"` branch to
  every source-built type (PATH = install_path/bin).
- `lib/common.lua` — per-ecosystem name grammars
  (follow `check_module_path`'s shape).
- `schemas/tool.schema.json`, `schemas/versions.schema.json` — new
  `oneOf` branches; keep the `(?![\s\S])` end anchors.
- `scripts/validate-catalog` — mirrored grammars (`\Z` anchors),
  cross-file type ⇔ record-shape rules.
- `scripts/add-version`, `scripts/verify-artifacts` — registry existence
  probes per ecosystem.
- `tests/fixtures/`, `tests/run-validator-tests` — negative fixtures per
  grammar trap; bump `MIN_CASES` and `SCHEMA_CASES`.
- `experiment/scripts/poc-test` — per-type behavior matrix
  (copy the go phase's case list, including forged-trailer regressions).
- `experiment/scripts/provision-nexus.sh`, `seed-artifacts.sh`,
  `offline-suite` — npm/pypi proxy repos and cache warming
  (cargo pending the Nexus CE format check).
- Documentation trail, mirroring the go type's:
  `docs/development.md`, `docs/design.md`,
  `docs/research/SYNTHESIS.md` —
  and, because the design revises the network principle for these
  types, every place that states the absolute never-public rule must
  gain the scoped exception without weakening it for artifact and go
  installs.
  Known locations:
  the AGENTS.md intro sentence ("never fall back to GitHub, public
  registries…"), the AGENTS.md fail-closed bullet,
  the AGENTS.md lesson stating that never-contact-the-internet is
  enforced by the plugin constructing only Nexus URLs,
  the header comment of `hooks/backend_install.lua`,
  and `docs/design.md`, which repeats the absolute rule in its
  overview, its network section, and its proof-of-concept criteria.
  That list is a starting point, not the boundary:
  finish with a repository-wide search for absolute network claims
  (for example "never", "only Nexus") and amend each hit.

## Hard-won gotchas (verified this week; do not rediscover them)

1. **mise's `cmd.exec` shell aborts on the first unguarded nonzero
   status.**
   Guard every step (`cmd || st=$?`, `cmd || true`);
   a bare `cmd1; cmd2` dies on cmd1.
2. **Never signal success with a fixed marker word** — build output can
   forge it.
   Use the numeric exit-status trailer pattern from `install_go_tool`
   and anchor the match at end of output;
   then check the expected binary exists.
3. **mise strips its own managed tool paths from PATH while hooks run.**
   User-installed runners resolve normally; a runner installed VIA mise
   will not be found — document, don't fight it.
4. **poc-test kept HOMEs contain a COPY of the plugin, not a link.**
   After editing hook code, rerunning `mise install` inside a kept
   `/tmp/mise-vault-poc.*` HOME tests the stale copy;
   copy the edited file into `<home>/plugin/hooks/` or rerun the full
   suite.
   This caused a long phantom-failure detour once already.
5. **Python's `$` regex anchor matches before a trailing newline** —
   use `\Z` in Python, `(?![\s\S])` in JSON Schema patterns.
6. **Go-proxy-style probes**: GET only (never HEAD), treat 404 AND 410
   as absent, refuse redirects, always check the HTTP code —
   the same conventions apply to the npm/PyPI/crates probes.
7. **`always_keep_download` can preserve the download directory** —
   anything cached under it must be cleared before reuse, fail-closed
   if clearing fails (see the go branch).
8. The repo hook enforces **semantic line breaks** in comments and
   markdown — one sentence per line, split long sentences at clause
   boundaries.
9. `install.sh` bootstrap, netrc, and validator behaviors have their own
   lessons in AGENTS.md — read that section end to end; it is current.

## Process expectations (how the go feature was landed)

- Design decisions of record: users self-manage toolchains;
  inherit-environment networking; env-var runner selection;
  the go type keeps its plugin-controlled GOPROXY design unchanged —
  do not "align" it without the user asking.
- Implementation can be dispatched to a cheaper model with a tight,
  self-contained spec prompt; the main thread verifies everything
  itself afterward (subagent reports have contained errors).
- The user expects an external code review loop before committing:
  Codex (`codex exec`) as the gating reviewer, iterate fix → re-review
  until an explicit merge verdict.
  Two operational notes: sol-tier dispatches have stalled reading
  stdin — redirect stdin from /dev/null and set an abort timeout;
  scope later rounds delta-only to keep them fast.
- Verification ladder per change:
  `scripts/validate-catalog` → `tests/run-validator-tests` →
  `tests/run-harness-selftest` → `experiment/scripts/poc-test`
  (docker stack must be up) → after committing and pushing to the
  `experiment` remote (`git push experiment <branch>:main`),
  `bootstrap-test` and `offline-test`.
  offline-test now also severs Nexus's egress network for the duration.
- Commit style: Conventional Commits, plain English, no attribution
  trailers, no internal shorthand
  (lint/tests must pass before every commit).

## Experiment stack quick reference

- `cd experiment && docker compose up -d` if not running
  (it was running and provisioned as of this handoff).
- Credentials and mirror overrides: `experiment/README.md`.
- Nexus is `127.0.0.2:8081`, GitLab is `127.0.0.3:8929`
  (hostnames deliberately differ because netrc has no port field).
- New Nexus repos are created idempotently in
  `experiment/scripts/provision-nexus.sh`; follow the go-proxy block as
  the template for npm/pypi proxy repos.
