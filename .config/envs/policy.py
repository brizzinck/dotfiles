"""Human-approved argv policies. This reduces accidental leaks; it is not a sandbox."""
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess

DENIED = {"env", "printenv", "set", "export", "declare", "typeset", "eval", "exec", "command", "builtin",
          "sudo", "doas", "su", "login", "unshare", "nsenter", "setsid", "nohup", "timeout", "xargs",
          "sh", "bash", "zsh", "dash", "fish", "ksh", "csh", "tcsh", "busybox", "toybox",
          "envs", "er", "ere", "ert", "mise", "direnv", "script", "tmux", "screen", "systemd-run",
          "docker", "podman", "chroot", "chrt", "nice", "stdbuf", "watch", "parallel"}
APPROVALS = "agent-approvals.json"


def words(prefix, c):
    try:
        result = shlex.split(prefix, posix=True)
    except ValueError:
        c.E.fail("invalid agent command prefix", 4)
    if not result or len(result) > 128 or any(not word or any(ord(x) < 32 or ord(x) == 127 for x in word) for word in result):
        c.E.fail("invalid agent command prefix", 4)
    return result


def rules(context, c):
    raw = context["cfg"].data.get("agents", {}).get("allow", [])
    return [words(prefix, c) for prefix in raw]


def executable(cmd, context, args, c):
    E = c.E
    if not cmd or any(any(ord(ch) < 32 or ord(ch) == 127 for ch in arg) for arg in cmd):
        E.fail("invalid agent command argv", 4)
    name = cmd[0]
    if "/" in name:
        path = Path(os.path.abspath(name))
    elif not getattr(args, "no_mise", False) and not context["cfg"].is_global and E.has_mise_config(context["cfg"].root):
        mise = E.tool("mise", required=False)
        if not mise:
            E.fail("approved executable changed; run envs agent allow again", 4)
        env = E.command_env(os.environ)
        for key in ("MISE_AUTO_INSTALL", "MISE_NOT_FOUND_AUTO_INSTALL", "MISE_EXEC_AUTO_INSTALL", "MISE_TASK_RUN_AUTO_INSTALL"):
            env[key] = "0"
        env["MISE_ENV"] = context["env"]
        try:
            result = subprocess.run([mise, "which", name], cwd=context["cfg"].root, env=env,
                                    stdin=subprocess.DEVNULL, capture_output=True, timeout=10, text=True)
            output = result.stdout.strip()
            if result.returncode or not output or "\n" in output or not Path(output).is_absolute():
                E.fail("approved executable changed; run envs agent allow again", 4)
            path = Path(output)
        except (OSError, subprocess.SubprocessError):
            E.fail("approved executable changed; run envs agent allow again", 4)
    else:
        found = shutil.which(name, path=os.environ.get("PATH", "/usr/bin:/bin"))
        if not found:
            E.fail("approved executable changed; run envs agent allow again", 4)
        path = Path(found)
    try:
        resolved = path.resolve(strict=True)
        if not resolved.is_file() or not os.access(resolved, os.X_OK):
            raise OSError()
    except OSError:
        E.fail("approved executable changed; run envs agent allow again", 4)
    reject(cmd, str(resolved), c)
    return str(resolved)


def reject(cmd, resolved, c):
    for name in (Path(cmd[0]).name.lower(), Path(resolved).name.lower()):
        if name in DENIED or re.fullmatch(r"(?:claude|codex|gemini)(?:[-.].*)?", name):
            c.E.fail("command is forbidden for agent secret use: " + name, 4)
        interpreter = name.startswith(("python", "pypy", "node", "perl", "ruby"))
        if interpreter:
            args = cmd[1:]
            # Only an explicit script filename is supported; option semantics differ between interpreters.
            if not args or args[0].startswith("-"):
                c.E.fail("command is forbidden for agent secret use: " + name, 4)
        if name in {"npx", "npm", "pnpm", "yarn", "uv", "pipx", "rye", "hatch", "poetry"}:
            c.E.fail("command is forbidden for agent secret use: " + name, 4)


def identity_refs(context, c):
    """Pin legacy fallback provenance with metadata; never fetch values while approving."""
    E, cfg, env, specs = c.E, context["cfg"], context["env"], context["specs"]
    refs = dict(specs["refs"])
    if specs["legacy"]:
        if E.managed_user():
            items = E.share({"v": 1, "op": "list"})["items"]
        else:
            import json
            c.owner_unlocked()
            rc, raw = c.safe_owner_rbw("list", "--raw")
            try:
                items = json.loads(raw) if rc == 0 else []
            except ValueError:
                E.fail("reference metadata unavailable", 1)
        available = {}
        for folder in E.env_folders(cfg.project):
            hits = E.rbw_env_items(items, cfg.project, env, folder)
            if len(hits) > 1:
                E.fail("legacy reference is ambiguous", 4)
            if not hits:
                continue
            fields = None
            if E.managed_user():
                item = E.share({"v": 1, "op": "describe", "id": hits[0]["id"]})["item"]
                fields = {f["name"][6:] for f in item.get("fields", []) if f["name"].startswith("field:") and f.get("set")}
            for name in specs["legacy"]:
                if name not in available and (fields is None or name in fields):
                    available[name] = c.D.parse_bw_ref(c.D.format_bw_ref(folder, env, name))
        if set(specs["legacy"]) - set(available):
            E.fail("required legacy reference is unavailable", 4)
        refs.update(available)
    identities = {name: c.ref_metadata(name, ref) for name, ref in refs.items()}
    return refs, identities


