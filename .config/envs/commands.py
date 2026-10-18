"""SECRETS command integration for envs. Public API is dispatch(name, host, ...).

Host functions keep the existing binding, protected-environment and managed broker
boundaries. Documents and local state never become shell code.
"""
import contextlib
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import sys
import time
import types
import unicodedata

HERE = Path(__file__).resolve().parent


def module(name):
    key = "_envs_" + name
    if key not in sys.modules:
        spec = importlib.util.spec_from_file_location(key, HERE / (name + ".py"))
        mod = importlib.util.module_from_spec(spec)
        sys.modules[key] = mod
        spec.loader.exec_module(mod)
    return sys.modules[key]


D = module("secrets")


class Host:
    def __init__(self, namespace):
        self.namespace = namespace

    def __getattr__(self, name):
        return self.namespace[name]


E = None


def dispatch(name, namespace, *args, **kwargs):
    global E
    E = Host(namespace)
    try:
        return globals()[name](*args, **kwargs)
    except OSError:
        E.fail("private metadata or source operation failed; values hidden", 1)
    except D.Problem as p:
        prefix = f"line {p.line}: " if p.line else ""
        E.fail(prefix + p.reason + "; values hidden", 4)


def private_dir(path):
    path = Path(path)
    # Parents are walked without symlinks; caller supplies a fixed account/test-state destination.
    if not path.exists():
        if not path.parent.exists():
            private_dir(path.parent)
        with D.parent_fd(path) as (fd, name):
            try:
                os.mkdir(name, 0o700, dir_fd=fd)
            except FileExistsError:
                pass
    with D.parent_fd(path) as (fd, name):
        st = os.stat(name, dir_fd=fd, follow_symlinks=False)
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o077:
        raise D.Problem("unsafe private metadata directory")
    return path


def state_path(name):
    base = Path(os.environ.get("XDG_STATE_HOME") or E.HOME / ".local/state") / "envs"
    return private_dir(base) / name


@contextlib.contextmanager
def metadata_lock():
    with D.parent_fd(state_path("metadata.lock")) as (fd, name):
        lock = os.open(name, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600, dir_fd=fd)
    try:
        st = os.fstat(lock)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_nlink != 1 or st.st_mode & 0o077:
            raise D.Problem("unsafe local authorization lock")
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield
    finally:
        os.close(lock)


def read_state(name):
    path = state_path(name)
    if not path.exists() and not path.is_symlink():
        return {}
    snap = D.read_document(path, private=True)
    try:
        data = json.loads(snap.text)
    except ValueError:
        raise D.Problem("invalid local authorization state") from None
    if not isinstance(data, dict):
        raise D.Problem("invalid local authorization state")
    return data


def write_state(name, data):
    path = state_path(name)
    text = json.dumps(data, sort_keys=True, indent=1) + "\n"
    if path.exists() or path.is_symlink():
        D.read_document(path, private=True).replace(text, recovery_dir=private_dir(state_path("recovery")))
        return
    module("imports").publish(path, None, text, sys.modules[__name__], None)


def policy_key(cfg, env):
    return D.digest([E.binding_key(cfg.root), cfg.project, env, cfg.is_global])


def source_selection(cfg, env):
    if cfg.is_global:
        return ["global.env"] if (cfg.root / "global.env").exists() else []
    entry = read_state("ref-sources.json").get(policy_key(cfg, env), {})
    selected = entry.get("sources", [".env"])
    if not isinstance(selected, list) or not all(isinstance(x, str) for x in selected):
        raise D.Problem("invalid reference source selection")
    return selected


