# Python test harness — design

Date: 2026-08-19
Status: approved design, pending implementation

## Problem

The four test suites are standalone bash scripts
that each re-implement the same scaffolding,
and bash itself is the main source of friction:

- The `PASS`/`FAIL` counters and the `ok()`/`bad()` reporters are copied into all four suites;
  only `poc-test.sh` has the `check`/`check_fail` helpers,
  so the other suites hand-write long `&& ok || bad` chains.
- The `.netrc` heredoc, the isolated-`$HOME` setup, the keep-on-failure cleanup,
  and the endpoint constants are each duplicated per suite.
- Reading expected versions from the catalog is done
  by shelling out to python one-liners from bash.
- Bash traps keep biting:
  pipefail swallowing grep results,
  quoting around captured output,
  secondary `$HOME`s requiring sub-shell tricks,
  background server processes needing manual readiness polling and `trap` cleanup.
- Adding a new check means copying an existing `&& ok || bad` block
  and editing it in three places.

## Decision

Rewrite the four test suites in Python using only the standard library,
on top of a small shared harness (~150 lines).
The suites stay sequential, stateful, phase-structured scenario scripts —
that shape matches what they test
(install a plugin, link the working tree, then verify behavior step by step),
so no test framework that assumes independent test cases is used.

Explicitly rejected:

- `unittest`:
  assumes independent, alphabetically-ordered test methods;
  the end-to-end suites are strictly ordered and share state,
  so the framework would be fought, not used.
- `pytest` or `bats-core`:
  external dependencies;
  the suites must run in the offline network,
  and python3 is the only runtime the test image is guaranteed to have
  (it is already required by `scripts/validate-catalog` and the current suites themselves).
- Migrating `provision-*`/`seed-*` scripts:
  they are curl/docker orchestration, stable, and not a pain point.
  They stay bash.

## Scope

In scope:
`experiment/scripts/poc-test.sh`,
`experiment/scripts/bootstrap-test.sh`,
`experiment/scripts/offline-test.sh`,
`tests/run-validator-tests`,
and the documentation that references them.

Out of scope:
`provision-nexus.sh`, `provision-gitlab.sh`, `provision-runner.sh`,
`seed-artifacts.sh`, `seed-extra-platforms.sh`, `install.sh`,
everything under `scripts/`,
and any change to what the suites assert.

**This migration changes the vehicle, not the tests.**
Every check migrates 1:1 —
same assertions, same phase structure, same fail-closed coverage.
No checks are added, removed, or weakened.

## File layout

```
tests/
  lib/
    __init__.py
    harness.py        # Suite: check bookkeeping, phase headers, summary, exit code
    env.py            # IsolatedHome, endpoint constants, netrc / mise-config writers
    catalog.py        # catalog readers (versions, latest), fixture sha256 rewrite
    servers.py        # redirect-trap HTTP server (context manager)
  run-validator-tests           # rewritten in Python; path unchanged (CI untouched)
experiment/scripts/
  poc-test            # Python, no extension (matches scripts/ house style)
  bootstrap-test      # Python, no extension
  offline-test        # host-side wrapper: docker run + repo mount
  offline-suite       # inner suite run inside the container (replaces the heredoc)
```

The old `.sh` files are deleted —
each one only after its replacement passes the equivalence check (see Verification).

All entry points are executable with a `#!/usr/bin/env python3` shebang.
Suites locate `tests/lib` relative to their own file path
(repo-root anchored `sys.path` insertion),
so they work from any working directory,
exactly like the current `BASH_SOURCE` logic.

## Harness API

### `harness.py`

```python
r = run(["mise", "install", f"glab@{v}"], env=home.env, timeout=120)
# -> Result(rc, out, err); r.ok == (rc == 0); never raises; text mode
# timeout expiry returns a failed Result, it does not raise

s = Suite("poc-test")
s.phase("Phase 4: installs (download via curl -n + sha256 + extract)")
s.check("install glab (bin/ layout, strip=0)", r.ok, detail=r.tail())
s.check_cmd("install go (runtime distribution)", [...], env=home.env)
s.check_fail("unapproved version rejected", [...], env=home.env)
s.note("MISE_OFFLINE=1 does NOT block the plugin's own download")  # INFO line
sys.exit(s.finish(keep_on_failure=[home]))
```

- `run()` wraps `subprocess.run`
  with `capture_output=True, text=True` and a default 120-second timeout.
  It never raises:
  a missing binary or a timeout becomes a failed `Result` with the reason in `err`.
  `Result.tail(n=200)` returns the last portion of combined output for failure details.
- `check(desc, cond, detail=None)` records and prints `  PASS  desc` or `  FAIL  desc`;
  on failure the detail is appended,
  truncated to ~200 characters (the current convention).
- `check_cmd` / `check_fail` are the command-shaped shortcuts:
  the command must succeed / must fail.
  `check_fail` reports the exit code and output tail
  when the command unexpectedly succeeds.
