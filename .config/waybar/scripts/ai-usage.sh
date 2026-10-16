#!/usr/bin/env bash
# ai-usage: waybar custom/ai (full bar). Never empty: a provider without data shows "–".
#   ai-usage.sh                  JSON: "<glyph> C 26·4  X –·100" = Claude and Codex, % used in the 5h window · weekly window,
#                                "–" = no data; tooltip: both windows per provider with "resets in ...", plan, today's ccusage
#                                cost. The class is always normal: an exhausted limit is normal, not an alert.
#   ai-usage.sh report daily     float.tui report (ccusage daily), also `blocks`
#   ai-usage.sh --record-claude  read the Claude Code statusline JSON on stdin and cache rate_limits (see below)
#
# Sources (all local, no network, nothing spends tokens):
#   Codex   ~/.codex/codex-hud/account-usage.json (codex-hud cache, `codex.rate_limits` SSE event) and
#           ~/.codex/codex-hud/account-usage/*.json; the freshest observation wins. Windows are told apart by
#           window_minutes (300 = 5h, 10080 = weekly), not by primary/secondary: the prolite plan reports only the weekly
#           window as "primary", so its 5h shows "–". A window whose reset time has passed counts as 0.
#   Claude  Claude Code hands `rate_limits` {five_hour,seven_day:{used_percentage,resets_at}} only to its statusline command
#           (claude-hud does not cache it anywhere), so the statusline output has to be tapped. Either file works, the newer
#           one wins:
#             ~/.cache/ai-usage/statusline.json  raw statusline JSON:  `tee ~/.cache/ai-usage/statusline.json | <statusline cmd>`
#             ~/.cache/ai-usage/claude.json      `tee >(ai-usage.sh --record-claude) | <statusline cmd>` (bash only)
#           Claude Code settings are not edited by this repo; until the tap exists Claude shows "–" (plus the ccusage cost).
#   Gemini  no local limit cache exists, so it is not shown.
set -u
CODEX_JSON="$HOME/.codex/codex-hud/account-usage.json"
CODEX_DIR="$HOME/.codex/codex-hud/account-usage"
CLAUDE_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/ai-usage/claude.json"
CLAUDE_RAW="${XDG_CACHE_HOME:-$HOME/.cache}/ai-usage/statusline.json"
RUN="${XDG_RUNTIME_DIR:-/tmp}/ai-usage"
CCU_CACHE="$RUN/ccusage-today.json"
G_AI='󰚩'

if [[ ${1:-} == --record-claude ]]; then
  mkdir -p "$(dirname "$CLAUDE_CACHE")"
  jq -c --argjson now "$(date +%s)" '{five_hour: .rate_limits.five_hour, seven_day: .rate_limits.seven_day, saved_at: $now} | select(.five_hour != null or .seven_day != null)' \
    >"$CLAUDE_CACHE.tmp" 2>/dev/null && [[ -s $CLAUDE_CACHE.tmp ]] && mv -f "$CLAUDE_CACHE.tmp" "$CLAUDE_CACHE"
  rm -f "$CLAUDE_CACHE.tmp"
  exit 0
fi

if [[ ${1:-} == report ]]; then
  if ! command -v ccusage >/dev/null 2>&1; then
    echo "ccusage is not installed (AUR; sudo ~/dotfiles/apply-system.sh --only install)"; read -rn1 _; exit 0
  fi
  ccusage "${2:-daily}"; echo; read -rn1 -p 'press a key' _; exit 0
fi

rel() { # epoch seconds -> "in 2d 3h" / "in 45m"
  local d=$(($1 - $(date +%s)))
  ((d <= 0)) && { echo "reset due"; return; }
  if ((d >= 86400)); then echo "in $((d / 86400))d $((d % 86400 / 3600))h"
  elif ((d >= 3600)); then echo "in $((d / 3600))h $((d % 3600 / 60))m"
  else echo "in $((d / 60))m"; fi
}
wname() { case $1 in 300) echo "5h" ;; 10080) echo "weekly" ;; 1440) echo "daily" ;; *) echo "${1}m" ;; esac; }