def forbidden_source(path, root=None):
    candidate = Path(os.path.abspath(path))
    rules = E.REPO / "infrastructure/users/secret-paths.txt"
    for line in rules.read_text().splitlines():
        raw = line.split(" #", 1)[0].strip()
        if not raw or raw.startswith("#"):
            continue
        raw = re.sub(r"\s+(?:top|full)$", "", raw)
        if raw.startswith("@REPO@/"):
            denied = E.REPO / raw[7:]
        else:
            denied = Path(raw) if raw.startswith("/") else E.HOME / raw
        candidates = [denied]
        if root is not None and not raw.startswith(("/", "@REPO@/")):
            candidates.append(Path(root) / raw)
        if any(candidate == entry or entry in candidate.parents for entry in candidates):
            return True
    return False


def source_path(cfg, relative):
    if not relative or Path(relative).is_absolute() or any(p in (".", "..") for p in relative.split("/")):
        raise D.Problem("invalid approved source path")
    if any(ord(c) < 32 or 0x7f <= ord(c) <= 0x9f or unicodedata.category(c) in ("Cf", "Cs", "Zl", "Zp") for c in relative):
        raise D.Problem("invalid approved source path")
    if any(p in (".git", ".ssh", ".gnupg", ".claude", ".codex", ".gemini") for p in Path(relative).parts):
        raise D.Problem("source is a credential location")
    path = cfg.root / relative
    if not cfg.is_global and forbidden_source(path, cfg.root):
        raise D.Problem("source is a credential location")
    return path


def documents(cfg, env, selected=None):
    result = []
    for relative in source_selection(cfg, env) if selected is None else selected:
        basename = Path(relative).name.casefold()
        for protected in cfg.protected:
            if (basename == ".env." + protected.casefold() or basename.startswith(".env." + protected.casefold() + ".")) and env.casefold() != protected.casefold():
                E.fail("protected source does not match selected environment", 4)
        path = source_path(cfg, relative)
        if relative == ".env" and not path.exists() and not path.is_symlink() and selected is None:
            continue
        snap = D.read_document(path, cfg.root, private=cfg.is_global)
        if getattr(cfg, "legacy_secrets", cfg.secrets) and not cfg.is_global and "bw://" not in snap.text:
            continue       # declaration-only projects keep their existing dotenv behavior until import
        doc = D.DotenvDocument(snap.text)
        # Legacy-only consumers keep their old dotenv compatibility until migration. Inline documents are strict.
        result.append((relative, snap, doc))
    return result


def synthetic_cfg(root, strict=True, augment=True):
    root = Path(root)
    row = E.bindings().get(E.binding_key(root))
    if row is None:
        prior = [r for key, r in E.bindings().items() if not Path(E.key_root(key)).exists() and E.stored_identity(r) != "-" and E.same_lineage(root, E.stored_identity(r))]
        if len({r[1] for r in prior}) == 1:
            row = prior[0]
    project = row[1] if row else re.sub(r"[^a-z0-9._-]", "-", root.name.lower()).strip("-._")[:63]
    if not project or not E.PROJECT_RE.fullmatch(project):
        project = "project-" + D.digest(str(root))[:12]
    cfg = E.Cfg(root, {"project": project, "environments": ["dev"], "default": "dev", "secrets": {}}, "", [])
    cfg.synthetic = True
    return augment_cfg(cfg) if augment else cfg


def augment_cfg(cfg):
    if cfg.problems:
        return cfg
    cfg.secrets = dict(getattr(cfg, "legacy_secrets", cfg.secrets))
    # Tool clients need declared names before selecting an environment. Target
    # equivalence belongs to effective() after the actual -e selection is known.
    for _, _, doc in documents(cfg, E.choose_env(cfg)):
        for name in doc.references():
            if E.bad_var_name(name):
                E.fail(f"{name}: reserved or invalid reference variable", 4)
            cfg.secrets[name] = "inline reference"
    return cfg


