# Python Test Harness Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the four bash test suites with Python equivalents on a small shared stdlib-only harness, migrating every check 1:1.

**Architecture:** A `tests/lib` package (harness, isolated homes, catalog readers, redirect server) shared by four sequential scenario scripts.
Suites stay phase-structured and stateful; no test framework is used.

**Tech Stack:** Python 3 standard library only.
No pip packages, no bash test code.

**Spec:** `docs/superpowers/specs/2026-08-19-python-test-harness-design.md` — read it first; it defines the harness API and the per-suite notes this plan implements.

## Global Constraints

- Python 3 standard library only; no new dependencies anywhere.
- Entry points are executable, extensionless, `#!/usr/bin/env python3` (matches `scripts/` house style).
- **This migration changes the vehicle, not the tests.**
  Every check migrates 1:1:
  same assertions, same phase structure, same order.
  No checks added, removed, or weakened.
- Check descriptions (the text after `PASS`) migrate verbatim from the bash originals.
  Where bash used different `ok`/`bad` wording for one check, the `ok` wording becomes the check description and the failure specifics go into `detail`.
- Rationale comments migrate verbatim (for example "assert the EFFECT (command fails, no versions listed), not mise's wording" and "both must be false — either one being true selects mise's built-in git").
- The suites test external tools (mise, git, curl, install.sh). Python replaces only bash's control flow.
  Never replace a `curl` or `git` invocation that is itself under test with a Python library call.
- Bash-to-Python conversion rules:
  - `grep -qx "$V"` (exact line match) → `V in r.out.splitlines()`
  - `grep -q "$V"` (substring) → `V in r.out`
  - `[ "$(echo $X)" = "$Y" ]` (whitespace-normalized compare) → `" ".join(r.out.split()) == Y`
  - every `run()` of a mise/git command inside an isolated home passes `env=home.env`
  - `timeout 30 cmd` → `run([...], timeout=30)`
- Do not touch: `provision-*.sh`, `seed-*.sh`, `install.sh`, anything under `scripts/`, any hook or catalog file, `.gitlab-ci.yml`.
- Commit messages: Conventional Commits, imperative, lowercase after the colon, no trailing period, **no attribution trailers of any kind**.
- Markdown files in this repo use semantic line breaks (one sentence per line); a hook enforces this.
- There is no configured Python linter; before each commit run `python3 -m py_compile` on every new/changed Python file.
- Delete each old `.sh` only in the same commit that lands its verified replacement.

## Execution environment facts

- The experiment stack is already up: containers `mv-gitlab` / `mv-nexus`, network `mise-vault-experiment_isolated`, test image `mise-vault-test`.
- Git remote `experiment` points at the experiment GitLab with a push-capable token.
- `bootstrap-test` asserts that the experiment GitLab default branch equals the local HEAD.
  Before running it, push the current commit: `git push experiment HEAD:main` (add `-f` only if rejected; the experiment GitLab is disposable).
- Suite runtimes: `run-validator-tests` seconds; each end-to-end suite ~2 minutes.

---

### Task 1: `tests/lib` harness package with self-test

**Files:**
- Create: `tests/lib/__init__.py` (empty)
- Create: `tests/lib/harness.py`
- Create: `tests/lib/env.py`
- Create: `tests/lib/catalog.py`
- Create: `tests/lib/servers.py`
- Create: `tests/run-harness-selftest` (executable)

**Interfaces (Produces — later tasks rely on these exact names):**
- `harness.run(cmd, env=None, timeout=120, cwd=None) -> Result`; `Result.rc/.out/.err/.ok/.tail(n=200)`
- `harness.Suite(name)` with `.phase(title)`, `.check(desc, cond, detail=None) -> bool`, `.check_cmd(desc, cmd, **run_kwargs) -> Result`, `.check_fail(desc, cmd, **run_kwargs) -> Result`, `.note(text, tag="INFO")`, `.ok(desc)`, `.bad(desc, detail=None)`, `.finish(keep_on_failure=()) -> int`
- `env.GITLAB_HOST_URL`, `env.NEXUS_HOST_URL`, `env.GITLAB_CONTAINER_URL`, `env.NEXUS_CONTAINER_URL`, `env.HOST_MACHINES`, `env.CONTAINER_MACHINES`
- `env.write_netrc(home_dir, machines)`, `env.write_aliases(home_dir, aliases_dict)`
- `env.IsolatedHome(prefix, machines=HOST_MACHINES, write_settings=True)` with `.path`, `.env`, `.write_aliases(dict)`, `.remove()`
- `catalog.versions(tool, root) -> list[str]`, `catalog.latest(tool, root) -> str`, `catalog.set_sha256(versions_file, platform, sha)`
- `servers.redirect_server(port, target, log_path)` context manager

- [ ] **Step 1: Write the failing self-test**

Create `tests/run-harness-selftest`, executable, with this content:

