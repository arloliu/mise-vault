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
    """Run a command, capturing text output.
    Errors (missing binary, timeout) come back as a failed Result instead of
    an exception, so a suite can keep going and report them as ordinary check
    failures."""
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
        """Print the summary; on success remove the listed homes, on failure
        keep them for inspection.
        Returns the process exit code."""
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