def effective(cfg, env, selected=None):
    """One effective name->reference mapping; legacy reads retain their own explicit provenance."""
    docs, refs, plain, assignments = documents(cfg, env, selected), {}, {}, {}
    for relative, snap, doc in docs:
        local = doc.references()
        for record in doc.records:
            assignments.setdefault(record.name, []).append(relative)
            if record.name not in local:
                plain[record.name] = record.value
        for name, ref in local.items():
            if E.bad_var_name(name):
                E.fail(f"{name}: reserved or invalid reference variable", 4)
            if name in refs:
                E.fail(f"{name}: duplicate reference across selected sources", 4)
            refs[name] = ref
    for name in refs:
        if len(assignments[name]) != 1:
            E.fail(f"{name}: duplicate secret assignment across selected sources", 4)
    legacy = dict(getattr(cfg, "legacy_secrets", cfg.secrets))
    for name in legacy:
        if name in refs:
            ref = refs[name]
            if E.managed_user() or (ref.folder, ref.item, ref.kind, ref.field) != (E.env_folder(cfg.project), env, "field", name):
                E.fail(f"{name}: conflicting legacy and inline mapping", 4)
        elif name in plain:
            E.fail(f"{name}: literal value conflicts with legacy declaration; run envs import", 4)
    names = list(dict.fromkeys([*refs, *legacy]))
    return {"refs": refs, "legacy": [n for n in legacy if n not in refs], "names": names, "docs": docs,
            "sources": [r for r, _, _ in docs]}


def mapping_digest(cfg, env, specs):
    return D.digest({"binding": E.binding_key(cfg.root), "lineage": E.repo_identity(cfg.root), "root": str(cfg.root),
                     "project": cfg.project, "env": env, "sources": [(name, list(snap.ident)) for name, snap, _ in specs["docs"]],
                     "refs": {n: r.canonical for n, r in specs["refs"].items()}, "legacy": specs["legacy"],
                     "legacy_folders": E.env_folders(cfg.project), "protected": sorted(cfg.protected)})


def known_ref_protected(cfg, ref):
    known = re.fullmatch(r"(?:Env|Users/[^/]+/Env|Shared/Env)/[^/]+", ref.folder)
    return bool(known and ref.item.casefold() in {p.casefold() for p in cfg.protected})


def safe_owner_rbw(*args):
    # Reuse the reviewed broker's child boundary; it cannot start an agent or prompt, including lock races.
    import asyncio
    broker = E.share_lib().Broker.__new__(E.share_lib().Broker)
    if E.TEST_DIRS:
        # The broker has its own separately verified hooks. Owner envs fake tests may not be broker processes.
        env = dict(os.environ, RBW_AGENT="/usr/bin/false", PINENTRY_USER_DATA="vault-share:no-prompt")
        try:
            p = subprocess.run([E.tool("rbw", "RBW_BIN"), *args], env=env, capture_output=True, text=True,
                               stdin=subprocess.DEVNULL, timeout=15)
            return p.returncode, p.stdout
        except (OSError, subprocess.SubprocessError):
            E.fail("reference backend unavailable", 1)
    try:
        async def read():
            await broker.prompt_guard()
            return await broker.rbw(*args)
        rc, raw = asyncio.run(read())
        return rc, raw.decode("utf-8", "strict")
    except (E.share_lib().Err, UnicodeError):
        E.fail("reference backend unavailable", 1)


def owner_unlocked():
    rc, _ = safe_owner_rbw("unlocked")
    if rc:
        E.fail("vault is locked; command not started", 3)