- `phase(title)` prints the `== title ==` section header.
- `note(text)` prints an `  INFO  ` line
  (documenting, not gating —
  used by the offline suite's `MISE_OFFLINE` section).
- `finish(keep_on_failure=[...])` prints `RESULT: N passed, N failed`,
  removes the listed `IsolatedHome`s when everything passed,
  keeps them (and says so, with paths) when anything failed,
  and returns the exit code (0/1).

### `env.py`

- Endpoint constants for both address families, selected explicitly:
  workstation-side (`http://127.0.0.3:8929` GitLab, `http://127.0.0.2:8081` Nexus)
  and container-side (`http://gitlab:8929`, `http://nexus:8081`).
  Test credentials stay here in one place
  (they are experiment-only values, already committed in `experiment/README.md`).
- `IsolatedHome`:
  creates a `mktemp`-style directory,
  writes `.netrc` (mode 600) and the mise settings (`gix = false`, `libgit2 = false`),
  and exposes `home.env` —
  a copy of `os.environ` with `HOME` replaced
  and every `MISE_*` override variable removed.
  **`HOME` is never exported globally**;
  each `run()` call receives the environment explicitly.
  Secondary homes
  (bootstrap-test's tag-pinned phase, poc-test's auto-install phase)
  are just additional `IsolatedHome` instances —
  no sub-shell tricks.
- Writers for the generated files the suites need:
  the conf.d alias file (with or without per-tool `nexus_url` options)
  and a project `mise.toml` / `.tool-versions`.

### `catalog.py`

- `versions(tool, root)` / `latest(tool, root)` read
  `<root>/catalog/<tool>/versions.json` with the `json` module.
  `root` points at the working tree, the bootstrap clone, or the linked plugin copy —
  expected values keep coming from the catalog,
  so approving a new version never requires editing a suite.
- `set_sha256(versions_file, platform, sha)` rewrites a fixture's checksum
  (poc-test's redirect phase corrects the smoke fixture in the linked copy).

### `servers.py`

- `redirect_server(port, target, log_path)`:
  a context manager running `http.server` on a daemon thread.
  Every request is appended to `log_path`
  and answered with a 302 to `target + path`.
  Entering the context blocks until the server answers (readiness handshake);
  exiting shuts it down.
  Replaces the current background-process + trap + poll-loop arrangement.

## Per-suite migration notes

Checks migrate 1:1 from the bash originals.
The rationale comments —
for example "assert the EFFECT (command fails, no versions listed), not mise's wording"
and "both must be false — either one being true selects mise's built-in git" —
carry over verbatim;
they are where the project's hard-won lessons live in the code.

- **`tests/run-validator-tests`** —
  first consumer of the harness;
  no network, so it validates the harness shape cheaply.
  Same path and name, so `.gitlab-ci.yml` needs no change.
  The fixture discovery, the minimum-case count, the built-in-engine loop,
  and the schema-drift loop (with the jsonschema-not-installed NOTE)
  all migrate as-is.
- **`bootstrap-test`** —
  the two-home structure (main flow + tag-pinned phase 6)
  becomes two `IsolatedHome`s.
  The phase-6 exit-code `case` dispatch becomes ordinary sequential checks.
- **`poc-test`** —
  the working-tree link
  (copy `metadata.lua`, `hooks/`, `lib/`, `config/`, `catalog/`
  plus the two fixture tools into the isolated plugin dir)
  becomes a helper in the suite.
  The embedded python redirect server and the sha256-correction snippet
  move into `servers.py` / `catalog.py`.
  The conf.d `sed` edits become a rewrite via the env writer.
  The lifecycle tags stay overridable via `EXPERIMENT_TAG_A` / `_B`.
- **`offline-test`** —
  the host wrapper composes
  `docker run --rm --network mise-vault-experiment_isolated -v <repo>:/repo:ro mise-vault-test python3 /repo/experiment/scripts/offline-suite`
  and passes the docker exit code through.
  The inner suite imports `/repo/tests/lib`,
  uses the container-side endpoints,
  and keeps writing its `.netrc` against the `gitlab`/`nexus` hostnames.
  The repo mount is read-only;
  the inner suite works entirely under the container's own `$HOME` and `/tmp`,
  exactly as the heredoc version does today.

## Error handling and diagnostics

- A failed check never aborts the suite;
  the remaining checks still run
  (current behavior, preserved by design).
- Every `check_cmd`/`check_fail` failure prints the exit code and a truncated output tail,
  so a red CI run is diagnosable from the log alone.
- On any failure the isolated HOMEs are kept and their paths printed;
  on full success they are removed.
- `run()`'s default timeout (120 s, overridable per call)
  replaces the ad-hoc `timeout 30` wrappers
  and guarantees a hung mise invocation cannot hang a suite forever.

## Verification (per suite, before deleting its `.sh`)

1. Against the same running experiment stack,
   run the bash original and the Python replacement back to back.
   The set of check descriptions and the PASS count must match
   (modulo agreed wording tweaks, listed in the migration commit message).
2. Break one expectation on purpose
   (for example, edit an expected version)
   and confirm the Python suite reports FAIL, exits 1, and keeps the HOME.
3. Only then delete the corresponding `.sh`
   in the same commit as its replacement's final form.

`bootstrap-test` and `offline-test` additionally require
the experiment GitLab to serve the local HEAD
(push to the experiment remote first — same requirement as today).

## Documentation and CI impact

- `.gitlab-ci.yml`: no change (`tests/run-validator-tests` keeps its path).
- Path updates:
  `README.md`, `experiment/README.md`,
  `docs/development.md` (test-suite table and workflow text),
  `AGENTS.md` (test-suite list),
  `docs/design.md` (repository layout diagram).
- The pipefail lesson in `AGENTS.md` stays:
  the provisioning scripts are still bash
  and the lesson still applies to them.

## Implementation order

Each step lands as its own commit;
a step's suite must pass its equivalence check before the next step starts.

1. `tests/lib` harness modules, with a minimal self-test.
2. Migrate `tests/run-validator-tests` (no network — fastest feedback).
3. Migrate `bootstrap-test`.
4. Migrate `poc-test`.
5. Migrate `offline-test` (wrapper + inner suite).
6. Update documentation references;
   confirm no stale references to the old `.sh` names remain.
