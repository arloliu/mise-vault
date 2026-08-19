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