def ref_metadata(name, ref):
    if E.managed_user():
        if not ref.folder:
            E.fail(f"{name}: referenced item or field unavailable", 4)
        try:
            item = E.share({"v": 1, "op": "describe", "folder": ref.folder, "name": ref.item})["item"]
        except E.Fail as error:
            if error.code == 3:
                E.fail("vault is locked; command not started", 3)
            if "ambiguous" in error.msg or "items called" in error.msg:
                E.fail(f"{name}: reference is ambiguous", 4)
            E.fail(f"{name}: referenced item or field unavailable", 4)
        available = [f for f in item.get("fields", []) if f.get("name") == ref.selector]
        if len(available) != 1 or not available[0].get("set"):
            E.fail(f"{name}: referenced item or field unavailable", 4)
        return {"id": item["id"], "type": item.get("type"), "selector": ref.selector}
    owner_unlocked()
    rc, raw = safe_owner_rbw("list", "--raw")
    try:
        items = json.loads(raw) if rc == 0 else []
        hits = [i for i in items if unicodedata.normalize("NFC", i.get("folder") or "") == ref.folder
                and unicodedata.normalize("NFC", i.get("name") or "") == ref.item]
    except (ValueError, TypeError, AttributeError):
        E.fail("reference metadata unavailable", 1)
    if len(hits) > 1:
        E.fail(f"{name}: reference is ambiguous", 4)
    if len(hits) != 1 or not hits[0].get("id"):
        E.fail(f"{name}: referenced item or field unavailable", 4)
    typ = str(hits[0].get("type", "")).lower().replace(" ", "")
    if ref.kind == "builtin" and ref.field in ("username", "password", "uris") and typ not in ("login", "1"):
        E.fail(f"{name}: referenced item or field unavailable", 4)
    # rbw list exposes no custom-field metadata. Only selected-item get can verify its field after human target consent.
    return {"id": hits[0]["id"], "type": typ, "selector": ref.selector}


def authorize_refs(cfg, args):
    E.refuse_agent("bind")
    env = getattr(args, "env", None) or cfg.default
    E.need_env(cfg, env)
    selected = getattr(args, "ref_file", None)
    specs = effective(cfg, env, selected)
    unknown_protected = set(getattr(args, "protect_ref", None) or []) - set(specs["refs"])
    if unknown_protected:
        E.fail("protected reference name is not declared", 4)
    if not specs["refs"]:
        return
    E.say(f"reference sources: {', '.join(specs['sources'])}")
    for name, ref in specs["refs"].items():
        E.say(f"  {name} -> {ref.canonical}")
    if not E.confirm("Authorize this exact reference target set for this project/environment?"):
        E.fail("reference targets not authorized", 4)
    identities = {name: ref_metadata(name, ref) for name, ref in specs["refs"].items()}
    for _, snap, _ in specs["docs"]:
        snap.verify()
    with metadata_lock():
        if selected:
            choices = read_state("ref-sources.json")
            choices[policy_key(cfg, env)] = {"sources": selected}
            write_state("ref-sources.json", choices)
        policies = read_state("ref-policies.json")
        previous_protected = policies.get(policy_key(cfg, env), {}).get("protected", [])
        policies[policy_key(cfg, env)] = {"digest": mapping_digest(cfg, env, specs), "identities": identities,
                                         "protected": sorted(set(previous_protected) | set(getattr(args, "protect_ref", None) or [])),
                                         "sources": specs["sources"], "root": str(cfg.root), "global": cfg.is_global,
                                         "source_identities": {relative: list(snap.ident) for relative, snap, _ in specs["docs"]}}
        write_state("ref-policies.json", policies)
    E.say("reference targets authorized; no values fetched")


def check_ref_policy(cfg, env, specs, agent=False, prod=False):
    if not specs["refs"]:
        return {}
    record = read_state("ref-policies.json").get(policy_key(cfg, env), {})
    if record.get("digest") != mapping_digest(cfg, env, specs):
        E.fail("reference policy changed; the owner must run envs bind again", 4)
    for name, ref in specs["refs"].items():
        protected = known_ref_protected(cfg, ref) or name in record.get("protected", [])
        if protected:
            if agent:
                E.fail(f"agents cannot use protected reference {name}", 4)
            if not prod and not E.typed_confirm(ref.item, f"{name}: protected reference target"):
                E.fail(f"{name}: protected reference requires --prod or typed authorization", 4)
    return record


