# Claude unlocked (YaCodeDevAgents installer)

Topic file of the agent docs. `CLAUDE.md` holds the index, the rules that apply everywhere and the file of every section.

### Claude unlocked
`claude-unlocked [CLAUDE ARGS...]` runs Claude Code on OpenAI-compatible providers (YaCodeDev AI Gateway, ArliAI, Experiential Labs) through a private claude-code-router. Since 2026-11-11 it is NOT part of this repo: it comes from the team repo `git@github.com:YaCodeDev/YaCodeDevAgents.git` (directory `claude-unlocked/`, its `README.md` is the reference), checked out at `~/Programs/YaCodeDevAgents`. The earlier home-grown port (stowed launcher, `ccr-config.py`, tmpfs router store seeded from Bitwarden, the `cu-no-settings` patch, the global npm ccr pinned in `user-tools.sh`) was removed in favour of it.

- **System-wide Multi-User Architecture**: Installed at `/srv/claude-unlocked` (permissions 0755, owned by `skalse:skalse`) with system configuration at `/etc/claude-unlocked/env` (mode 0644), so all workstation users (`skalse`, `td`, `yc`, and future users) have immediate execution access without redundant installations.
  - Symlinks in `/usr/local/bin` and `/srv/devtools/bin`: `claude-unlocked`, `claude-unlocked-rea`, `claude-unlocked-update`, `unlocked-task`, and fallback `claude` CLI.
  - Runtime separation: When `/srv/claude-unlocked` is non-writable by a user, runtime state (`router-home`) automatically routes to `~/.local/share/claude-unlocked/router-home` per user. Each user gets their own sqlite store without permission collisions, while sharing port 3460 if the router daemon is already healthy.
- **Settings Hierarchy**:
  1. Base settings & global provider keys in `/etc/claude-unlocked/env` (mode 0644).
  2. Per-user overrides in `~/.config/claude-unlocked/env`.
  3. Per-invocation environment overrides (`CLAUDE_UNLOCKED_*`).
  - Base owner settings: `CLAUDE_UNLOCKED_DISALLOWED_TOOLS="Artifact,DesignSync,Workflow,PushNotification,SendFeedback"` (slim mode), `CLAUDE_UNLOCKED_AUTO_COMPACT_MAX=300000`.
- **`~/.claude/settings.json` stays safe**: the router runs with `HOME=router-home` (and `CCR_INTERNAL_HOME_DIR`, XDG dirs), so its profile management writes into files nothing reads. Plain `claude` is untouched; the launcher passes everything as env and `--settings`.
- **Secrets from Bitwarden**:
  - Keys are stored in Bitwarden:
    - `AIGATEWAY_API_KEYS`: item `AIGatewayToken` (no folder, YaCodeDev organisation; token is in password or notes field).
    - `ARLIAI_API_KEYS`: folder `Env/global`, item `default`, field `ARLIAI_API_KEY`.
    - `EXPLABS_API_KEYS`: folder `Env/global`, item `default`, field `EXPLABS_API_KEY`.
  - `claude-unlocked-update` queries `rbw` directly if unlocked and populates the keys into the environment before calling the installer.
  - Upstream design keeps the provider keys in `/etc/claude-unlocked/env` (readable by all users on the workstation).
- **Update & Management**: `claude-unlocked-update` (`.local/bin/claude-unlocked-update`, stowed):
  - Fetches keys from Bitwarden automatically if `rbw` is unlocked.
  - Detects system install mode (`/srv/claude-unlocked` and `/etc/claude-unlocked`) or falls back to user home.
  - Pulls upstream `~/Programs/YaCodeDevAgents`.
  - Installs into `/srv/claude-unlocked` and writes `/etc/claude-unlocked/env` (mode 0644).
  - Handles Node/mise isolation and `better-sqlite3` rebuild automatically.
- **Workers for the main session** (`unlocked-task`, `.local/bin/unlocked-task`, stowed, `#!/usr/bin/python3 -I`): the main Claude stays on the owner's subscription; work that would go to a Sonnet / Haiku subagent runs as a headless `claude-unlocked -p --output-format json --effort high` worker on `aigateway/qwen3.8-flash-next-abliterated` (the router maps `output_config.effort` to the upstream `reasoning_effort`). Modes: default read-only (`--permission-mode default`, allowed Read, Glob, Grep, read-only git; other tools are denied in `-p`), `--write` (acceptEdits, no Bash), `--bash` (bypassPermissions). At most `UNLOCKED_TASK_MAX` (default 4) workers at once: each holds an `O_CLOEXEC` flock slot in `$XDG_RUNTIME_DIR/unlocked-task/` (not inherited, so a router daemon started by a worker never keeps a slot); a call past the limit exits 75 (`all 4 Qwen worker slots are busy`), `--slots` prints `busy N/4`, `--wait` queues. Planning rule (skill and rule file): heavy tasks to Sonnet 5.5 high, light non-priority tasks to up to 4 Qwen workers, Qwen first whenever it fits and a slot is free, light overflow waits unless urgent. Measured: one worker 14 s for a one-word answer, four in parallel about 63 s each (the gateway serialises them). Answer on stdout, `[unlocked-task: model, turns, s, ok|error]` on stderr, exit 1 on a worker error. The manual is the skill `unlocked-workers` (`private/.claude/skills/unlocked-workers/SKILL.md`, reached through the `~/.claude/skills` link); the always-on rule is `~/.claude/UNLOCKED.md`, included from `~/.claude/CLAUDE.md` (both outside the repo, like `RTK.md`): no Sonnet / Haiku subagents, `unlocked-task` instead, and a one-line recommendation to the owner when Sonnet 5.5 high fits better (criteria in the skill), then an Agent with `model: "sonnet"`, `effort: "high"` on the subscription once the owner agrees or after Qwen failed the same task twice. Tested 2026-11-11: a read-only question answered correctly (2 turns, 8 s), `--write` fixed a planted bug, a read-only worker could not run `touch`.
- **Doctor check**: `./doctor.sh` includes `users-claude-unlocked`. Reports INFO until `/srv/claude-unlocked` and `/etc/claude-unlocked/env` are configured, then checks read permissions and link validity.
- **Checks**: `claude-unlocked --selftest` (bwrap sandbox, `/usr/bin/bwrap` is installed), `claude-unlocked --router stop|start|status` for the router (port 3460, UI on 3462). Never run a bare `ccr`: without the private HOME it rewrites `~/.claude/settings.json`.
- **Default model**: `aigateway/qwen3.8-flash-next-abliterated`; `/model` lists every model of the three providers (405 on 2026-11-11). Smoke test 2026-11-11: `claude-unlocked -p "reply with the single word pong"` -> `pong`, `--selftest` all ok, `~/.claude/settings.json` unchanged.
