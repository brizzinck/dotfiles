# AGENTS.md

Instructions for every coding agent in this repository (Codex, Claude Code, others).

- `CLAUDE.md` is the project documentation for all agents, not only Claude: read it first. It is the index: the rules that
  apply everywhere, how changes are applied (`stow .`, `sudo ./apply-system.sh --only SECTION`) and one topic file under
  `docs/agents/` per subsystem (its tests and doctor checks); read that file before you work on the subsystem.
- The ongoing workstation overhaul is coordinated outside the repo, in `~/.local/share/workstation-overhaul/`
  (private, local only). Start with `CODEX.md` there, then `agent-rules.md`; both are binding.
- Never commit the `private` submodule, `env.secret.sh` or anything from the coordination directory; this repository is
  public.