def resolve_refs(cfg, env, specs, wanted, record):
    refs = {n: specs["refs"][n] for n in wanted if n in specs["refs"]}
    groups, values = {}, {}
    for name, ref in refs.items():
        current = ref_metadata(name, ref)
        if current != record.get("identities", {}).get(name):
            E.fail(f"{name}: referenced identity changed; human approval is required", 4)
        groups.setdefault((current["id"], ref.folder, ref.item), []).append((name, ref))
    for (ident, folder, item_name), entries in groups.items():
        fields = list(dict.fromkeys(ref.selector for _, ref in entries))
        if E.managed_user():
            try:
                result = E.share({"v": 1, "op": "get", "id": ident, "fields": fields})
            except E.Fail as error:
                E.fail("vault is locked; command not started" if error.code == 3 else f"{entries[0][0]}: referenced item or field unavailable",
                       3 if error.code == 3 else 4)
            got = result.get("values", {})
        else:
            rc, raw = safe_owner_rbw("get", "--raw", ident)
            if rc:
                owner_unlocked()
                E.fail(f"{entries[0][0]}: referenced item or field unavailable", 4)
            try:
                item = json.loads(raw)
                if item.get("id") != ident or unicodedata.normalize("NFC", item.get("folder") or "") != folder or unicodedata.normalize("NFC", item.get("name") or "") != item_name:
                    E.fail(f"{entries[0][0]}: referenced identity changed; human approval is required", 4)
                got = {}
                for field in fields:
                    if field.startswith("field:"):
                        matches = [f for f in item.get("fields", []) if f.get("name") == field[6:]]
                        if len(matches) != 1:
                            E.fail(f"{entries[0][0]}: referenced item or field unavailable", 4)
                        got[field] = matches[0].get("value")
                    elif field == "notes":
                        got[field] = item.get("notes")
                    elif field == "uris":
                        got[field] = "\n".join(u["uri"] if isinstance(u, dict) else u for u in item.get("data", {}).get("uris", []))
                    else:
                        got[field] = (item.get("data") or {}).get(field)
            except (ValueError, TypeError, AttributeError, KeyError):
                E.fail(f"{entries[0][0]}: referenced item or field unavailable", 4)
        for name, ref in entries:
            value = got.get(ref.selector)
            if not isinstance(value, str) or not value:
                E.fail(f"{name}: referenced item or field unavailable", 4)
            if len(value) < 6:
                E.fail(f"{name} is too short for safe output masking", 4)
            if "\x00" in value:
                E.fail(f"{name}: referenced value is unsupported", 4)
            values[name] = value
    for _, snap, _ in specs["docs"]:
        snap.verify()
    return values


def cmd_refs(args):
    try:
        cfg = E.cfg_for(args)
    except E.Fail:
        if args.action != "set" or getattr(args, "global_", False):
            raise
        _, top = E.git_common_dir(Path.cwd())
        cfg = synthetic_cfg(top or Path.cwd())
    env = args.env or cfg.default
    if args.action == "set":
        if E.bad_var_name(args.name):
            E.fail("invalid or reserved reference variable", 4)
        ref = D.parse_bw_ref(args.uri)
        default_file = "global.env" if cfg.is_global else ".env"
        path = source_path(cfg, args.file or default_file)
        if path.exists() or path.is_symlink():
            snap = D.read_document(path, cfg.root)
            doc = D.DotenvDocument(snap.text)
            rows = [r for r in doc.records if r.name == args.name]
            if len(rows) > 1:
                E.fail(f"{args.name}: duplicate assignments require owner import", 4)
            if rows and not rows[0].value.startswith("bw://"):
                E.fail(f"{args.name} has a literal value; the owner must run envs import first", 4)
            if rows:
                D.parse_bw_ref(rows[0].value)
            snap.replace(doc.rewrite({args.name: ref.canonical}), recovery_dir=private_dir(state_path("recovery")))
        else:
            # Creation is exclusive. No unrelated document is read or replaced in metadata mode.
            module("imports").publish(path, None, args.name + "=" + ref.canonical + "\n", sys.modules[__name__], None)
        with metadata_lock():
            policies = read_state("ref-policies.json")
            key = policy_key(cfg, env)
            if key in policies:
                # Protection is durable human classification. Metadata edits revoke
                # target authority without deleting that classification.
                policies[key]["digest"] = None
                policies[key]["identities"] = {}
            write_state("ref-policies.json", policies)
        E.say(f"{args.name}: reference saved in {args.file or default_file}; human approval required")
        return
    specs = effective(cfg, env)
    for relative, _, doc in specs["docs"]:
        for name, ref in doc.references().items():
            E.say(f"{relative}\t{name}\t" + (ref.canonical if args.locations else "valid-reference"))