```python
#!/usr/bin/env python3
# Self-test for tests/lib: exercises the harness with no network and no
# experiment stack, so a broken helper is caught before any suite uses it.
import http.client
import io
import sys
from contextlib import redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lib.harness import Result, Suite, run
from lib import catalog, env, servers

ROOT = Path(__file__).resolve().parent.parent
failures = []


def expect(desc, cond):
    print(("  PASS  " if cond else "  FAIL  ") + desc, flush=True)
    if not cond:
        failures.append(desc)


# --- run() ---
r = run(["true"])
expect("run: zero exit reported ok", r.ok and r.rc == 0)
r = run(["false"])
expect("run: nonzero exit reported not ok", not r.ok)
r = run(["sh", "-c", "echo out; echo err >&2; exit 3"])
expect("run: captures stdout/stderr/rc", r.rc == 3 and "out" in r.out and "err" in r.err)
r = run(["sleep", "5"], timeout=1)
expect("run: timeout becomes a failed Result, not an exception",
       not r.ok and "timed out" in r.err)
r = run(["this-binary-does-not-exist-xyz"])
expect("run: missing binary becomes a failed Result", not r.ok)
expect("run: tail() flattens and truncates",
       Result(0, "a\n" * 300, "").tail(10) == ("a " * 300).strip()[-10:])

# --- Suite bookkeeping and output format ---
buf = io.StringIO()
with redirect_stdout(buf):
    s = Suite("selftest-inner")
    s.phase("Phase X")
    s.check("good", True)
    s.check("bad", False, detail="why it broke")
    s.check_cmd("cmd ok", ["true"])
    s.check_fail("cmd must fail", ["false"])
    rc = s.finish()
out = buf.getvalue()
expect("Suite: counts passes and failures", s.passed == 3 and s.failed == 1)
expect("Suite: failure makes finish() return 1", rc == 1)
expect("Suite: PASS/FAIL line format", "  PASS  good" in out and "  FAIL  bad" in out)
expect("Suite: failure detail printed", "why it broke" in out)
expect("Suite: phase header format", "== Phase X ==" in out)
expect("Suite: summary line", "RESULT: 3 passed, 1 failed" in out)
buf = io.StringIO()
with redirect_stdout(buf):
    s2 = Suite("selftest-inner2")
    s2.check("fine", True)
    rc2 = s2.finish()
expect("Suite: all-pass makes finish() return 0", rc2 == 0)

# --- IsolatedHome ---
home = env.IsolatedHome("selftest.")
netrc = home.path / ".netrc"
expect("IsolatedHome: netrc written mode 600",
       netrc.exists() and (netrc.stat().st_mode & 0o777) == 0o600)
expect("IsolatedHome: netrc lists the experiment machines",
       "machine 127.0.0.3" in netrc.read_text() and "machine 127.0.0.2" in netrc.read_text())
settings = (home.path / ".config/mise/config.toml").read_text()
expect("IsolatedHome: gix and libgit2 forced off", "gix = false" in settings and "libgit2 = false" in settings)
e = home.env
expect("IsolatedHome: env swaps HOME and strips MISE_* overrides",
       e["HOME"] == str(home.path) and not any(k.startswith("MISE_") for k in e))
expect("IsolatedHome: env disables git prompts", e.get("GIT_TERMINAL_PROMPT") == "0")
home.write_aliases({"glab": "vault:glab"})
conf = (home.path / ".config/mise/conf.d/mise-vault.toml").read_text()
expect("IsolatedHome: alias writer emits tool_alias entries",
       "[tool_alias]" in conf and 'glab = "vault:glab"' in conf)
kept = env.IsolatedHome("selftest-keep.")
buf = io.StringIO()
with redirect_stdout(buf):
    s3 = Suite("selftest-inner3")
    s3.check("boom", False)
    s3.finish(keep_on_failure=[kept])
expect("Suite: failing finish keeps the home and prints its path",
       kept.path.exists() and str(kept.path) in buf.getvalue())
kept.remove()
buf = io.StringIO()
with redirect_stdout(buf):
    s4 = Suite("selftest-inner4")
    s4.check("fine", True)
    s4.finish(keep_on_failure=[home])
expect("Suite: passing finish removes the home", not home.path.exists())

# --- catalog ---
vs = catalog.versions("go", ROOT)
expect("catalog: versions() returns the ordered list", len(vs) >= 1 and vs[-1] == catalog.latest("go", ROOT))

# --- redirect server ---
log = Path("/tmp/selftest-redirect.log")
log.write_text("")
with servers.redirect_server(18099, "http://127.0.0.2:8081", str(log)):
    conn = http.client.HTTPConnection("127.0.0.1", 18099, timeout=5)
    conn.request("GET", "/probe/path")
    resp = conn.getresponse()
    expect("redirect_server: answers 302 toward the target",
           resp.status == 302 and resp.getheader("Location") == "http://127.0.0.2:8081/probe/path")
expect("redirect_server: logs every request path", "/probe/path" in log.read_text())
log.unlink()

print(f"\nrun-harness-selftest: {'OK' if not failures else 'FAILED: ' + ', '.join(failures)}", flush=True)
sys.exit(1 if failures else 0)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `chmod +x tests/run-harness-selftest && tests/run-harness-selftest`
Expected: ImportError (lib modules do not exist yet).

- [ ] **Step 3: Implement `tests/lib/harness.py`**

```python
"""Check bookkeeping shared by the test suites.

A suite is a sequential scenario script: a failed check never aborts the
run, it is counted and the remaining checks still execute.
"""
import subprocess

DETAIL_LIMIT = 200


def _text(v):
    if isinstance(v, bytes):
        return v.decode(errors="replace")
    return v or ""


class Result:
    """Outcome of one external command; never raises."""

    def __init__(self, rc, out, err):
        self.rc = rc
        self.out = out
        self.err = err

    @property
    def ok(self):
        return self.rc == 0

    def tail(self, n=DETAIL_LIMIT):
        """Last n characters of combined output, whitespace-flattened."""
        combined = " ".join((self.out + " " + self.err).split())
        return combined[-n:]


