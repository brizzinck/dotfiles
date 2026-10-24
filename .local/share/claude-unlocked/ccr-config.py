#!/usr/bin/python3 -I
"""ccr-config.py: the claude-code-router store of claude-unlocked (docs: CLAUDE.md "Claude unlocked").

The store lives in tmpfs ($XDG_RUNTIME_DIR/claude-unlocked/.claude-code-router/config.sqlite): ccr keeps provider keys in
plain text there and has no ${VAR} expansion at runtime, so the keys must never reach a persistent file. Every value comes
from the environment set by claude-unlocked; stdout carries only what the launcher reads back.

  ccr-config.py seed NAME     NAME's provider from the template, key from $<NAME>_API_KEY (envs run -g injects it)
  ccr-config.py has-key NAME  exit 0 when provider NAME has a key in the store
  ccr-config.py layout        router settings of the template (custom router, timeout, fallback, no request logs)
  ccr-config.py sync          refresh each picker provider's model list from its live /models
  ccr-config.py key           print the local gateway client key
  ccr-config.py settings      print the --settings JSON for Claude Code
  ccr-config.py resume-model ARGS...  print the model a resumed chat should start on
"""
import datetime
import glob
import json
import os
import re
import sqlite3
import sys
import urllib.request

DB = os.environ.get("CU_ROUTER_DB", "")

# Non-secret provider template. The key arrives only through `seed`; `sync` fills `models` from the live API.
PROVIDERS = {
    "arliai": {
        "id": "provider-arliai",
        "url": "https://api.arliai.com/v1",
        "extraBody": {"default": {}, "Qwen3.5-27B-Derestricted": {"presence_penalty": 1.5}},
    },
    "explabs": {
        "id": "provider-explabs",
        "url": "https://api.experientiallabs.ai/v1",
        "extraBody": {"default": {}},
    },
}


def err(msg):
    print(f"claude-unlocked: {msg}", file=sys.stderr)


def connect(readonly=False):
    if readonly:
        return sqlite3.connect("file:" + DB + "?mode=ro", uri=True, timeout=10)
    return sqlite3.connect(DB, timeout=10)


def load(db):
    row = db.execute("select value_json from app_config where key = ?", ("default",)).fetchone()
    if not row:
        raise RuntimeError("router store has no default config (start ccr once)")
    return json.loads(row[0])


def save(db, cfg):
    now = datetime.datetime.now(datetime.timezone.utc).isoformat()
    with db:
        db.execute("update app_config set value_json = ?, updated_at = ? where key = ?", (json.dumps(cfg), now, "default"))
    # The gateway reads its config only at start: the launcher restarts it when this stamp is newer than service.json startedAt.
    with open(os.environ["CU_MARKER"], "w") as marker:
        marker.write(now + "\n")


def providers_of(cfg):
    return {p.get("name"): p for p in cfg.get("Providers", [])}


def cmd_seed(name):
    tpl = PROVIDERS.get(name)
    if tpl is None:
        err(f"unknown provider {name}")
        return 2
    key = os.environ.get(name.upper() + "_API_KEY", "").strip()
    if not key:
        err(f"{name}: no key in the environment")
        return 1
    url = os.environ.get(name.upper() + "_BASE_URL", "").rstrip("/") or tpl["url"]
    db = connect()
    cfg = load(db)
    providers = cfg.setdefault("Providers", [])
    entry = next((p for p in providers if p.get("name") == name), None)
    if entry is None:
        entry = {"id": tpl["id"], "name": name, "models": [], "protocolDetectionMode": "manual", "extraBody": tpl["extraBody"]}
        providers.append(entry)
    entry.update({"api_base_url": url, "api_key": key, "capabilities": [{"baseUrl": url, "type": "openai_chat_completions"}]})
    save(db, cfg)
    return 0


def cmd_has_key(name):
    try:
        entry = providers_of(load(connect(readonly=True))).get(name) or {}
    except Exception:
        return 1
    return 0 if entry.get("api_key") else 1