# ── Codex: 5h and weekly windows (by window_minutes), plan ─────────────────────
# The freshest observation wins. A plan can report only one window (prolite: just the weekly one), the other stays empty.
cx_plan="" cx_5="" cx_5r="" cx_7="" cx_7r="" cx_t=0
CX_JQ='def win: select(. != null) | {p: .used_percent, w: .window_minutes, r: (.resets_at | if type == "string" then (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601? // 0) else (. // 0) end)};'
cx_cands() {
  [[ -r $CODEX_JSON ]] && jq -c "$CX_JQ"'
    [.entries[]? | select(.body != null) | {t: (.observed_at // ""), b: (.body | sub("^SSE event: "; "") | fromjson?)}]
    | map(select(.b.rate_limits.primary != null or .b.rate_limits.secondary != null)) | sort_by(.t) | last
    | select(. != null) | {t: (.t | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601? // 0), plan: (.b.plan_type // ""), wins: [.b.rate_limits.primary, .b.rate_limits.secondary | win]}' "$CODEX_JSON" 2>/dev/null
  local f
  for f in "$CODEX_DIR"/*.json; do
    [[ -r $f ]] || continue
    jq -c "$CX_JQ"'select(.limits != null) | {t: ((.observedAt // 0) / 1000 | floor), plan: (.limits.plan_type // ""), wins: [.limits.primary, .limits.secondary | win]}' "$f" 2>/dev/null
  done
}
rec=$(cx_cands | jq -sc 'map(select(. != null and (.wins | length) > 0)) | if length == 0 then empty else max_by(.t) end' 2>/dev/null)
if [[ -n $rec ]]; then
  IFS='|' read -r cx_t cx_plan cx_5 cx_5r cx_7 cx_7r < <(jq -r 'def pick(f): ([.wins[] | select(.w != null and (.w | f))][0] // {}) | [.p, .r] | map(. // "") | join("|");
      [.t, .plan, pick(. <= 300), pick(. >= 10080)] | join("|")' <<<"$rec")
fi
now=$(date +%s)
cx_pc() { # pct, reset epoch -> pct, 0 once the window has reset, empty when unknown
  [[ $1 =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo; return; }
  if [[ ${2:-} =~ ^[0-9]+$ ]] && ((${2} > 0 && ${2} < now)); then echo 0; else printf '%.0f\n' "$1"; fi
}
cx_5=$(cx_pc "$cx_5" "$cx_5r") cx_7=$(cx_pc "$cx_7" "$cx_7r")

# ── Claude: statusline cache(s) (rate_limits), ccusage for the cost line ───────
# claude.json (written by --record-claude) and statusline.json (raw statusline JSON, `tee`d); the newer file wins.
cl_5="" cl_7="" cl_5r="" cl_7r="" cl_cost="" cl_tok="" cl_best=0
for f in "$CLAUDE_CACHE" "$CLAUDE_RAW"; do
  [[ -r $f ]] || continue
  m=$(stat -c %Y "$f" 2>/dev/null || echo 0)
  ((m > cl_best)) || continue
  rec=$(jq -r '(.rate_limits // .) | [(.five_hour.used_percentage // ""), (.five_hour.resets_at // ""), (.seven_day.used_percentage // ""), (.seven_day.resets_at // "")] | @tsv' "$f" 2>/dev/null) || continue
  IFS=$'\t' read -r p5 r5 p7 r7 <<<"$rec"
  [[ $p5 =~ ^[0-9.]+$ || $p7 =~ ^[0-9.]+$ ]] || continue
  cl_best=$m cl_5=$p5 cl_5r=$r5 cl_7=$p7 cl_7r=$r7
done
# a window without a known reset is trusted for 6 h at most; one that has reset counts as 0
cl_pc() { # pct, reset epoch -> pct / 0 / empty
  [[ $1 =~ ^[0-9.]+$ ]] || { echo; return; }
  if [[ ${2:-} =~ ^[0-9]+$ ]]; then
    ((${2} < now)) && { echo 0; return; }
  elif ((now - cl_best > 21600)); then echo; return; fi
  printf '%.0f\n' "$1"
}
cl_5=$(cl_pc "$cl_5" "$cl_5r") cl_7=$(cl_pc "$cl_7" "$cl_7r")
if command -v ccusage >/dev/null 2>&1; then
  mkdir -p "$RUN"
  if [[ ! -s $CCU_CACHE ]] || (($(date +%s) - $(stat -c %Y "$CCU_CACHE") > 300)); then
    # refresh in the background; the next poll sees it
    (flock -n 9 || exit 0; ccusage daily --json --offline --since "$(date +%Y%m%d)" >"$CCU_CACHE.tmp" 2>/dev/null && mv -f "$CCU_CACHE.tmp" "$CCU_CACHE") 9>"$RUN/ccusage.lock" &
    disown 2>/dev/null || true
  fi
  if [[ -s $CCU_CACHE ]]; then
    IFS=$'\t' read -r cl_cost cl_tok < <(jq -r '[ (.. | objects | select(has("totalCost")) | .totalCost) ] | last as $c | [ (.. | objects | select(has("totalTokens")) | .totalTokens) ] | last as $t | [($c // ""), ($t // "")] | @tsv' "$CCU_CACHE" 2>/dev/null)
  fi
fi

# ── text, class, tooltip ────────────────────────────────────────────────────────
# bar text: "󰚩 C 26·4  X –·100" = Claude 5h·weekly, Codex 5h·weekly, % used, "–" = no data. The class is always normal.
v() { echo "${1:-–}"; }
printf -v text '%s C %s·%s  X %s·%s' "$G_AI" "$(v "$cl_5")" "$(v "$cl_7")" "$(v "$cx_5")" "$(v "$cx_7")"
line() { # label pct reset-epoch [why when empty]
  if [[ -n $2 ]]; then
    local r=""
    if [[ -n ${3:-} ]]; then
      if ((${3} < now)); then r=" (window reset, no use since)"; else r=" (resets $(rel "$3"))"; fi
    fi
    echo "$1 ${2}%$r"
  else echo "$1 –  (${4:-no data})"; fi
}
cl_why="no rate_limits yet: Claude Code statusline is not piped into ai-usage.sh"
tip=("AI usage, % used: 5h · weekly   (C Claude, X Codex, – no data)" ""
  "$(line 'Claude 5h:    ' "$cl_5" "$cl_5r" "$cl_why")"
  "$(line 'Claude weekly:' "$cl_7" "$cl_7r" "$cl_why")")
[[ -n $cl_cost ]] && tip+=("Claude today (ccusage): \$$(printf '%.2f' "$cl_cost")${cl_tok:+, $((cl_tok / 1000))k tokens}")
tip+=("")
if [[ -n $cx_plan || $cx_t != 0 ]]; then cx_why="this plan reports no 5h window"; else cx_why="no ~/.codex/codex-hud usage cache yet"; fi
tip+=("$(line 'Codex 5h:    ' "$cx_5" "$cx_5r" "$cx_why")"
  "$(line 'Codex weekly:' "$cx_7" "$cx_7r" "${cx_why/this plan reports no 5h window/no weekly window reported}")")
[[ -n $cx_plan ]] && tip+=("Codex plan: $cx_plan")
tip+=("" "L: ccusage daily · R: 5h blocks")

printf '%s\n' "${tip[@]}" | jq -Rs --arg t "$text" '{text: $t, class: "normal", tooltip: (rtrimstr("\n"))}' | jq -c .