def run(cmd, env=None, timeout=120, cwd=None):
    """Run a command, capturing text output. Errors (missing binary,
    timeout) come back as a failed Result instead of an exception, so a
    suite can keep going and report them as ordinary check failures."""
    try:
        p = subprocess.run(cmd, env=env, cwd=cwd, capture_output=True,
                           text=True, timeout=timeout)
        return Result(p.returncode, p.stdout, p.stderr)
    except subprocess.TimeoutExpired as e:
        return Result(124, _text(e.stdout),
                      _text(e.stderr) + f" [timed out after {timeout}s]")
    except OSError as e:
        return Result(127, "", str(e))


class Suite:
    def __init__(self, name):
        self.name = name
        self.passed = 0
        self.failed = 0

    def phase(self, title):
        print(f"\n== {title} ==", flush=True)

    def ok(self, desc):
        self.passed += 1
        print(f"  PASS  {desc}", flush=True)

    def bad(self, desc, detail=None):
        self.failed += 1
        line = f"  FAIL  {desc}"
        if detail:
            line += f" ({str(detail)[:DETAIL_LIMIT]})"
        print(line, flush=True)

    def check(self, desc, cond, detail=None):
        if cond:
            self.ok(desc)
        else:
            self.bad(desc, detail)
        return bool(cond)

    def check_cmd(self, desc, cmd, **run_kwargs):
        """The command must succeed."""
        r = run(cmd, **run_kwargs)
        self.check(desc, r.ok, detail=f"exit={r.rc}; {r.tail()}")
        return r

    def check_fail(self, desc, cmd, **run_kwargs):
        """The command must fail (fail-closed paths)."""
        r = run(cmd, **run_kwargs)
        self.check(desc, not r.ok, detail=f"unexpectedly succeeded; {r.tail()}")
        return r

    def note(self, text, tag="INFO"):
        print(f"  {tag}  {text}", flush=True)

    def finish(self, keep_on_failure=()):
        """Print the summary; on success remove the listed homes, on
        failure keep them for inspection. Returns the process exit code."""
        print(flush=True)
        if self.failed == 0:
            for home in keep_on_failure:
                home.remove()
            print(f"RESULT: {self.passed} passed, 0 failed", flush=True)
            return 0
        kept = ", ".join(str(h.path) for h in keep_on_failure if h.path.exists())
        suffix = f"   (kept for inspection: {kept})" if kept else ""
        print(f"RESULT: {self.passed} passed, {self.failed} failed{suffix}", flush=True)
        return 1
```

- [ ] **Step 4: Implement `tests/lib/env.py`**

```python
"""Isolated test homes and experiment-stack endpoints.

The credentials below are experiment-only values, already public in
experiment/README.md; real deployments never store credentials in files.
"""
import os
import shutil
import tempfile
from pathlib import Path

# distinct loopback IPs => distinct netrc machines (netrc has no port field)
GITLAB_HOST_URL = "http://127.0.0.3:8929"
NEXUS_HOST_URL = "http://127.0.0.2:8081"
# addresses as seen from a container on the compose network
GITLAB_CONTAINER_URL = "http://gitlab:8929"
NEXUS_CONTAINER_URL = "http://nexus:8081"

GITLAB_DEV_TOKEN = "glpat-mise-vault-dev-000001"
NEXUS_DEV_PASSWORD = "dev-mise-vault"

HOST_MACHINES = [("127.0.0.3", "developer", GITLAB_DEV_TOKEN),
                 ("127.0.0.2", "developer", NEXUS_DEV_PASSWORD)]
CONTAINER_MACHINES = [("gitlab", "developer", GITLAB_DEV_TOKEN),
                      ("nexus", "developer", NEXUS_DEV_PASSWORD)]


def write_netrc(home_dir, machines):
    lines = []
    for host, login, password in machines:
        lines += [f"machine {host}", f"  login {login}", f"  password {password}"]
    path = Path(home_dir) / ".netrc"
    path.write_text("\n".join(lines) + "\n")
    path.chmod(0o600)


def write_aliases(home_dir, aliases):
    """Write the conf.d alias file a real bootstrap would generate."""
    conf_dir = Path(home_dir) / ".config/mise/conf.d"
    conf_dir.mkdir(parents=True, exist_ok=True)
    body = "[tool_alias]\n" + "".join(f'{k} = "{v}"\n' for k, v in aliases.items())
    (conf_dir / "mise-vault.toml").write_text(body)


class IsolatedHome:
    """A throwaway $HOME with netrc and the bootstrap mise settings.

    HOME is never exported into this process; run() calls receive
    home.env explicitly, so several isolated homes can coexist."""

    def __init__(self, prefix, machines=HOST_MACHINES, write_settings=True):
        self.path = Path(tempfile.mkdtemp(prefix=prefix, dir="/tmp"))
        write_netrc(self.path, machines)
        if write_settings:
            cfg = self.path / ".config/mise"
            cfg.mkdir(parents=True)
            # both must be false — either one being true selects mise's
            # built-in git, which ignores netrc and credential helpers
            (cfg / "config.toml").write_text("[settings]\ngix = false\nlibgit2 = false\n")

    @property
    def env(self):
        e = {k: v for k, v in os.environ.items() if not k.startswith("MISE_")}
        e["HOME"] = str(self.path)
        e["GIT_TERMINAL_PROMPT"] = "0"
        return e

    def write_aliases(self, aliases):
        write_aliases(self.path, aliases)

    def remove(self):
        shutil.rmtree(self.path, ignore_errors=True)
```

- [ ] **Step 5: Implement `tests/lib/catalog.py`**

```python
"""Read expected values from the catalog, so approving a new version
never requires editing a test suite."""
import json
from pathlib import Path


