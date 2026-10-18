"""All-or-nothing literal imports. Values remain in memory and private recovery copies."""
import copy
import os
from pathlib import Path
import stat
import time


def read_optional(path, c, private=True):
    if not path.exists() and not path.is_symlink():
        return None
    return c.D.read_document(path, private=private)


def prepare_target(path, c):
    path = Path(path)
    if not path.parent.exists():
        c.private_dir(path.parent)
    with c.D.parent_fd(path) as (fd, name):
        st = os.fstat(fd)
        if st.st_uid != os.getuid() or st.st_mode & 0o022:
            raise c.D.Problem("unsafe import destination directory")
    return read_optional(path, c)


def publish(path, snapshot, text, c, recovery):
    if snapshot is not None:
        snapshot.replace(text, recovery_dir=recovery)
        installed = c.D.read_document(path, private=True)
        if installed.text != text:
            raise c.D.Problem("destination changed; source retained")
        return installed
    data = text.encode("utf-8")
    with c.D.parent_fd(path) as (fd, name):
        parent = (os.fstat(fd).st_dev, os.fstat(fd).st_ino)
        temp = ".envs-import-" + os.urandom(12).hex()
        raw = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd)
        try:
            with os.fdopen(raw, "wb") as target:
                target.write(data); target.flush(); os.fsync(target.fileno())
                created = (os.fstat(target.fileno()).st_dev, os.fstat(target.fileno()).st_ino)
            os.link(temp, name, src_dir_fd=fd, dst_dir_fd=fd, follow_symlinks=False)
            os.unlink(temp, dir_fd=fd)
            os.fsync(fd)
            with c.D.parent_fd(path) as (current, current_name):
                if ((os.fstat(current).st_dev, os.fstat(current).st_ino) != parent
                        or not c.D._payload_matches(current, current_name, created, data)):
                    raise c.D.Problem("destination changed; source retained")
        finally:
            try:
                os.unlink(temp, dir_fd=fd)
            except FileNotFoundError:
                pass
    installed = c.D.read_document(path, private=True)
    if installed.ident[:2] != created or installed.text != text:
        raise c.D.Problem("destination changed; source retained")
    return installed


def backup(snapshot, destination, c):
    with c.D.parent_fd(destination) as (fd, name):
        raw = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd)
        with os.fdopen(raw, "wb") as target:
            target.write(snapshot.text.encode()); target.flush(); os.fsync(target.fileno())
        os.fsync(fd)


def classify(doc, args, c):
    existing = doc.references()
    values = {name: value for name, value in doc.values().items() if name not in existing}
    if not values:
        c.E.fail("no literal assignments to import", 2)
    supplied = any(getattr(args, key, None) is not None for key in ("secrets", "plain", "drop"))
    groups = {key: [name for name in (getattr(args, key, None) or "").split(",") if name] for key in ("secrets", "plain", "drop")}
    if not supplied:
        if not c.E.tty():
            c.E.fail("no terminal to classify: supply complete --secrets/--plain/--drop names", 2)
        for name, value in values.items():
            guess = "secret" if c.E.looks_secret(name, value) else "plain"
            while True:
                c.E.say(name + ": guess " + guess)
                answer = input(name + ": [s]ecret / [p]lain / [d]rop / [q]uit: ").strip().lower()
                if answer == "q":
                    c.E.fail("import cancelled; no values imported", 130)
                group = {"s": "secrets", "p": "plain", "d": "drop"}.get(answer)
                if group:
                    groups[group].append(name); break
    classified = [name for group in groups.values() for name in group]
    if set(classified) != set(values) or len(classified) != len(set(classified)):
        c.E.fail("classification must name every literal assignment exactly once", 2)
    for name in classified:
        if c.E.bad_var_name(name):
            c.E.fail(name + ": reserved or invalid import name; no values imported", 4)
    for name in groups["secrets"]:
        if len(values[name]) < 6:
            c.E.fail(name + " is too short for safe output masking; no values imported", 4)
        if "\x00" in values[name]:
            c.E.fail(name + ": unsupported secret; no values imported", 4)
    for group, names in groups.items():
        c.E.say(group + ": " + ", ".join(names))
    if groups["drop"] or getattr(args, "global_", False):
        if not getattr(args, "yes", False) and not c.E.confirm("Apply these classifications, including removal of drop records?"):
            c.E.fail("import not confirmed; no values imported", 4)
    return values, groups


