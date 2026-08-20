# Handoff: implement Phase C (the bun runner for npm tools)

Written 2026-08-20 for a fresh conversation to start implementation.
Read this file, the design spec
(`2026-08-20-ecosystem-tools-design.md`, sections 4 and 9 plus both
implementation-notes appendices),
and AGENTS.md before writing any code.

## Where the repository stands

- `main` is `5c9df2c`, tagged `v0.5.0`,
  and the experiment GitLab mirrors both.
- Phases A (npm + pypi) and B (cargo) are fully landed:
  seven catalog tools, every gate green at that commit —
  validate-catalog OK (7 tools), run-validator-tests 99,
  run-approve-tests 175, run-harness-selftest OK,
  poc-test 81/81, bootstrap-test 28/28, offline-test 15/15.
- Each phase went through a Codex post-implementation review loop to an
  explicit merge verdict
  (reports under `tmp/`, not tracked; the durable outcomes are in the
  spec's implementation notes and `docs/research/SYNTHESIS.md`
  entries 20-21).
- Branches `feat/ecosystem-tools` and `feat/cargo-tools` are merged
  and can be deleted.

## What Phase C is

Make `MISE_VAULT_NPM_RUNNER=bun` a working runner instead of the
current recognized-but-rejected value.
The design spec is authoritative; its two empirical gates come first,
and the phase ships ONLY if both pass:

1. **Placement**: verify `bun add -g <package>@<version>` with
   `BUN_INSTALL_GLOBAL_DIR=<install_path>` and
   `BUN_INSTALL_BIN=<install_path>/bin` really pins the install to
   those directories.
   Both the command form and the variables are unverified research
   claims — bun has never been installed on this machine.
2. **Registry inheritance**: verify bun honors the environment's npm
   registry configuration.
   `.npmrc` support varies by bun version; a bun that silently
   reaches the public registry is disqualifying until it is
   configured via `bunfig.toml`,
   and the user documentation must then carry the bunfig channel in
   the per-runner table.

If bun cannot be pinned to the target directories,
the bun runner ships as an explicit error naming that limitation —
never a silent fallback to npm.
Pin `DO_NOT_TRACK=1` (noise suppression, per the spec's pinned-set
guarantee).

## Environment work before any plugin code

- bun is NOT installed on this machine and not in the experiment
  test image.
  Install it locally for the empirical gates
  (official installer; keep the mirror-override convention —
  see `UV_INSTALL_URL` / `RUSTUP_INSTALL_URL` in
  `experiment/test-image/Dockerfile` for the pattern).
- Decide empirically whether the throwaway-HOME poc environment can
  drive bun (where its binary lives, whether it needs HOME-relative
  state the suite must accommodate —
  compare the RUSTUP_HOME accommodation in poc-test's cargo phase).
- Nexus: bun speaks the npm registry protocol,
  so the existing `npm-proxy` repository should serve it —
  verify against the experiment stack, do not assume.

## Files you will touch (mirror the npm-runner diff shape)

- `hooks/backend_install.lua` — replace the bun rejection inside the
  npm branch with the real command path
  (the accepted-value set of `MISE_VAULT_NPM_RUNNER` stays `npm|bun`;
  runner selection, trailer discipline, existence check, and pinned
  env all follow the existing npm/pipx/uv blocks).
  The bun trailer needs its own marker (e.g. `BUNINSTALL_EXIT`) and a
  forged-trailer poc regression like every other command shape.
- `experiment/scripts/poc-test` — bun cases mirroring the npm ones:
  approved install through the Nexus npm proxy, binary runs,
  registry-channel differential for whatever config channel bun
  actually reads (.npmrc or bunfig.toml — record which, per version),
  pinned-env and exact-argv assertions (fake-bun shim),
  runner-missing guidance,
  and the existing bun-rejection check flips to a success-path check.
- `experiment/test-image/Dockerfile`, `experiment/README.md` —
  bun toolchain layer with a mirror-overridable installer URL.
- `offline-suite` — a bun case from the warmed npm-proxy cache.
- Docs trail: README (runner table row, pinned-env row, verified
  versions), development guide, design document section on ecosystem
  types, SYNTHESIS entry, spec implementation notes for Phase C.
  AGENTS.md: the "bun reads bunfig.toml / verify in Phase C" wording
  in the spec and README resolves to whatever the experiment shows;
  add any new empirical lessons in the existing entry style.

## Process expectations (unchanged from Phases A and B)

- Implementation is dispatched to a cheaper model (sonnet) with tight
  self-contained prompts; the main thread verifies EVERYTHING itself —
  subagent reports have contained real errors
  (a miscounted test tally, an invented arithmetic;
  always re-run the suites and diff check lists yourself).
- Review loop: the post-impl-review skill with the Codex plugin tier
  (codex:codex-rescue subagent, `--wait --model gpt-5.6-sol
  --effort xhigh --write`, step down per its convention).
  If dispatching bare `codex exec` yourself:
  ALWAYS redirect stdin from /dev/null and set a timeout —
  a sol dispatch without it has stalled indefinitely on
  "Reading additional input from stdin...".
  Loop fix -> delta re-review until an explicit merge verdict.
- Fixes found by review are amended into the single feat commit
  (`git commit --amend`), keeping the branch one-feat-commit ahead of
  main; force-push the experiment remote and re-run bootstrap-test
  and offline-test on every new hash.
- Verification ladder per change:
  validate-catalog -> run-validator-tests -> run-approve-tests ->
  run-harness-selftest -> full poc-test (docker stack up) ->
  after commit + `git push experiment <branch>:main`,
  bootstrap-test and offline-test.
- Finish: ff-merge to main, bump `metadata.lua` to 0.6.0,
  tag `v0.6.0`, push main and the tag to experiment.
- Commit style: Conventional Commits, plain English,
  no attribution trailers, no numbered internal citations
  (review rounds have repeatedly flagged "design doc section N" /
  "decision N" in comments — state the rule itself instead).

## Deferred items (recorded so they are not lost; none block Phase C)

- pipx older than the introduction of `PIPX_MAN_DIR` /
  `PIPX_COMPLETION_DIR` / `PIPX_DEFAULT_BACKEND` / `PIPX_FETCH_PYTHON`
  silently ignores those pins — the no-leftover-files and
  pinned-backend guarantees need a recent pipx
  (documented in README; revisit if the company standardizes a
  pipx version).
- Scoped npm packages (`@scope/name`) are covered by fixtures only;
  the first real scoped catalog tool adds end-to-end coverage.
- pip-style hash pinning via a temp requirements file for the pipx
  runner: known path, explicitly out of scope until wanted.
- Uppercase prerelease versions (`1.0.0-RC.1`) are deliberately
  unapprovable; widening the version grammars is a reviewed change
  (schema, validator, fixtures move together).
- Production-side config checks from the owner's pasted snippets
  (possibly transcription artifacts — verify against the real files):
  pip `trusted-host` must equal the index host;
  cargo `[net] proxy` is not a valid key (`proxy` lives in `[http]`);
  uv `allow-insecure-host` takes a LIST of hosts.
- Existing experiment stacks provisioned before the cargo-proxy
  repository must re-run `provision-nexus.sh` once
  (role privileges are now create-or-update).
- Branch cleanup: delete merged `feat/ecosystem-tools` and
  `feat/cargo-tools`.