def reference_status(cfg, env):
    specs = effective(cfg, env)
    record = read_state("ref-policies.json").get(policy_key(cfg, env), {})
    return {"names": specs["names"], "sources": specs["sources"], "references": sorted(specs["refs"]),
            "reference_approval": "current" if record.get("digest") == mapping_digest(cfg, env, specs) else "unapproved",
            "legacy": specs["legacy"]}


def new_run_required(args):
    if E.agent_context() or getattr(args, "env_file", False):
        return True
    cfg = E.cfg_for(args)
    env = E.choose_env(cfg, args.env)
    return bool(effective(cfg, env)["refs"])


def prepare_export(args, agent=False, require_source=False):
    """Binding/source/policy validation only; Send calls this before its separate publication confirmation."""
    cfg = E.cfg_for(args)
    if agent and E.binding_state(cfg.root, cfg.project)[0] != "bound":
        E.fail("agent command is not approved; ask the owner to run envs agent allow -- COMMAND", 4)
    E.require_bound(cfg)
    env = E.choose_env(cfg, getattr(args, "env", None))
    if agent and cfg.is_protected(env):
        E.fail(f"agents cannot use protected environment {env}", 4)
    E.guard_protected(cfg, env, getattr(args, "prod", False))
    specs = effective(cfg, env)
    only = getattr(args, "only", None) or []
    if isinstance(only, str):
        only = [n for n in only.split(",") if n]
    if set(only) - set(specs["names"]):
        E.fail("--only includes undeclared names", 2)
    wanted = [n for n in specs["names"] if not only or n in only]
    policy = check_ref_policy(cfg, env, specs, agent, getattr(args, "prod", False))
    source_name = getattr(args, "env_source", None) or getattr(args, "file", None)
    source = None
    if source_name is not None:
        if Path(source_name).is_absolute():
            try:
                source_name = str(Path(source_name).relative_to(cfg.root))
            except ValueError:
                E.fail("source is outside approved root", 4)
        if source_name not in source_selection(cfg, env):
            E.fail("source was not approved; the owner must run envs bind --ref-file again", 4)
        source = next(((relative, snap, doc) for relative, snap, doc in specs["docs"] if relative == source_name), None)
    elif specs["docs"]:
        source = specs["docs"][0]
    if source is None and require_source:
        selected = source_name or (source_selection(cfg, env)[0] if source_selection(cfg, env) else ".env")
        if selected not in source_selection(cfg, env):
            E.fail("source was not approved; the owner must run envs bind --ref-file again", 4)
        snapshot = D.read_document(source_path(cfg, selected), cfg.root, private=cfg.is_global)
        document = D.DotenvDocument(snapshot.text)
        document.references()
        for entry in document.records:
            if entry.name in specs["names"] and not entry.value.startswith("bw://"):
                E.fail(f"{entry.name}: literal value conflicts with declared secret; run envs import", 4)
        source = (selected, snapshot, document)
    return {"cfg": cfg, "env": env, "specs": specs, "wanted": wanted, "policy": policy, "source": source}