def cmd_layout():
    db = connect()
    cfg = load(db)
    want = {
        "CUSTOM_ROUTER_PATH": os.environ["CU_CUSTOM_ROUTER"],
        "API_TIMEOUT_MS": 3600000,
    }
    changed = any(cfg.get(k) != v for k, v in want.items())
    cfg.update(want)
    router = cfg.setdefault("Router", {})
    fallback = {"mode": "retry", "models": [], "retryCount": 3}
    if router.get("fallback") != fallback:
        router["fallback"] = fallback
        changed = True
    obs = cfg.setdefault("observability", {})
    if obs.get("requestLogs") is not False:
        obs["requestLogs"] = False
        changed = True
    prof = cfg.setdefault("profile", {})
    if prof.get("enabled") is not False:
        prof["enabled"] = False
        changed = True
    if prof.get("profiles") != []:
        prof["profiles"] = []
        changed = True
    if prof.get("claudeCode", {}).get("enabled") is not False:
        prof.setdefault("claudeCode", {})["enabled"] = False
        changed = True
    if changed:
        save(db, cfg)
    return 0


# Each picker provider is refreshed from its live /models on every launch: the router rejects a model missing from the
# provider's saved list. Models the API flags as not supporting tools are dropped (Claude Code always sends tools). A provider
# that reports context windows gets per-model compact windows (CU_WINDOWS) and output caps (extraBody max_tokens). A failed
# fetch keeps the saved list.
def cmd_sync():
    try:
        db = connect()
        cfg = load(db)
    except Exception as exc:
        err(f"model sync skipped: {exc}")
        return 0
    changed = False
    windows = {}
    max_output = int(os.environ["CU_MAX_OUTPUT"])
    context_percent = int(os.environ["CU_CONTEXT_PERCENT"])
    compact_max = int(os.environ["CU_COMPACT_MAX"])
    providers = providers_of(cfg)
    for name in os.environ["CU_PICKER_PROVIDERS"].split():
        entry = providers.get(name)
        if not entry or not entry.get("api_key"):
            continue
        try:
            base = entry["api_base_url"].split("/chat/completions")[0].rstrip("/")
            req = urllib.request.Request(base + "/models", headers={"Authorization": "Bearer " + entry["api_key"]})
            data = json.load(urllib.request.urlopen(req, timeout=20)).get("data", [])
        except Exception as exc:
            err(f"{name} model sync skipped: {exc}")
            continue
        live = []
        caps = {}
        for m in data:
            if "supports_tools" in m and m["supports_tools"] is not True:
                continue
            ctx = m.get("context_window_tokens")
            if ctx:
                out = min(max_output, m.get("maximum_output_tokens") or max_output)
                compact = min(compact_max, ctx * context_percent // 100, ctx - out - 8000)
                if compact < 100000:
                    compact = 100000
                    out = ctx - compact - 8000
                if out < 4096:
                    continue
                windows[name + "/" + m["id"]] = compact
                if out < max_output:
                    caps[m["id"]] = out
            live.append(m["id"])
        if any("context_window_tokens" in m for m in data):
            body = entry.get("extraBody") or {}
            new_body = {"default": body.get("default", {})}
            for model_id, extra in body.items():
                if model_id != "default" and model_id in live:
                    rest = {k: v for k, v in extra.items() if k != "max_tokens"}
                    if rest:
                        new_body[model_id] = rest
            for model_id, out in caps.items():
                new_body[model_id] = {**new_body.get(model_id, {}), "max_tokens": out}
            if new_body != body:
                entry["extraBody"] = new_body
                changed = True
                err(f"{name} output caps: {len(caps)} models below {max_output}")
        if not live or live == entry.get("models"):
            continue
        old = set(entry.get("models", []))
        entry["models"] = live
        changed = True
        err(f"{name} models synced: {len(live)} live, +{len(set(live) - old)} -{len(old - set(live))}")
    try:
        with open(os.environ["CU_WINDOWS"]) as f:
            old_windows = json.load(f)
    except Exception:
        old_windows = None
    if windows != old_windows:
        os.makedirs(os.path.dirname(os.environ["CU_WINDOWS"]), exist_ok=True)
        with open(os.environ["CU_WINDOWS"], "w") as f:
            json.dump(windows, f, indent=1, sort_keys=True)
    if not changed:
        return 0
    save(db, cfg)
    return 0


def cmd_key():
    row = connect(readonly=True).execute("select encrypted_key, encryption from api_keys where id = ?", ("local-gateway",)).fetchone()
    if not row or row[1] != "plain" or not row[0]:
        err("router store has no plain local-gateway key")
        return 1
    print(row[0])
    return 0


# Settings passed on the command line only, so ~/.claude/settings.json and plain `claude` stay untouched:
#   attribution off; modelPicker = every model of the picker providers; autoCompactWindow / modelSettings from the windows;
#   hooks.Stop when CU_GOAL is set (a Stop prompt hook is the only way to raise the 30s goal-check timeout);
#   hooks.PreToolUse blocking Read on images when CU_BLOCK_IMAGES names the hook command.
def cmd_settings():
    settings = {"attribution": {"commit": "", "pr": ""}}
    options = []
    try:
        providers = providers_of(load(connect(readonly=True)))
        for name in os.environ["CU_PICKER_PROVIDERS"].split():
            options += [
                {"model": f"{name}/{m}", "label": m, "description": name}
                for m in providers.get(name, {}).get("models", [])
            ]
    except Exception as exc:
        err(f"model picker skipped: {exc}")
    if options:
        settings["modelPicker"] = {"options": options}
    if os.environ.get("CU_DEFAULT_COMPACT"):
        settings["autoCompactWindow"] = int(os.environ["CU_DEFAULT_COMPACT"])
    try:
        with open(os.environ["CU_WINDOWS"]) as f:
            windows = json.load(f)
    except Exception:
        windows = {}
    if windows:
        settings["modelSettings"] = {m.lower(): {"autoCompactWindow": w} for m, w in windows.items()}
    goal = os.environ.get("CU_GOAL", "")
    if goal:
        hook = {"type": "prompt", "prompt": goal, "timeout": int(os.environ["CU_GOAL_TIMEOUT"])}
        if os.environ.get("CU_GOAL_MODEL"):
            hook["model"] = os.environ["CU_GOAL_MODEL"]
        settings.setdefault("hooks", {})["Stop"] = [{"hooks": [hook]}]
    if os.environ.get("CU_BLOCK_IMAGES"):
        settings.setdefault("hooks", {})["PreToolUse"] = [
            {"matcher": "Read", "hooks": [{"type": "command", "command": os.environ["CU_BLOCK_IMAGES"], "timeout": 10}]}
        ]
    print(json.dumps(settings))
    return 0


# A resumed chat keeps the model it last ran on. --resume <id> reads that transcript; --continue and the bare --resume picker
# read the newest transcript of this directory. An explicit --model or a model the router no longer serves keep the default.
def cmd_resume_model(args):
    default = os.environ["CU_DEFAULT_MODEL"]
    mode, session = None, None
    for i, a in enumerate(args):
        if a == "--model" or a.startswith("--model="):
            print(default)
            return 0
        if a in ("-c", "--continue"):
            mode = mode or "latest"
        elif a in ("-r", "--resume"):
            mode = "resume"
            if i + 1 < len(args) and not args[i + 1].startswith("-"):
                session = args[i + 1]
        elif a.startswith("--resume="):
            mode, session = "resume", a.split("=", 1)[1]
    if not mode:
        print(default)
        return 0
    project = os.path.join(os.environ["CU_PROJECTS"], re.sub(r"[^A-Za-z0-9]", "-", os.getcwd()))
    path = os.path.join(project, f"{session}.jsonl") if session else None
    if not path or not os.path.isfile(path):
        files = sorted(glob.glob(os.path.join(project, "*.jsonl")), key=os.path.getmtime)
        path = files[-1] if files else None
    model = None
    if path:
        with open(path) as f:
            for line in f:
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                if rec.get("type") != "assistant" or rec.get("isSidechain"):
                    continue
                m = (rec.get("message") or {}).get("model") or ""
                if "/" in m:
                    model = m
    try:
        served = {f"{n}/{m}" for n, p in providers_of(load(connect(readonly=True))).items() for m in p.get("models", [])}
    except Exception:
        served = None
    print(model if model and (served is None or model in served) else default)
    return 0


def main(argv):
    if not argv:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    cmd, rest = argv[0], argv[1:]
    if cmd == "seed" and len(rest) == 1:
        return cmd_seed(rest[0])
    if cmd == "has-key" and len(rest) == 1:
        return cmd_has_key(rest[0])
    if cmd == "layout":
        return cmd_layout()
    if cmd == "sync":
        return cmd_sync()
    if cmd == "key":
        return cmd_key()
    if cmd == "settings":
        return cmd_settings()
    if cmd == "resume-model":
        return cmd_resume_model(rest)
    print(__doc__.strip(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