def digest(context, allowed, c):
    return c.D.digest({"mapping": c.mapping_digest(context["cfg"], context["env"], context["specs"]),
                       "sources": [(name, list(snap.ident)) for name, snap, _ in context["specs"]["docs"]],
                       "rules": allowed, "ref_policy": context["policy"]})


def human(c):
    c.E.refuse_agent("agent policy")
    if not c.E.tty() and not (c.E.test_mode() and os.environ.get("ENVS_TEST_YES") == "1"):
        c.E.fail("agent policy changes require a human terminal", 4)


def command(args, cmd, c):
    human(c)
    cfg = c.E.load_global(augment=False) if getattr(args, "global_", False) else c.E.load_cfg(augment=False)
    env = getattr(args, "env", None) or c.E.choose_env(cfg)
    c.E.need_env(cfg, env)
    key = c.policy_key(cfg, env)
    approved = c.read_state(APPROVALS)
    if args.action == "list":
        for row in approved.get(key, {}).get("entries", []):
            c.E.say("--any (every command except the forbidden families)" if row.get("any") else shlex.join(row["prefix"]))
        return
    wildcard = getattr(args, "any", False)
    if wildcard == bool(cmd):
        c.E.fail("agent allow/deny needs -- COMMAND or --any", 2)
    prefix = None if wildcard else words(shlex.join(cmd), c)
    if args.action == "deny":
        with c.metadata_lock():
            approved = c.read_state(APPROVALS)
            row = approved.get(key, {})
            row["entries"] = [entry for entry in row.get("entries", [])
                              if not (entry.get("any") if wildcard else entry.get("prefix") == prefix)]
            approved[key] = row; c.write_state(APPROVALS, approved)
        c.E.say("agent approval revoked" if wildcard else "agent prefix revoked")
        return
    context = c.prepare_export(args, agent=True)
    allowed = rules(context, c)
    if wildcard:
        return allow_any(context, allowed, key, c)
    add_rule = not any(prefix[:len(rule)] == rule for rule in allowed)
    resolved = executable(prefix, context, args, c)
    # Vault metadata before the confirmation and any policy edit: a locked vault leaves no half-written rule behind.
    refs, identities = identity_refs(context, c)
    c.E.say("Authorize " + shlex.join(prefix))
    c.E.say("scope: " + context["cfg"].project + "/" + context["env"] + "; names: " + ", ".join(context["specs"]["names"]))
    c.E.say("binding: " + str(context["cfg"].root))
    if add_rule:
        c.E.say("This also records the exact prefix in " + ("global.local.toml" if cfg.is_global else ".envs.toml") + " [agents] allow")
    if not c.E.confirm("Approve this exact argv prefix and effective mapping?"):
        c.E.fail("agent policy not approved", 4)
    if add_rule:
        import json
        path = cfg.root / (c.E.GLOBAL_LOCAL if cfg.is_global else c.E.TOML)
        snapshot = c.D.read_document(path, cfg.root) if path.exists() or path.is_symlink() else None
        editor = c.E.TomlText(snapshot.text if snapshot else "")
        if not cfg.is_global and snapshot is None:
            editor.set(None, "project", c.E.toml_str(cfg.project))
            editor.set(None, "environments", json.dumps(cfg.envs))
            editor.set(None, "default", c.E.toml_str(cfg.default))
        declared = [shlex.join(rule) for rule in allowed] + [shlex.join(prefix)]
        editor.set("agents", "allow", json.dumps(declared))
        c.module("imports").publish(path, snapshot, editor.text(), c, c.private_dir(c.state_path("recovery")))
        context = c.prepare_export(args, agent=True)
        allowed = rules(context, c)
        refs, identities = identity_refs(context, c)
    record(context, allowed, refs, identities, key, {"prefix": prefix, "executable": resolved}, c)
    c.E.say("agent prefix approved; no values fetched")


def allow_any(context, allowed, key, c):
    """One private approval for every command of this project/environment. Nothing is written to a project file; the
    forbidden families, protected targets, digest checks, masking and audit still apply on every run."""
    refs, identities = identity_refs(context, c)
    c.E.say("Authorize any command (shells, environment printers, wrappers, escalation and interpreter -c/stdin stay refused)")
    c.E.say("scope: " + context["cfg"].project + "/" + context["env"] + "; names: " + ", ".join(context["specs"]["names"]))
    c.E.say("binding: " + str(context["cfg"].root))
    c.E.say("Recorded only in private local state; no project file changes")
    if not c.E.confirm("Approve any command with this effective mapping?"):
        c.E.fail("agent policy not approved", 4)
    record(context, allowed, refs, identities, key, {"any": True}, c)
    c.E.say("agent approved for any command; no values fetched")


