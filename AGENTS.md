# AGENTS.md

Instructions for every coding agent in this repository (Codex, Claude Code, others).

- `CLAUDE.md` is the project documentation for all agents, not only Claude: read it first. It describes every subsystem,
  its tests and its doctor checks, and how changes are applied (`stow .`, `sudo ./apply-system.sh --only SECTION`).
- The ongoing workstation overhaul is coordinated outside the repo, in `~/.local/share/workstation-overhaul/`
  (private, local only). Start with `CODEX.md` there, then `agent-rules.md`; both are binding.
- Never commit the `private` submodule, `env.secret.sh` or anything from the coordination directory; this repository is
  public.
