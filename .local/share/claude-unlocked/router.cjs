// claude-code-router CUSTOM_ROUTER_PATH module, set by claude-unlocked.
// Claude Code sends its stop-condition check (/goal and Stop prompt hooks) to
// the small/haiku slot. This sends it to the model the same session last used
// for its main loop instead. A hook with its own model (CLAUDE_UNLOCKED_GOAL_MODEL)
// keeps that model. The router reloads this file on every request, so state
// lives on globalThis.
"use strict";
const fs = require("fs");
const os = require("os");
const path = require("path");

const EVALUATOR_MARKER = "You are evaluating a stop-condition hook in Claude Code";
const MAIN_LOOP_TOOL = "Agent";
const ENV_FILE = path.join(os.homedir(), ".config", "claude-unlocked", "env");
const MAX_SESSIONS = 1000;
const state = (globalThis.__claudeUnlockedRouter ??= {
  sessions: new Map(),
  env: { mtimeMs: -1, smallModel: "" },
});

function smallModel() {
  let stat;
  try {
    stat = fs.statSync(ENV_FILE);
  } catch {
    return state.env.smallModel;
  }
  if (stat.mtimeMs === state.env.mtimeMs) return state.env.smallModel;
  const values = {};
  for (const line of fs.readFileSync(ENV_FILE, "utf8").split("\n")) {
    const match = /^(CLAUDE_UNLOCKED_(?:SMALL_)?MODEL)=["']?([^"'\s#]+)/.exec(line);
    if (match) values[match[1]] = match[2];
  }
  const model = values.CLAUDE_UNLOCKED_SMALL_MODEL || values.CLAUDE_UNLOCKED_MODEL || "";
  state.env = { mtimeMs: stat.mtimeMs, smallModel: model.toLowerCase() };
  return state.env.smallModel;
}

module.exports = async function route(req) {
  const body = req.body;
  const sessionId = req.sessionId;
  if (!sessionId || !body || typeof body.model !== "string") return undefined;
  if (Array.isArray(body.tools) && body.tools.some((tool) => tool && tool.name === MAIN_LOOP_TOOL)) {
    state.sessions.delete(sessionId);
    state.sessions.set(sessionId, body.model);
    if (state.sessions.size > MAX_SESSIONS) state.sessions.delete(state.sessions.keys().next().value);
    return undefined;
  }
  const sessionModel = state.sessions.get(sessionId);
  if (!sessionModel || sessionModel === body.model) return undefined;
  if (!JSON.stringify(body.system ?? "").includes(EVALUATOR_MARKER)) return undefined;
  const small = smallModel();
  if (small && body.model.toLowerCase() !== small) return undefined;
  return sessionModel;
};