def versions(tool, root):
    """All approved versions of a tool, catalog order (oldest first)."""
    path = Path(root) / "catalog" / tool / "versions.json"
    return [r["version"] for r in json.loads(path.read_text())]


def latest(tool, root):
    return versions(tool, root)[-1]


def set_sha256(versions_file, platform, sha):
    """Rewrite a fixture's checksum (test fixtures only, never the real
    catalog)."""
    path = Path(versions_file)
    recs = json.loads(path.read_text())
    recs[0]["platforms"][platform]["sha256"] = sha
    path.write_text(json.dumps(recs, indent=2))
```

- [ ] **Step 6: Implement `tests/lib/servers.py`**

```python
"""A server that answers every request with a redirect to the real
artifact store: if the plugin followed redirects an install through it
would succeed, so a failure proves redirects are refused, not merely
that the target was down. Every request path is appended to a log so a
test can prove the plugin actually reached this server."""
import http.client
import threading
import time
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, HTTPServer


@contextmanager
def redirect_server(port, target, log_path):
    class Handler(BaseHTTPRequestHandler):
        def _redirect(self):
            with open(log_path, "a") as f:
                f.write(self.path + "\n")
            self.send_response(302)
            self.send_header("Location", target + self.path)
            self.end_headers()

        do_GET = _redirect
        do_HEAD = _redirect

        def log_message(self, *args):
            pass

    server = HTTPServer(("127.0.0.1", port), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        _wait_until_answering(port)
        yield server
    finally:
        server.shutdown()
        server.server_close()


def _wait_until_answering(port, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
            conn.request("GET", "/ready")
            if conn.getresponse().status == 302:
                return
        except OSError:
            pass
        time.sleep(0.25)
    raise RuntimeError(f"redirect server did not come up on 127.0.0.1:{port}")
```

Also create the empty `tests/lib/__init__.py`.

- [ ] **Step 7: Run the self-test until it passes**

Run: `tests/run-harness-selftest`
Expected: every line PASS, final line `run-harness-selftest: OK`, exit 0.
Fix harness code (not the self-test's expectations) until it does.

- [ ] **Step 8: Compile-check and commit**

```bash
python3 -m py_compile tests/lib/*.py tests/run-harness-selftest
git add tests/lib tests/run-harness-selftest
git commit -m "test: add shared python harness for the test suites"
```

---

### Task 2: Port `tests/run-validator-tests`

**Files:**
- Rewrite: `tests/run-validator-tests` (same path and name — `.gitlab-ci.yml` must stay untouched)
- Read (reference): the current bash version of the same file at `git show HEAD:tests/run-validator-tests`

**Interfaces:**
- Consumes: `Suite`, `run` from Task 1.
- Produces: nothing new.

- [ ] **Step 1: Capture the bash baseline**

```bash
tests/run-validator-tests | tee /tmp/validator-bash.out
```

Expected: exits 0. Keep the output for the equivalence diff.

- [ ] **Step 2: Rewrite the file in Python**

Replace the file's content with:

```python
#!/usr/bin/env python3
# Validator rejection tests: the catalog is the security boundary, so the
# validator must provably reject unsafe or malformed catalog entries, not
# only accept the good ones.
#
#   1. the real catalog must validate
#   2. every case under tests/fixtures/invalid-catalog/<case>/ must be
#      rejected by the built-in engine (always available, no dependencies)
#   3. when the jsonschema package is installed (as in CI), the cases a
#      formal schema can express must ALSO be rejected by the schemas ALONE
#      (--engine schema) — this is what keeps the two rule sets from
#      drifting apart: a schema gap fails here even though the built-in
#      engine would still have caught the bad entry
#
# No network needed. Exit 0 = all good, 1 = any failure.
import importlib.util
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lib.harness import Suite, run

ROOT = Path(__file__).resolve().parent.parent
VALIDATE = str(ROOT / "scripts" / "validate-catalog")
FIXTURES = ROOT / "tests" / "fixtures" / "invalid-catalog"
# cases a formal JSON Schema can express on its own (single-file shape rules);
# the rest are cross-file rules that only the built-in/cross checks cover
SCHEMA_CASES = ["artifact-traversal", "artifact-shell-metacharacters",
                "artifact-missing-version", "bin-path-absolute",
                "bin-path-traversal", "bad-sha256", "unknown-field",
                "invalid-format"]
MIN_CASES = 12

s = Suite("run-validator-tests")

r = run([VALIDATE])
s.check("real catalog accepted", r.ok,
        detail="real catalog must validate cleanly: " + r.tail())

# a vanished fixture directory must fail the suite, not silently skip it
cases = sorted(p for p in FIXTURES.iterdir() if p.is_dir()) if FIXTURES.is_dir() else []
s.check(f"fixture matrix present ({len(cases)} cases, expected >= {MIN_CASES})",
        len(cases) >= MIN_CASES,
        detail=f"found under {FIXTURES}")

for case in cases:
    r = run([VALIDATE, "--engine", "builtin", "--catalog-dir", str(case)])
    s.check(f"built-in engine rejects: {case.name}", not r.ok,
            detail="output: " + r.tail())

if importlib.util.find_spec("jsonschema"):
    for name in SCHEMA_CASES:
        r = run([VALIDATE, "--engine", "schema", "--catalog-dir", str(FIXTURES / name)])
        s.check(f"schemas alone reject: {name}", not r.ok,
                detail="schemas/ has drifted behind the built-in rules; output: " + r.tail())
else:
    s.note("jsonschema not installed — schema-only passes skipped (CI runs them)", tag="NOTE")

sys.exit(s.finish())
```

- [ ] **Step 3: Equivalence check**

```bash
tests/run-validator-tests | tee /tmp/validator-py.out
grep '^  PASS' /tmp/validator-bash.out | sort > /tmp/a
grep '^  PASS' /tmp/validator-py.out  | sort > /tmp/b
diff /tmp/a /tmp/b
```

Expected: exit 0 from the suite and an empty diff.
(The final summary line changes from `run-validator-tests: N passed...` to `RESULT: N passed...` — an agreed normalization, not a check.)

- [ ] **Step 4: Sabotage check (must fail loudly)**

```bash
python3 - <<'PY'
import json
p = "catalog/go/tool.json"
d = json.load(open(p)); d["not_a_real_field"] = True
json.dump(d, open(p, "w"), indent=2)
PY
tests/run-validator-tests; echo "exit=$?"
git checkout -- catalog/go/tool.json
```

Expected: `real catalog accepted` reports FAIL and the suite exits 1.

- [ ] **Step 5: Compile-check and commit**

```bash
python3 -m py_compile tests/run-validator-tests
git add tests/run-validator-tests
git commit -m "test: port run-validator-tests to the python harness"
```

---

### Task 3: Port `bootstrap-test`

**Files:**
- Create: `experiment/scripts/bootstrap-test` (executable Python)
- Delete: `experiment/scripts/bootstrap-test.sh` (same commit, after verification)
- Reference: read `experiment/scripts/bootstrap-test.sh` in full before writing any code — it is the source of truth for every check.

**Interfaces:**
- Consumes: `Suite`, `run`, `IsolatedHome`, `GITLAB_HOST_URL`, `catalog.versions/latest` from Task 1.

**Suite skeleton** (top of file; header comment carried over from the `.sh`):

```python
#!/usr/bin/env python3
# End-to-end bootstrap test: the full new-developer flow
# in a fresh isolated HOME, driven only by git clone + ~/.netrc.
#
# The MAIN flow (phases 1-5) bootstraps from the experiment GitLab's default
# branch, which must equal the local HEAD — so every assertion about machine
# state is made against the code under review, never against an older tag.
# Phase 6 separately proves that a tag-pinned bootstrap works, in its own HOME.
import os
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "tests"))
from lib import catalog
from lib.env import GITLAB_HOST_URL, GITLAB_DEV_TOKEN, IsolatedHome
from lib.harness import Suite, run

PIN_REF = os.environ.get("EXPERIMENT_PIN_TAG", "v0.0.14")  # pin/re-pin coverage only
s = Suite("bootstrap-test")
home = IsolatedHome("mise-vault-bootstrap.")
```

- [ ] **Step 1: Push HEAD and capture the bash baseline**

```bash
git push experiment HEAD:main
./experiment/scripts/bootstrap-test.sh | tee /tmp/bootstrap-bash.out; echo "exit=$?"
```

Expected: exit 0.
If any check fails, STOP and report — the baseline must be green before porting.

- [ ] **Step 2: Port the six phases 1:1**

Work through `bootstrap-test.sh` top to bottom;
every `ok`/`bad` pair becomes one harness call with the same description.
Conversion notes for the non-obvious spots:

- Phase 1 clone: `run(["git", "clone", "-q", "--depth", "1", f"{GITLAB_HOST_URL}/devtools/mise-vault.git", str(home.path / "bootstrap")], env=home.env)`.
- HEAD comparison: local HEAD via `run(["git", "-C", str(REPO_ROOT), "rev-parse", "HEAD"])`, cloned HEAD likewise against the clone; keep the bash FAIL message about pushing to the experiment remote.
- `install.sh` runs: `run([str(home.path / "bootstrap/install.sh")], env=home.env)`; the bash version redirected to a log file — instead keep the `Result` and grep `r.out + r.err` for `version {expect}`.
- The API raw fetch stays a real curl call (it verifies the documented endpoint): `run(["curl", "-fsSL", "-H", f"PRIVATE-TOKEN: {GITLAB_DEV_TOKEN}", f"{GITLAB_HOST_URL}/api/v4/projects/devtools%2Fmise-vault/repository/files/install.sh/raw?ref={cloned}"], env=home.env)` and check the first output line is the bash shebang.
- Phase 2 settings checks: `run(["mise", "settings", "gix"], env=home.env)` etc.; carry the "both must be false" comment.
- Phase 3 project flow: build `home.path / "app"` with a `mise.toml`,
  then run `mise trust -q`, `mise install`, `mise exec -- glab --version` with `cwd=str(proj)` and `env=home.env`.
  The jq / aqua fail-closed checks keep their effect-based assertions
  (`r.rc != 0` and no version-looking lines / "disabled" in output)
  and the rationale comment about not asserting mise's wording;
  keep `timeout=30` on both.
- Phase 5 vault-sync: the three `mise run vault-sync ...` invocations use `cwd=str(home.path)`; grep the captured output instead of log files.
- Phase 6: a second `IsolatedHome("mise-vault-bootstrap-tag.")`; run the four steps sequentially and emit ONE check that matches the bash `case`:

```python
tag_home = IsolatedHome("mise-vault-bootstrap-tag.")
r = run(["git", "-c", "advice.detachedHead=false", "clone", "-q", "--depth", "1",
         "-b", PIN_REF, f"{GITLAB_HOST_URL}/devtools/mise-vault.git",
         str(tag_home.path / "bootstrap")], env=tag_home.env)
if not r.ok:
    s.bad("tag clone failed", r.tail())
else:
    r = run([str(tag_home.path / "bootstrap/install.sh")], env=tag_home.env)
    if not r.ok:
        s.bad("tagged install.sh failed", r.tail())
    elif PIN_REF not in r.out + r.err:
        s.bad("tag self-detection missing from install log")
    elif not run(["mise", "ls-remote", "glab"], env=tag_home.env).out.strip():
        s.bad("tagged bootstrap not functional")
    else:
        s.ok(f"tagged checkout ({PIN_REF}) bootstraps, self-detects the tag, and serves the catalog")
tag_home.remove()
```

End with `sys.exit(s.finish(keep_on_failure=[home]))`.

- [ ] **Step 3: Equivalence check**

```bash
chmod +x experiment/scripts/bootstrap-test
./experiment/scripts/bootstrap-test | tee /tmp/bootstrap-py.out; echo "exit=$?"
diff <(grep '^  PASS' /tmp/bootstrap-bash.out | sort) <(grep '^  PASS' /tmp/bootstrap-py.out | sort)
```

Expected: exit 0 and an empty diff (PASS-line descriptions may embed values like the HEAD hash; identical stack + identical HEAD means identical text).

- [ ] **Step 4: Sabotage check**

```bash
EXPERIMENT_PIN_TAG=v9.9.9 ./experiment/scripts/bootstrap-test; echo "exit=$?"
```

Expected: phase 6 reports FAIL (`tag clone failed`), exit 1,
and the summary names a kept HOME under /tmp.
Remove that kept directory afterwards.

- [ ] **Step 5: Compile-check, delete the bash original, commit**

```bash
python3 -m py_compile experiment/scripts/bootstrap-test
git rm experiment/scripts/bootstrap-test.sh
git add experiment/scripts/bootstrap-test
git commit -m "test: port bootstrap-test to the python harness"
```

---

### Task 4: Port `poc-test`

**Files:**
- Create: `experiment/scripts/poc-test` (executable Python)
- Delete: `experiment/scripts/poc-test.sh` (same commit, after verification)
- Reference: read `experiment/scripts/poc-test.sh` in full before writing any code.

**Interfaces:**
- Consumes: everything from Task 1, including `servers.redirect_server` and `catalog.set_sha256`.

**Suite skeleton** (header comment carried over; tags stay overridable):

```python
#!/usr/bin/env python3
# mise-vault PoC test matrix: plugin behavior against the local Docker stack.
# Runs entirely inside an isolated HOME so the real machine config is untouched.
# (carry over the full Structure/Requires comment block from poc-test.sh)
import os
import shutil
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "tests"))
from lib import catalog, servers
from lib.env import GITLAB_HOST_URL, NEXUS_HOST_URL, IsolatedHome
from lib.harness import Suite, run

TAG_A = os.environ.get("EXPERIMENT_TAG_A", "v0.0.3")
TAG_B = os.environ.get("EXPERIMENT_TAG_B", "v0.0.4")
PLUGIN_URL = f"{GITLAB_HOST_URL}/devtools/mise-vault.git"
s = Suite("poc-test")
home = IsolatedHome("mise-vault-poc.")
```

- [ ] **Step 1: Capture the bash baseline**

```bash
./experiment/scripts/poc-test.sh | tee /tmp/poc-bash.out; echo "exit=$?"
```

Expected: exit 0. If not, STOP and report.

- [ ] **Step 2: Port phases 1-6 1:1**

Work through `poc-test.sh` top to bottom.
Conversion notes:

- Expected versions come from `catalog.versions(...)` / `catalog.latest(...)` with `root=REPO_ROOT` (replaces the `cat_versions` shell helper).
- The initial alias file (including the one alias that keeps an explicit `nexus_url` option) is written with `home.write_aliases({...})` — keep the comment that one alias covers the override channel.
- Phase 2 working-tree link becomes a helper in the suite:

```python
def link_working_tree():
    """Copy the working tree's plugin files (plus the two fixture tools)
    into an isolated plugin dir and link it, so every later check runs
    the exact code under review."""
    plug = home.path / "plugin"
    plug.mkdir()
    shutil.copy(REPO_ROOT / "metadata.lua", plug / "metadata.lua")
    for d in ("hooks", "lib", "config", "catalog"):
        shutil.copytree(REPO_ROOT / d, plug / d)
    # fixtures: darwin-only (unsupported platform) and smoke (deliberately wrong sha256)
    for tool in ("darwin-only", "smoke"):
        shutil.copytree(REPO_ROOT / "tests/fixtures/catalog" / tool, plug / "catalog" / tool)
    run(["mise", "plugins", "uninstall", "vault"], env=home.env)
    return plug, run(["mise", "plugins", "link", "vault", str(plug)], env=home.env)
```

- Phase 3 exact-list comparisons use the whitespace-normalize rule; the "core backend shadowed" check needs `GO_V in out.splitlines()` AND no line starting with `1.24`.
- Phase 4 GOROOT check keeps the exact argv `["mise", "exec", f"go@{go_v}", "--", "sh", "-c", "echo $GOROOT"]` and then `Path(goroot, "src").is_dir()`.
- Phase 5 writes `.tool-versions` with the asdf `golang` name — carry the comment.
- Phase 6 keeps `check_fail` for the unknown-tool and unapproved-version cases, and plain `run` + conditions for the darwin-only ("not available for linux-amd64" in output) and smoke-checksum ("sha-256" or "sha256" in output, case-insensitive) cases.

- [ ] **Step 3: Port phase 7 (redirect refusal) and phase 8**

Phase 7, using the harness pieces (carry the rationale comments from the bash version):

```python
s.phase("Phase 7: redirect refusal + successful single-binary install")
# correct the smoke fixture's sha256 in the LINKED catalog so the only thing
# standing between mise and a successful install is the transport policy
r = run(["curl", "-fsSn", f"{NEXUS_HOST_URL}/repository/devtools/smoke/0.0.1/smoke-0.0.1.txt"],
        env=home.env)
real_sha = __import__("hashlib").sha256(r.out.encode()).hexdigest()
catalog.set_sha256(plug / "catalog/smoke/versions.json", "linux-amd64", real_sha)
redirect_log = home.path / "redirect-requests.log"
redirect_log.write_text("")
try:
    with servers.redirect_server(18082, "http://127.0.0.2:8081", str(redirect_log)):
        s.ok("redirect server is up and answering 302")
        home.write_aliases({**ALIASES,
            "smoke": "vault:smoke[nexus_url=http://127.0.0.1:18082/repository/devtools]"})
        r = run(["mise", "install", "smoke@0.0.1"], env=home.env)
        seen = redirect_log.read_text()
        s.check("redirect from the artifact server aborts the install (request logged, redirect refused)",
                (not r.ok) and "smoke-0.0.1.txt" in seen
                and any(w in (r.out + r.err).lower() for w in ("redirect", "unavailable", "could not be downloaded")),
                detail=f"exit={r.rc}; server saw: {' '.join(seen.split())[:120]}; out: {r.tail()}")
except RuntimeError as e:
    s.bad("redirect server did not come up on 127.0.0.1:18082", e)
home.write_aliases({**ALIASES, "smoke": "vault:smoke"})
s.check_cmd("install smoke@0.0.1 (single-binary format, correct sha256)",
            ["mise", "install", "smoke@0.0.1"], env=home.env)
```

(`ALIASES` is the dict the suite defined at the top for the initial alias file — rewriting the whole file replaces the bash `sed` edits.)
The sha256 of the downloaded text file: careful — hash the exact bytes.
`run()` is text mode and `urllib` cannot use netrc,
so the artifact must be fetched for hashing by running curl with `-o` to a temp file,
then hashing the file bytes with `hashlib.sha256(Path(tmp).read_bytes())`.
Use that form, not the `.encode()` shortcut in the snippet above.

Phase 8 (auto-install guard; carry the comment about bootstrap pre-installing the plugin):

```python
s.phase("Phase 8: an alias to an uninstalled plugin must NOT auto-install it")
home2 = IsolatedHome("mise-vault-poc2.")
home2.write_aliases({"glab": "vault:glab"})
r = run(["mise", "ls-remote", "glab"], env=home2.env)
s.check("alias to uninstalled plugin does not auto-install (bootstrap must pre-install)",
        glab_v not in r.out.splitlines(),
        detail="alias to uninstalled plugin AUTO-INSTALLED — bootstrap's pre-install assumption no longer holds")
home2.remove()
```

End with `sys.exit(s.finish(keep_on_failure=[home]))`.

- [ ] **Step 4: Equivalence check**

```bash
chmod +x experiment/scripts/poc-test
./experiment/scripts/poc-test | tee /tmp/poc-py.out; echo "exit=$?"
diff <(grep '^  PASS' /tmp/poc-bash.out | sort) <(grep '^  PASS' /tmp/poc-py.out | sort)
```

Expected: exit 0, empty diff.

- [ ] **Step 5: Sabotage check**

```bash
EXPERIMENT_TAG_A=v9.9.9 ./experiment/scripts/poc-test; echo "exit=$?"
```

Expected: phase 1 FAILs, exit 1, kept HOME reported.
Remove the kept directory afterwards.

- [ ] **Step 6: Compile-check, delete the bash original, commit**

```bash
python3 -m py_compile experiment/scripts/poc-test
git rm experiment/scripts/poc-test.sh
git add experiment/scripts/poc-test
git commit -m "test: port poc-test to the python harness"
```

---

### Task 5: Port `offline-test` (wrapper + inner suite)

**Files:**
- Create: `experiment/scripts/offline-test` (executable Python wrapper)
- Create: `experiment/scripts/offline-suite` (executable Python, runs inside the container)
- Delete: `experiment/scripts/offline-test.sh` (same commit, after verification)
- Reference: read `experiment/scripts/offline-test.sh` in full — the heredoc inner script is the source of truth for `offline-suite`.

**Interfaces:**
- Consumes: `Suite`, `run`, `catalog`, `env.CONTAINER_MACHINES`, `env.write_netrc`, `env.write_aliases`, `env.GITLAB_CONTAINER_URL`, `env.NEXUS_CONTAINER_URL`.

- [ ] **Step 1: Push HEAD and capture the bash baseline**

```bash
git push experiment HEAD:main
./experiment/scripts/offline-test.sh | tee /tmp/offline-bash.out; echo "exit=$?"
```

Expected: exit 0. If not, STOP and report.

- [ ] **Step 2: Write the wrapper**

`experiment/scripts/offline-test`:

```python
#!/usr/bin/env python3
# Offline gate: the complete developer flow must work inside a network that can
# reach ONLY the private GitLab and Nexus — no route to the public internet.
# Runs offline-suite in a container attached solely to the compose 'isolated'
# network (internal: true), using the mise-vault-test image. The repository is
# mounted read-only so the suite and tests/lib come from the working tree.
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
NETWORK = "mise-vault-experiment_isolated"
IMAGE = "mise-vault-test"

sys.exit(subprocess.call([
    "docker", "run", "--rm", "--network", NETWORK,
    "-v", f"{REPO_ROOT}:/repo:ro",
    IMAGE, "python3", "/repo/experiment/scripts/offline-suite",
]))
```

- [ ] **Step 3: Write the inner suite**

`experiment/scripts/offline-suite` ports the heredoc sections 0-4 1:1. Skeleton and conversion notes:

```python
#!/usr/bin/env python3
# Runs INSIDE the offline container (see offline-test). The container's own
# HOME is used directly — the container is the isolation boundary here.
import os
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]   # /repo in the container
sys.path.insert(0, str(REPO_ROOT / "tests"))
from lib import catalog
from lib.env import (CONTAINER_MACHINES, GITLAB_CONTAINER_URL,
                     NEXUS_CONTAINER_URL, write_aliases, write_netrc)
from lib.harness import Suite, run

HOME = Path(os.environ["HOME"])
ENV = {**os.environ, "GIT_TERMINAL_PROMPT": "0"}
s = Suite("offline-suite")
write_netrc(HOME, CONTAINER_MACHINES)
```

- Section 0 network probes stay curl: `run(["curl", "-m", "5", "-sf", "https://github.com", "-o", "/dev/null"], env=ENV)` must fail; same for proxy.golang.org; GitLab probe plain `-sf`, Nexus probe `-sfn` (netrc). Keep all four descriptions.
- Section 1: clone `{GITLAB_CONTAINER_URL}/devtools/mise-vault.git` to `/tmp/bootstrap`, then run `/tmp/bootstrap/install.sh`; one combined check like the bash `&&` chain, with the install output tail as the failure detail.
- Then overwrite the alias file exactly as the bash comment explains (carry it): `write_aliases(HOME, {t: f"vault:{t}[nexus_url={NEXUS_CONTAINER_URL}/repository/devtools]" for t in ("go", "golangci-lint", "glab")})`.
- Section 2: expected versions via `catalog.versions("golangci-lint", "/tmp/bootstrap")` etc. (root is the bootstrap clone — carry the comment about approving a new version never requiring a suite edit); then the ls-remote equality check and the glab/go install+exec checks, each a combined condition like the bash chain.
- Section 3: the jq fail-closed check with `timeout=30`, effect-based assertion, rationale comment carried.
- Section 4: `MISE_OFFLINE=1` documenting checks: pass `env={**ENV, "MISE_OFFLINE": "1"}`; the two INFO outcomes use `s.note(...)` exactly as the bash version prints them; remove the installed golangci-lint dir first with `shutil.rmtree(HOME / ".local/share/mise/installs/golangci-lint", ignore_errors=True)`.

End with `sys.exit(s.finish())` (no isolated homes to keep — the container is discarded by `--rm`).

- [ ] **Step 4: Equivalence check**

```bash
chmod +x experiment/scripts/offline-test experiment/scripts/offline-suite
./experiment/scripts/offline-test | tee /tmp/offline-py.out; echo "exit=$?"
diff <(grep '^  PASS' /tmp/offline-bash.out | sort) <(grep '^  PASS' /tmp/offline-py.out | sort)
```

Expected: exit 0, empty diff.

- [ ] **Step 5: Exit-propagation check**

```bash
sed -i 's/mise-vault-experiment_isolated/no-such-network/' experiment/scripts/offline-test
./experiment/scripts/offline-test; echo "exit=$?"
git checkout -- experiment/scripts/offline-test 2>/dev/null || sed -i 's/no-such-network/mise-vault-experiment_isolated/' experiment/scripts/offline-test
```

Expected: docker fails and the wrapper exits nonzero (the wrapper must propagate the container exit code).

- [ ] **Step 6: Compile-check, delete the bash original, commit**

```bash
python3 -m py_compile experiment/scripts/offline-test experiment/scripts/offline-suite
git rm experiment/scripts/offline-test.sh
git add experiment/scripts/offline-test experiment/scripts/offline-suite
git commit -m "test: port offline-test to the python harness"
```

---

### Task 6: Update documentation references

**Files:**
- Modify: `README.md` (test-suite command listing)
- Modify: `experiment/README.md` (test-suite command listing)
- Modify: `docs/development.md` (test-suite table and any `.sh` workflow text)
- Modify: `AGENTS.md` (test-suite list in "Development environment")
- Modify: `docs/design.md` (repository layout diagram: `run-validator-tests` line and any suite names)

**Interfaces:** none — documentation only.

- [ ] **Step 1: Update every reference**

Change `poc-test.sh` → `poc-test`, `bootstrap-test.sh` → `bootstrap-test`, `offline-test.sh` → `offline-test` in the files above.
Where `docs/development.md` describes the suites, add one sentence:
the suites are Python on a shared harness in `tests/lib`, verified standalone by `tests/run-harness-selftest`.
Keep the pipefail lesson in `AGENTS.md` unchanged — the provisioning scripts are still bash and the lesson still applies to them.
Remember: these Markdown files use semantic line breaks (one sentence per line).

- [ ] **Step 2: Verify nothing stale remains**

```bash
grep -rn "poc-test.sh\|bootstrap-test.sh\|offline-test.sh" \
  --include="*.md" --include="*.yml" --include="*.yaml" . | grep -v docs/research | grep -v tmp/
```

Expected: no output (research notes and tmp/ are historical records and stay untouched).

- [ ] **Step 3: Commit**

```bash
git add README.md experiment/README.md docs/development.md AGENTS.md docs/design.md
git commit -m "docs: point test documentation at the python suites"
```