def resolve_export(context, sync=False, agent=False):
    cfg, env, specs, wanted = (context[k] for k in ("cfg", "env", "specs", "wanted"))
    values = resolve_refs(cfg, env, specs, wanted, context["policy"])
    legacy = [n for n in wanted if n in specs["legacy"]]
    if legacy:
        if agent:
            if not E.rbw_unlocked():
                E.fail("vault is locked; command not started", 3)
        else:
            E.ensure_rbw(sync)
        fields = E.env_fields(cfg.project, env, names=legacy) or {}
        for name in legacy:
            value = fields.get(name)
            if not isinstance(value, str) or not value:
                E.fail(f"{name}: required secret unavailable", 1)
            if agent and len(value) < 6:
                E.fail(f"{name} is too short for safe output masking", 4)
            values[name] = value
    for _, snap, _ in specs["docs"]:
        snap.verify()
    return values


def command_argv(context, cmd, args, values):
    cfg, env, specs = (context[k] for k in ("cfg", "env", "specs"))
    use_mise = not getattr(args, "no_mise", False) and not cfg.is_global
    argv, mised = E.mise_cmd(cfg, cmd, env) if use_mise else (list(cmd), False)
    child = E.command_env(os.environ)
    for name in specs["names"]:
        child.pop(name, None)
    child.update(values)
    child["ENVS_PROJECT"], child["ENVS_ENV"] = cfg.project, env
    child["ENVS_SECRETS"] = " ".join(values)
    if mised:
        local = E.mise_env_keys(cfg.root)
        shadow = types.SimpleNamespace(root=cfg.root, secrets=dict.fromkeys(specs["names"]))
        if set(values) & set(local) or E.parent_mise_overrides(shadow):
            E.fail("mise overrides an injected name; command not started", 4)
        child["MISE_ENV"] = env
        for key in ("MISE_AUTO_INSTALL", "MISE_NOT_FOUND_AUTO_INSTALL", "MISE_EXEC_AUTO_INSTALL", "MISE_TASK_RUN_AUTO_INSTALL"):
            child[key] = "0"
        for key in E.MISE_LOG_ENV:
            child.pop(key, None)
        child["MISE_LOG_LEVEL"] = "warn"
    return argv, child


def cmd_run(args, cmd):
    agent = E.agent_context()
    if agent:
        return module("policy").run(args, cmd, sys.modules[__name__])
    context = prepare_export(args, require_source=getattr(args, "env_file", False))
    values = resolve_export(context, getattr(args, "sync", False))
    argv, child = command_argv(context, cmd, args, values)
    for _, snap, _ in context["specs"]["docs"]:
        snap.verify()
    if getattr(args, "env_file", False):
        runtime = module("runtime")
        try:
            if not any("{envfile}" in word for word in cmd):
                E.fail("--env-file requires an argv {envfile} placeholder", 2)
            text = runtime.render_document(context["source"][2], values, context["specs"]["names"], omit_unselected=True)
            with private_envfile(text) as path:
                argv = [word.replace("{envfile}", str(path)) for word in argv]
                return runtime.supervise_run(argv, child, agent=False, on_error=lambda msg: E.warn(msg))
        except runtime.RuntimeProblem:
            E.fail("value or runtime cannot support the strict dotenv file; command not started", 4)
    if any("{envfile}" in word for word in cmd):
        E.fail("{envfile} requires --env-file", 2)
    if context["cfg"].is_protected(context["env"]):
        E.journal(f"run project={context['cfg'].project} env={context['env']} cmd={os.path.basename(cmd[0])} vars={len(values)}")
    sys.stdout.flush(); sys.stderr.flush()
    try:
        os.execvpe(argv[0], argv, child)
    except OSError:
        E.fail("cannot run command", 127)


WRAPPER_RESERVED = {"envs", "er", "ere", "ert", "eval", "exec", "command", "builtin", "source", "alias", "unalias",
                    "typeset", "declare", "export", "set", "unset", "cd", "read", "printf", "echo", "test", "true", "false",
                    "exit", "return", "local", "function", "sudo", "doas", "su", "login"}