def shell_literal(value):
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$").replace("`", "\\`") + '"'


def run(args, c):
    E, D = c.E, c.D
    E.refuse_agent("import")  # Before opening the source or examining any literal value.
    global_ = getattr(args, "global_", False)
    cfg = E.load_global(augment=False) if global_ else E.load_cfg(augment=False)
    E.require_bound(cfg)
    env = getattr(args, "env", None) or cfg.default
    E.need_env(cfg, env); E.guard_protected(cfg, env, getattr(args, "prod", False), "import into")
    canonical = E.global_dir().parent / "secrets/env.sh"
    if global_:
        if getattr(args, "plain_to_mise", False):
            E.fail("global imports use canonical shell exports, not mise", 2)
        source = Path(os.path.abspath(args.file)) if args.file else canonical
        # Arbitrary explicit human input is allowed, credential stores remain excluded.
        legacy = E.HOME / "dotfiles/env.secret.sh"
        if source not in (canonical, legacy) and c.forbidden_source(source):
            E.fail("source is a credential location", 4)
        snap = D.read_document(source, private=True)
    else:
        source = Path(os.path.abspath(args.file)) if args.file else cfg.root / ".env"
        try:
            relative = str(source.relative_to(cfg.root))
        except ValueError:
            E.fail("source is outside approved root", 4)
        source = c.source_path(cfg, relative)
        basename = source.name.casefold()
        if any(basename.startswith(".env." + protected.casefold()) and env.casefold() != protected.casefold()
               for protected in cfg.protected):
            E.fail("protected source does not match selected environment", 4)
        snap = D.read_document(source, cfg.root)
    try:
        doc = D.DotenvDocument(snap.text, shell=global_)
    except D.Problem as problem:
        E.fail("line %s: unsupported %s syntax; no values imported" % (problem.line or 1, "shell" if global_ else "dotenv"), 4)
    values, groups = classify(doc, args, c)
    if E.FOLDER_PREFIX and groups["plain"]:
        E.fail("--for/--shared plain exports require a target-user migration; source retained", 4)
    secrets, plain, dropped = groups["secrets"], groups["plain"], groups["drop"]
    ref_values = {name: D.format_bw_ref(E.env_folder(cfg.project), env, name) for name in secrets}
    ref_target = E.global_dir() / "global.env"
    ref_snap = ref_doc = plain_snap = plain_doc = None
    if global_ and not E.FOLDER_PREFIX:
        ref_snap = prepare_target(ref_target, c)
        ref_doc = D.DotenvDocument(ref_snap.text if ref_snap else "")
        ref_doc.references()
        for name in secrets:
            current = ref_doc.values().get(name)
            if current is not None and current != ref_values[name] and not args.overwrite:
                E.fail(name + ": existing reference differs; source retained", 4)
        plain_snap = prepare_target(canonical, c)
        plain_doc = D.DotenvDocument(plain_snap.text if plain_snap else "", shell=True)
        for name in plain:
            current = plain_doc.values().get(name)
            if current is not None and current != values[name] and not args.overwrite and source != canonical:
                E.fail(name + ": existing canonical export differs; source retained", 4)
    mise_snap, mise_text = None, None
    if not global_ and getattr(args, "plain_to_mise", False):
        mise = E.mise_target(cfg.root, env, cfg.default)
        for name in plain:
            if name in cfg.secrets:
                E.fail(name + ": declared secret cannot become plain implicitly", 4)
        mise_snap = read_optional(mise, c, private=False)
        try:
            existing_plain = E.tomllib.loads(mise_snap.text if mise_snap else "").get("env", {})
        except ValueError:
            E.fail("mise destination has invalid TOML; source retained", 4)
        for name in plain:
            if name in existing_plain and existing_plain[name] != values[name] and not args.overwrite:
                E.fail(name + ": existing mise value differs; source retained", 4)
        editor = E.TomlText(mise_snap.text if mise_snap else "")
        for name in plain:
            editor.set("env", name, E.toml_str(values[name]))
        mise_text = editor.text()
    for name in secrets:
        if name in E.mise_env_keys(cfg.root) and not global_:
            E.fail(name + ": existing mise value conflicts with secret import", 4)
    base = c.state_path("placeholder").parent.parent / "usr/secrets-backups"
    recovery = c.private_dir(base / ("envs-import-" + str(time.time_ns()) + "-" + os.urandom(6).hex()))
    backup(snap, recovery / "source.env", c)
    for label, target in (("global.env", ref_snap), ("canonical.env", plain_snap), ("mise.toml", mise_snap)):
        if target is not None and target.path != snap.path:
            backup(target, recovery / label, c)
    snap.verify()
    transaction = {"names": sorted([*secrets, *plain, *dropped]), "phase": "prepared"}
    c.write_state("import-status.json", transaction)
    # One item edit, all conflicts checked first. An identical pre-existing value makes retry idempotent.
    with E.write_lock():
        if secrets:
            try:
                if E.managed_user():
                    c.managed_put(cfg, env, {name: values[name] for name in secrets}, args.overwrite)
                else:
                    manager = E.bw_open()
                    item = E.bw_env_item(manager, cfg.project, env, create=False)
                    if item is not None:
                        E.item_field_names(item)
                        existing = {field["name"]: field.get("value") for field in item.get("fields", [])}
                        conflicts = [name for name in secrets if name in existing and existing[name] != values[name] and not args.overwrite]
                        if conflicts:
                            E.fail("existing vault fields differ; use --overwrite only after review; source retained", 4)
                    else:
                        item = E.bw_env_item(manager, cfg.project, env, create=True)
                    edited = copy.deepcopy(item)
                    for name in secrets:
                        E.item_set_field(edited, name, values[name])
                    E.bw_save(manager, edited)
                    check = manager.bw_json("get", "item", item["id"])
                    E.item_field_names(check)
                    verified = {field["name"]: field.get("value") for field in check.get("fields", [])}
                    if check.get("id") != item["id"] or any(verified.get(name) != values[name] for name in secrets):
                        E.fail("vault readback failed", 1)
                    manager.refresh_rbw()
            except E.Fail as error:
                E.fail("vault write or verification failed; source retained", error.code if E.managed_user() else 1)
        transaction["phase"] = "vault-verified"
        c.write_state("import-status.json", transaction)
        snap.verify()
        if global_ and E.FOLDER_PREFIX:
            c.write_state("scoped-global-import.json", {"phase": "target-mapping-required", "folder": E.env_folder(cfg.project),
                                                       "env": env, "refs": ref_values, "names": sorted(secrets)})
            transaction["phase"] = "target-mapping-required"
            c.write_state("import-status.json", transaction)
            E.say("vault fields written; target-user global mapping still needs setup; source retained")
            E.say("metadata-only target references: " + str(c.state_path("scoped-global-import.json")))
            return
        if global_:
            new_refs = ref_doc.rewrite(ref_values)
            # Do not remove pre-existing declarations; new inline assignments need no TOML duplicate.
            ref_installed = publish(ref_target, ref_snap, new_refs, c, recovery) if secrets else ref_snap
            canonical_replacements = {"export " + name: shell_literal(values[name]) for name in plain}
            canonical_text = plain_doc.rewrite(canonical_replacements, set(secrets) | set(plain) | set(dropped))
            if ref_installed is not None:
                ref_installed.verify()
            plain_installed = plain_snap
            if not (source == canonical and args.keep) and (canonical_text != (plain_snap.text if plain_snap else "") or plain):
                plain_installed = publish(canonical, plain_snap, canonical_text, c, recovery)
            if source != canonical and not args.keep:
                if ref_installed is not None:
                    ref_installed.verify()
                if plain_installed is not None:
                    plain_installed.verify()
                snap.replace(doc.rewrite({}, set(secrets) | set(plain) | set(dropped)), recovery_dir=recovery)
        else:
            mise_installed = publish(mise, mise_snap, mise_text, c, recovery) if mise_text is not None else None
            if not args.keep:
                if mise_installed is not None:
                    mise_installed.verify()
                snap.replace(doc.rewrite(ref_values, dropped), recovery_dir=recovery)
    transaction["phase"] = "complete"
    c.write_state("import-status.json", transaction)
    if args.keep:
        E.warn("--keep left original plaintext assignments unchanged; retain and rotate credentials as appropriate")
    E.say("import complete; source plaintext replaced only after verified vault writes; private recovery retained")
    if not global_ and E.tracked_in_git(cfg.root, source):
        E.warn("tracked source working tree updated; old history and backups may contain credentials; review and rotate")
    if secrets:
        E.say("run envs bind" + (" -g" if global_ else "") + " to authorize the exact reference targets before use")