def record(context, allowed, refs, identities, key, entry, c):
    for _, snap, _ in context["specs"]["docs"]:
        snap.verify()
    with c.metadata_lock():
        approved = c.read_state(APPROVALS)
        previous = approved.get(key, {})
        current_digest = digest(context, allowed, c)
        entries = previous.get("entries", []) if previous.get("digest") == current_digest else []
        same = (lambda row: row.get("any")) if entry.get("any") else (lambda row: row.get("prefix") == entry["prefix"])
        entries = [row for row in entries if not same(row)] + [entry]
        approved[key] = {"digest": current_digest, "entries": entries, "names": context["specs"]["names"],
                         "refs": {name: ref.canonical for name, ref in refs.items()}, "identities": identities,
                         "root": str(context["cfg"].root), "env": context["env"], "global": context["cfg"].is_global,
                         "source_identities": {relative: list(snap.ident) for relative, snap, _ in context["specs"]["docs"]}}
        c.write_state(APPROVALS, approved)


def audit(context, cmd, names, decision, c):
    import json
    fields = {"event": "agent-run", "project": context["cfg"].project if context else "unknown",
              "env": context["env"] if context else "unknown", "cmd": Path(cmd[0]).name[:128] if cmd else "unknown",
              "names": sorted(names), "decision": decision, "result": "authorized" if decision == "allow" else "refused"}
    logger = c.E.tool("logger", required=False)
    if not logger:
        c.E.fail("required agent audit is unavailable; command not started", 4)
    try:
        result = subprocess.run([logger, "-t", "envs", "--"], input=json.dumps(fields, ensure_ascii=True) + "\n",
                                text=True, capture_output=True, timeout=3)
    except (OSError, subprocess.SubprocessError):
        c.E.fail("required agent audit failed; command not started", 4)
    if result.returncode:
        c.E.fail("required agent audit failed; command not started", 4)


def run(args, cmd, c):
    context, audited = None, False
    try:
        if getattr(args, "allow_missing", False) or getattr(args, "sync", False):
            c.E.fail("agent run refuses --allow-missing and --sync", 4)
        context = c.prepare_export(args, agent=True, require_source=getattr(args, "env_file", False))
        allowed = rules(context, c)
        row = c.read_state(APPROVALS).get(c.policy_key(context["cfg"], context["env"]), {})
        if not row.get("entries"):
            c.E.fail("agent command is not approved; ask the owner to run envs agent allow -- COMMAND", 4)
        if row.get("digest") != digest(context, allowed, c):
            c.E.fail("agent policy changed; human approval is required", 4)
        entry = next((entry for entry in row["entries"] if entry.get("prefix") and cmd[:len(entry["prefix"])] == entry["prefix"]), None)
        if entry is not None and not any(cmd[:len(rule)] == rule for rule in allowed):
            entry = None
        # An exact prefix keeps its pinned executable; --any pins none, and executable() still refuses the forbidden families.
        entry = entry or next((entry for entry in row["entries"] if entry.get("any")), None)
        if entry is None:
            c.E.fail("agent command is not approved; ask the owner to run envs agent allow -- COMMAND (or --any)", 4)
        resolved = executable(cmd, context, args, c)
        if not entry.get("any") and resolved != entry["executable"]:
            c.E.fail("approved executable changed; run envs agent allow again", 4)
        refs, identities = identity_refs(context, c)
        if {name: ref.canonical for name, ref in refs.items()} != row.get("refs") or identities != row.get("identities"):
            c.E.fail("agent policy changed; human approval is required", 4)
        selected = {name: refs[name] for name in context["wanted"]}
        specs = dict(context["specs"], refs=selected, legacy=[])
        values = c.resolve_refs(context["cfg"], context["env"], specs, context["wanted"], {"identities": identities})
        runtime = c.module("runtime")
        runtime.secret_patterns(values)  # Pattern/setup bounds are enforced before audit and child launch.
        argv, env = c.command_argv(context, [resolved, *cmd[1:]], args, values)
        text = None
        if getattr(args, "env_file", False):
            if not any("{envfile}" in word for word in cmd):
                c.E.fail("--env-file requires an argv {envfile} placeholder", 2)
            text = runtime.render_document(context["source"][2], values, context["specs"]["names"], omit_unselected=True)
        elif any("{envfile}" in word for word in cmd):
            c.E.fail("{envfile} requires --env-file", 2)
        audited = True
        c.E.namespace["_RUN_AUDITED"] = True
        audit(context, cmd, context["wanted"], "allow", c)
        if text is not None:
            with c.private_envfile(text) as path:
                argv = [word.replace("{envfile}", str(path)) for word in argv]
                return runtime.supervise_run(argv, env, values, agent=True, on_error=c.E.warn)
        return runtime.supervise_run(argv, env, values, agent=True, on_error=c.E.warn)
    except c.module("runtime").RuntimeProblem:
        c.E.fail("secret masking or strict dotenv setup is unsupported; command not started", 4)
    finally:
        if not audited:
            c.E.namespace["_RUN_AUDITED"] = True
            audit(context, cmd, context["wanted"] if context else [], "deny", c)