def load_wrap_rows():
    directory = E.global_dir()
    # File names only; neither the shell loader nor this editor reads vault values.
    path = directory / "wrap.tsv"
    if not path.exists() and not path.is_symlink():
        return []
    snap = D.read_document(path, private=True)
    result, seen = [], set()
    for line in snap.text.splitlines():
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 3:
            E.fail("invalid local wrapper metadata", 4)
        name, binary, names = fields
        if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]*", name) or name in WRAPPER_RESERVED or name in seen:
            E.fail("invalid local wrapper command", 4)
        if not Path(binary).is_absolute() or any(ord(c) < 32 or ord(c) == 127 for c in binary):
            E.fail("invalid local wrapper executable", 4)
        if not Path(binary).is_file() or not os.access(binary, os.X_OK) or Path(binary).resolve() == E.SELF:
            E.fail("wrapper executable is unavailable or recursive", 4)
        selected = names.split(",")
        if not selected or len(set(selected)) != len(selected) or any(E.bad_var_name(n) for n in selected):
            E.fail("invalid local wrapper variable names", 4)
        seen.add(name); result.append((name, binary, selected))
    return result


def cmd_global_wrap(args):
    E.refuse_agent("global-wrap")
    if not E.tty() and not (E.test_mode() and os.environ.get("ENVS_TEST_YES") == "1"):
        E.fail("global-wrap requires a human terminal", 4)
    rows = load_wrap_rows()
    if args.list:
        for name, binary, names in rows:
            E.say(f"{name}\t{binary}\t{','.join(names)}")
        return
    name = args.remove or args.name
    if not name or not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]*", name) or name in WRAPPER_RESERVED:
        E.fail("invalid or reserved wrapper name", 4)
    rows = [row for row in rows if row[0] != name]
    if not args.remove:
        binary = args.binary
        if not binary or not Path(binary).is_absolute() or any(ord(c) < 32 or ord(c) == 127 for c in binary):
            E.fail("wrapper requires an absolute executable", 4)
        if not Path(binary).is_file() or not os.access(binary, os.X_OK) or Path(binary).resolve() == E.SELF:
            E.fail("wrapper executable is unavailable or recursive", 4)
        names = [n for n in (args.only or "").split(",") if n]
        if not names or any(E.bad_var_name(n) for n in names) or len(set(names)) != len(names):
            E.fail("wrapper needs valid unique --only names", 4)
        cfg = E.load_global()
        if set(names) - set(effective(cfg, cfg.default)["names"]):
            E.fail("wrapper names are not declared in the effective global mapping", 4)
        rows.append((name, binary, names))
    directory = E.global_dir()
    if not directory.exists():
        private_dir(directory)
    path = directory / "wrap.tsv"
    content = "".join(f"{n}\t{b}\t{','.join(names)}\n" for n, b, names in sorted(rows))
    if path.exists() or path.is_symlink():
        D.read_document(path, private=True).replace(content, recovery_dir=private_dir(state_path("recovery")))
    else:
        module("imports").publish(path, None, content, sys.modules[__name__], None)
    E.say(f"{name}: wrapper {'removed' if args.remove else 'saved'}; new shells load the change")


@contextlib.contextmanager
def private_envfile(text):
    runtime = module("runtime")
    if E.test_mode():
        import tempfile
        with tempfile.TemporaryDirectory(prefix="envs-private-test.", dir="/dev/shm") as base:
            with runtime.private_envfile(text, base=base) as path:
                yield path
    else:
        with runtime.private_envfile(text) as path:
            yield path


def cmd_send(args):
    return module("send").run(args, sys.modules[__name__], module("runtime"))


def cmd_agent(args, cmd=None):
    return module("policy").command(args, cmd, sys.modules[__name__])


def cmd_import(args):
    return module("imports").run(args, sys.modules[__name__])


def cmd_scan(args):
    return module("scan").run(args, sys.modules[__name__])


def audit_denied(cmd):
    return module("policy").audit(None, cmd, [], "deny", sys.modules[__name__])
