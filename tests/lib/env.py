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
