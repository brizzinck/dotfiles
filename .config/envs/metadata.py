"""Offline doctor checks. Source payloads and vaults are never opened."""
import importlib.util
import json
import os
from pathlib import Path
import pwd
import re
import stat
import sys
import tomllib
import types

spec = importlib.util.spec_from_file_location("_envs_metadata_core", Path(__file__).with_name("secrets.py"))
D = importlib.util.module_from_spec(spec); sys.modules[spec.name] = D; spec.loader.exec_module(D)


def inspect(home, repo):
    home, repo = Path(home), Path(repo)
    results = []
    def result(kind, check, message):
        results.append((kind, check, message))
    def regular(path, private=True):
        with D.parent_fd(path) as (fd, name):
            value = os.stat(name, dir_fd=fd, follow_symlinks=False)
        if (not stat.S_ISREG(value.st_mode) or value.st_uid != os.getuid() or value.st_nlink != 1
                or value.st_mode & (0o077 if private else 0o022)):
            raise D.Problem("unsafe metadata file")
        return value
    config = home / ".config/envs"
    state = home / ".local/state/envs"
    for name in ("global.env", "wrap.tsv", "global.local.toml"):
        path = config / name
        if not path.exists() and not path.is_symlink():
            result("INFO", "envs-" + name, "local metadata is not configured"); continue
        try:
            regular(path, private=name != "global.local.toml")
            if name == "wrap.tsv":
                text = D.read_document(path, private=True).text
                seen = set()
                for line in text.splitlines():
                    if not line or line.startswith("#"):
                        continue
                    fields = line.split("\t")
                    if len(fields) != 3:
                        raise D.Problem("invalid wrapper metadata")
                    command, binary, selected = fields
                    if (not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]*", command) or command in seen
                            or command in {"envs", "er", "ere", "ert", "eval", "exec", "command", "builtin", "source"}
                            or not Path(binary).is_absolute() or any(ord(ch) < 32 or ord(ch) == 127 for ch in binary)
                            or not Path(binary).is_file() or not os.access(binary, os.X_OK)
                            or Path(binary).resolve() == (repo / ".local/bin/envs").resolve()
                            or not selected or any(not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", word) for word in selected.split(","))):
                        raise D.Problem("invalid wrapper metadata")
                    seen.add(command)
            elif name == "global.local.toml":
                data = tomllib.loads(D.read_document(path).text)
                if set(data) - {"secrets", "db", "agents"}:
                    raise D.Problem("invalid global metadata schema")
                agents = data.get("agents", {})
                if not isinstance(agents, dict) or set(agents) - {"allow"} or not isinstance(agents.get("allow", []), list):
                    raise D.Problem("invalid agent metadata schema")
            result("OK", "envs-" + name, "local metadata passes ownership/type/schema checks; no source values read")
        except (OSError, D.Problem, ValueError, TypeError):
            result("FAIL", "envs-" + name, "unsafe or malformed local metadata; inspect it in the owner's terminal")
    if state.exists() or state.is_symlink():
        try:
            with D.parent_fd(state / "placeholder") as (fd, _):
                value = os.fstat(fd)
                if value.st_uid != os.getuid() or value.st_mode & 0o077:
                    raise D.Problem("unsafe authorization directory")
            for filename in ("ref-policies.json", "agent-approvals.json"):
                path = state / filename
                if not path.exists() and not path.is_symlink():
                    result("INFO", "envs-" + filename, "no approvals recorded"); continue
                regular(path)
                data = json.loads(D.read_document(path, private=True).text)
                if not isinstance(data, dict):
                    raise D.Problem("invalid authorization schema")
                stale, old = False, False
                for row in data.values():
                    if not isinstance(row, dict):
                        raise D.Problem("invalid authorization schema")
                    root, identities = row.get("root"), row.get("source_identities")
                    if root is None or identities is None:
                        old = True; continue
                    if not isinstance(root, str) or not Path(root).is_absolute() or not isinstance(identities, dict):
                        raise D.Problem("invalid authorization schema")
                    for relative, identity in identities.items():
                        if (not isinstance(relative, str) or Path(relative).is_absolute() or any(part in (".", "..") for part in relative.split("/"))
                                or not isinstance(identity, list) or len(identity) != 5 or not all(isinstance(number, int) for number in identity)):
                            raise D.Problem("invalid authorization source metadata")
                        try:
                            # verify() uses fstat metadata only, without opening the source payload.
                            D.Snapshot(Path(root) / relative, "", tuple(identity)).verify()
                        except D.Problem:
                            stale = True
                if stale:
                    result("FAIL", "envs-" + filename, "source metadata changed; human bind/agent approval is required")
                elif old:
                    result("INFO", "envs-" + filename, "older approval metadata; refresh through human bind/agent allow")
                else:
                    result("OK", "envs-" + filename, "source identities match; full policy and executable checks still run before each command")
        except (OSError, D.Problem, ValueError, TypeError):
            result("FAIL", "envs-authorizations", "unsafe or malformed local authorization metadata")
    else:
        result("INFO", "envs-authorizations", "no local authorizations configured")
    return results


def main():
    rows = inspect(pwd.getpwuid(os.getuid()).pw_dir, Path(__file__).resolve().parents[2])
    for row in rows:
        print("\t".join(row))
    return int(any(row[0] == "FAIL" for row in rows))


if __name__ == "__main__":
    sys.exit(main())
