#!/usr/bin/env bash
# ai-usage: waybar custom/ai. Quiet when no data is available.
#   ai-usage.sh                  JSON: "C 23% X 41%" + tooltip with windows, resets and today's ccusage numbers
#   ai-usage.sh report daily     float.tui report (ccusage daily), also `blocks`
#   ai-usage.sh --record-claude  read the Claude Code statusline JSON on stdin and cache rate_limits (see below)
#
# Sources (all local, no network):
#   Codex   ~/.codex/codex-hud/account-usage.json (codex-hud cache, `codex.rate_limits` SSE event) or the newer
#           ~/.codex/codex-hud/account-usage/*.json; used_percent, window_minutes, resets_at
#   Claude  ~/.cache/ai-usage/claude.json {five_hour:{used_percentage,resets_at},seven_day:{...},saved_at}, written by
#           `ai-usage.sh --record-claude` when it is piped the statusline JSON, e.g. a statusline command
#           `tee >(~/.config/waybar/scripts/ai-usage.sh --record-claude) | <existing statusline command>`.
#           Claude Code settings are not edited by this repo, so until that is wired in Claude falls back to ccusage
#           (today's tokens and cost, cached 5 min); with neither, the Claude part is omitted.
set -u
CODEX_JSON="$HOME/.codex/codex-hud/account-usage.json"
CODEX_DIR="$HOME/.codex/codex-hud/account-usage"
CLAUDE_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/ai-usage/claude.json"
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

# ── Codex: pct, window minutes, reset epoch, plan ───────────────────────────────
cx_pct="" cx_win="" cx_reset="" cx_plan="" cx_sec=""
best=0
if [[ -r $CODEX_JSON ]]; then
  rec=$(jq -r '[.entries[]? | select(.body != null) | {t: (.observed_at // ""), b: (.body | sub("^SSE event: "; "") | fromjson? )}]
        | map(select(.b.rate_limits.primary != null)) | sort_by(.t) | last
        | if . == null then empty else [(.t | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601? // 0), .b.rate_limits.primary.used_percent, .b.rate_limits.primary.window_minutes, (.b.rate_limits.primary.resets_at | if type == "string" then (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601? // 0) else . end), (.b.plan_type // ""), (.b.rate_limits.secondary.used_percent // "")] | @tsv end' "$CODEX_JSON" 2>/dev/null)
  if [[ -n $rec ]]; then
    IFS=$'\t' read -r best cx_pct cx_win cx_reset cx_plan cx_sec <<<"$rec"
  fi
fi
if [[ -d $CODEX_DIR ]]; then
  for f in "$CODEX_DIR"/*.json; do
    [[ -r $f ]] || continue
    rec=$(jq -r 'select(.limits.primary != null) | [((.observedAt // 0) / 1000 | floor), .limits.primary.used_percent, .limits.primary.window_minutes, .limits.primary.resets_at, (.limits.plan_type // ""), (.limits.secondary.used_percent // "")] | @tsv' "$f" 2>/dev/null)
    [[ -n $rec ]] || continue
    IFS=$'\t' read -r t p w r pl sc <<<"$rec"
    if ((t > best)); then best=$t cx_pct=$p cx_win=$w cx_reset=$r cx_plan=$pl cx_sec=$sc; fi
  done
fi
# a window that already reset is stale: the percentage is no longer valid
if [[ -n $cx_reset && $cx_reset =~ ^[0-9]+$ ]] && ((cx_reset > 0 && cx_reset < $(date +%s))); then cx_pct="0"; fi
[[ $cx_pct =~ ^[0-9]+(\.[0-9]+)?$ ]] || cx_pct=""
[[ -n $cx_pct ]] && cx_pct=$(printf '%.0f' "$cx_pct")

# ── Claude: statusline cache, else ccusage ──────────────────────────────────────
cl_5="" cl_7="" cl_5r="" cl_7r="" cl_cost="" cl_tok=""
if [[ -r $CLAUDE_CACHE ]] && (($(date +%s) - $(jq -r '.saved_at // 0' "$CLAUDE_CACHE" 2>/dev/null || echo 0) < 21600)); then
  IFS=$'\t' read -r cl_5 cl_5r cl_7 cl_7r < <(jq -r '[(.five_hour.used_percentage // ""), (.five_hour.resets_at // ""), (.seven_day.used_percentage // ""), (.seven_day.resets_at // "")] | @tsv' "$CLAUDE_CACHE" 2>/dev/null)
  [[ $cl_5 =~ ^[0-9.]+$ ]] && cl_5=$(printf '%.0f' "$cl_5") || cl_5=""
  [[ $cl_7 =~ ^[0-9.]+$ ]] && cl_7=$(printf '%.0f' "$cl_7") || cl_7=""
fi
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
parts=() tip=() maxp=0
if [[ -n $cl_5 ]]; then
  parts+=("C ${cl_5}%"); ((cl_5 > maxp)) && maxp=$cl_5
  tip+=("Claude 5h: ${cl_5}%${cl_5r:+ (resets $(rel "$cl_5r"))}")
  [[ -n $cl_7 ]] && { tip+=("Claude 7d: ${cl_7}%${cl_7r:+ (resets $(rel "$cl_7r"))}"); ((cl_7 > maxp)) && maxp=$cl_7; }
elif [[ -n $cl_cost ]]; then
  parts+=("C \$$(printf '%.1f' "$cl_cost")")
fi
[[ -n $cl_cost ]] && tip+=("Claude today (ccusage): \$$(printf '%.2f' "$cl_cost")${cl_tok:+, $((cl_tok / 1000))k tokens}")
if [[ -n $cx_pct ]]; then
  parts+=("X ${cx_pct}%"); ((cx_pct > maxp)) && maxp=$cx_pct
  tip+=("Codex ${cx_win:+$(wname "$cx_win") }window: ${cx_pct}%${cx_reset:+ (resets $(rel "$cx_reset"))}${cx_plan:+, plan $cx_plan}")
  [[ -n $cx_sec ]] && tip+=("Codex secondary: ${cx_sec}%")
fi
if ((${#parts[@]} == 0)); then echo '{"text":""}'; exit 0; fi

class=ok
if ((maxp >= 90)); then class=critical; elif ((maxp >= 75)); then class=warning; fi
text="$G_AI ${parts[*]}"
tip+=("" "click: ccusage daily, right click: 5h blocks")

# one alert when a window crosses 90 %
mkdir -p "$RUN"
if ((maxp >= 90)); then
  if [[ ! -e $RUN/alerted ]]; then touch "$RUN/alerted"; notify-send -a ai-usage -u critical "AI usage at ${maxp}%" "${parts[*]}" 2>/dev/null || true; fi
else
  rm -f "$RUN/alerted"
fi
printf '%s\n' "${tip[@]}" | jq -Rs --arg t "$text" --arg c "$class" '{text: $t, class: $c, tooltip: (rtrimstr("\n"))}' | jq -c .
