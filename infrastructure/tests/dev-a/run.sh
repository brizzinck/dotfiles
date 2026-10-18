#!/usr/bin/env bash
# Offline tests of stage DEV-a (shell and git conveniences). Everything runs against fakes in a scratch directory and private
# tmux servers (-L); nothing of the live session is touched (no notification, no dispatch, no clipboard, no real history).
#
#   run.sh [--quick]    --quick = what doctor runs: sections 1-3, the non-tmux parts of 4 and section 5 (about 3 s)
#   ONLY=1,3 run.sh     only those sections (1 gitleaks hook, 2 atuin, 3 carapace + fzf-tab, 4 cmd-notify, 5 overhead)
#   DEV_A_REAL=1        also smoke-test the real atuin / carapace / difft binaries found on PATH (scratch XDG dirs)
#
# 1 pre-commit + pre-push hooks: scratch repo (and a bare remote) with the hooks and .gitleaks.toml of this repo; the push cases are
#   --no-verify, merge, cherry-pick, rebase, am, an evil merge, a broad working-tree allowlist, fail closed (skipped without gitleaks)
# 2 atuin: recording hook (fake atuin logs its argv), the secret-command table, history_filter + prune (real atuin when on PATH), rows / filter cycling / preview of fzf/atuin-history.sh, and the Ctrl+R
#   list in a private tmux (full run only)
# 3 carapace: cache build, lookup table, `-default-` fallback next to untouched native completions; fzf-tab zstyles
# 4 cmd-notify: worker with a fake hyprctl / notify-send / hyprd and a private tmux (also two windows of one process and a nested
#   tmux), zsh side with a fake worker (ignore list through aliases and wrappers)
# 5 hook overhead: 1000 x preexec + precmd with an instant fake atuin, average must stay under 1 ms
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
QUICK=0
for a in "$@"; do case $a in --quick) QUICK=1 ;; *) echo "usage: run.sh [--quick]" >&2; exit 2 ;; esac; done
T=$(mktemp -d)
SOCK="dev-a-test-$$"
cleanup() {
  tmux -L "$SOCK" kill-server 2>/dev/null
  tmux -L "$SOCK-b" kill-server 2>/dev/null
  pkill -f "tmux -L $SOCK" 2>/dev/null
  rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SOCK" "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SOCK-b"   # kill-server leaves the socket files behind
  [[ -n ${T:-} && -d $T ]] && rm -rf -- "$T"
}
trap cleanup EXIT
passed=0 fails=0
pass() { printf 'PASS  %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
expect() { local n=$1; shift; if "$@" >/dev/null 2>&1; then pass "$n"; else fail "$n"; fi; }
# a fake secret assembled at run time: the literal next to a token keyword would trip the pre-commit hook on this file
FAKE_SECRET="abcdef""123456"
want() { [[ -z ${ONLY:-} || ,$ONLY, == *",$1,"* ]]; }   # want N: section N selected
have() { command -v "$1" >/dev/null 2>&1; }
eq() { local n=$1 got=$2 exp=$3; if [[ $got == "$exp" ]]; then pass "$n"; else fail "$n (got: $got | expected: $exp)"; fi; }

REAL_HOME=$HOME
mkdir -p "$T/bin" "$T/home" "$T/cfg" "$T/data" "$T/state" "$T/cache" "$T/run"
chmod 700 "$T/run"
export HOME="$T/home" XDG_CONFIG_HOME="$T/cfg" XDG_DATA_HOME="$T/data" XDG_STATE_HOME="$T/state" XDG_CACHE_HOME="$T/cache" XDG_RUNTIME_DIR="$T/run"
unset CLAUDECODE TMUX TMUX_PANE SSH_CONNECTION HYPRLAND_INSTANCE_SIGNATURE ATUIN_SESSION
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
ln -s "$REPO/.config/zsh" "$T/cfg/zsh"; ln -s "$REPO/.config/fzf" "$T/cfg/fzf"; ln -s "$REPO/.config/layout" "$T/cfg/layout"
real_path=$PATH

# a zsh file without its "interactive with zle" guard line, so it can be sourced by `zsh -f` in a script
unguard() { grep -v '^\[\[ -o zle' "$1" >"$2"; }

# ── 1 gitleaks pre-commit hook ───────────────────────────────────────────────────────────────────────────────
s1() {
  have gitleaks && have git || { echo "SKIP  section 1 (gitleaks or git missing)"; return; }
  local r="$T/leak" tok1 tok2 out
  # fake tokens built at run time: this file itself must not look like a leak to the hook that scans it
  tok1="ghp_$(printf '%s' 'aB3dE5gH7jK9mN1pQ3sT5vW7yZ9bC1dE3fG5')"
  tok2="ghp_$(printf '%s' 'Zq8wE5gH7jK9mN1pQ3sT5vW7yZ9bC1dE3fG5')"
  mkdir -p "$r/.githooks" && git -C "$r" init -q && git -C "$r" config user.email t@t && git -C "$r" config user.name t
  git -C "$r" config core.hooksPath .githooks
  cp "$REPO/.githooks/pre-commit" "$REPO/.githooks/gitleaks-lib" "$r/.githooks/"; cp "$REPO/.gitleaks.toml" "$r/.gitleaks.toml"
  expect "hook is executable" test -x "$REPO/.githooks/pre-commit"
  expect "pre-push hook is executable" test -x "$REPO/.githooks/pre-push"
  expect "the docs do not call --no-verify the only bypass (merge, rebase, cherry-pick, am and edited hooks skip pre-commit too)" bash -c "! grep -q 'The only bypass is' '$REPO/CLAUDE.md' '$REPO/.githooks/pre-commit'"
  expect "the docs name GitHub push protection as the backstop" grep -q 'push protection' "$REPO/CLAUDE.md"
  git -C "$r" add .githooks/pre-commit .gitleaks.toml
  expect "first commit of the config passes (working-tree config)" git -C "$r" commit -q -m cfg
  printf 'token = "%s"\n' "$tok1" >"$r/f1.txt"; git -C "$r" add f1.txt
  out=$(git -C "$r" commit -q -m f1 2>&1); local rc=$?
  eq "a staged leak blocks the commit" "$rc" 1
  [[ $out == *REDACTED* && $out != *"${tok1:4}"* ]] && pass "the finding is redacted" || fail "the finding is redacted"
  [[ $out == *"git commit --no-verify"* ]] && pass "the block explains the bypass" || fail "the block explains the bypass"
  git -C "$r" restore --staged f1.txt; rm -f "$r/f1.txt"
  printf 'clean\n' >"$r/c.txt"; git -C "$r" add c.txt
  local t0=$EPOCHREALTIME
  expect "a clean change passes" git -C "$r" commit -q -m clean
  local ms=$(( (${EPOCHREALTIME/./} - ${t0/./}) / 1000 ))
  ((ms < 500)) && pass "commit with the hook takes ${ms} ms (< 500)" || fail "commit with the hook takes ${ms} ms"
  : >"$r/.gitleaksignore"; printf 'y\n' >"$r/b.txt"; git -C "$r" add b.txt
  expect ".gitleaksignore blocks" bash -c "! git -C '$r' commit -q -m b"
  rm -f "$r/.gitleaksignore"; git -C "$r" restore --staged b.txt; rm -f "$r/b.txt"
  printf 'token = "%s" # gitleaks:allow\n' "$tok1" >"$r/f2.txt"; git -C "$r" add f2.txt
  expect "a gitleaks:allow comment does not help" bash -c "! git -C '$r' commit -q -m f2"
  git -C "$r" restore --staged f2.txt; rm -f "$r/f2.txt"
  printf '\n[[allowlists]]\nregexTarget = "secret"\nregexes = [ %s ]\n' "'''^$tok1\$'''" >>"$r/.gitleaks.toml"
  printf 'token = "%s"\n' "$tok1" >"$r/f3.txt"; git -C "$r" add .gitleaks.toml f3.txt
  expect "an allowlist entry and its value in one commit is blocked" bash -c "! git -C '$r' commit -q -m f3"
  git -C "$r" restore --staged f3.txt
  expect "the config alone passes" git -C "$r" commit -q -m allow
  git -C "$r" add f3.txt
  expect "the value passes once its allowlist entry is committed" git -C "$r" commit -q -m f3
  printf 'token = "%s"\n' "$tok2" >"$r/f4.txt"; git -C "$r" add f4.txt
  expect "--no-verify bypasses" git -C "$r" commit -q --no-verify -m nv
  git -C "$r" worktree add -q "$T/leak-wt" -b wt 2>/dev/null
  printf 'token = "%s"\n' "${tok2/Zq8/Zq9}" >"$T/leak-wt/w.txt"; git -C "$T/leak-wt" add w.txt
  expect "the hook also runs in a linked worktree" bash -c "! git -C '$T/leak-wt' commit -q -m w"
  # fail closed: no gitleaks on PATH
  printf 'more\n' >"$r/d.txt"; git -C "$r" add d.txt
  mkdir -p "$T/nogl"; local c
  for c in git bash env readlink dirname mktemp rm cat head; do ln -sf "$(command -v $c)" "$T/nogl/$c"; done
  out=$(PATH="$T/nogl" git -C "$r" commit -q -m nogl 2>&1)
  [[ $out == *"gitleaks is not installed"* ]] && pass "missing gitleaks blocks the commit (fail closed)" || fail "missing gitleaks blocks the commit (fail closed): $out"
  expect "the committed allowlist covers the known false positives" bash -c "cd '$REPO' && gitleaks git --no-banner --redact -l error --exit-code 3 -c .gitleaks.toml . >/dev/null 2>&1"
  expect ".gitleaks.toml extends the default rules" grep -q '^useDefault = true' "$REPO/.gitleaks.toml"
  expect ".gitleaks.toml is not stowed" grep -q 'gitleaks' "$REPO/.stow-local-ignore"
  s1_push
  s1_lint
}

# doctor `gitleaks-history` helpers in .githooks/gitleaks-lib: the committed config is linted and used for the history scan
s1_lint() {
  local c="$T/lint.toml" r="$T/lint-repo" out tok rc
  mk() { printf '%s\n' 'title = "x"' '[extend]' 'useDefault = true' '[[allowlists]]' 'regexTarget = "secret"' "$@" >"$c"; }
  lint() { bash -c ". '$REPO/.githooks/gitleaks-lib'; gl_cfg_problems '$1'"; }
  eq "L6: the repo's committed .gitleaks.toml has no broad allowlist" "$(bash -c ". '$REPO/.githooks/gitleaks-lib'; gl_committed_cfg_problems '$REPO'")" ""
  mk "regexes = ['''^abc123\$''']"; eq "L6: an exact value regex is fine" "$(lint "$c")" ""
  mk "paths = ['''^docs/''']"; [[ $(lint "$c") == *"paths allowlist"* ]] && pass "L6: a paths allowlist is flagged" || fail "L6 paths"
  mk "regexes = ['''.*''']"; [[ $(lint "$c") == *"catch-all"* ]] && pass "L6: a catch-all regex .* is flagged" || fail "L6 .*"
  mk "regexes = [ '''^.+\$''' ]"; [[ $(lint "$c") == *"catch-all"* ]] && pass "L6: ^.+\$ is flagged" || fail "L6 .+"
  mk 'regexes = [ "\\S+" ]'; [[ $(lint "$c") == *"catch-all"* ]] && pass "L6: \\S+ is flagged" || fail "L6 S+"
  mk "commits = ['abc']"; [[ $(lint "$c") == *"commits"* ]] && pass "L6: a commits allowlist is flagged" || fail "L6 commits"
  printf 'title = "x"\n[extend]\nuseDefault = false\n' >"$c"; [[ $(lint "$c") == *"default rules"* ]] && pass "L6: useDefault = false is flagged" || fail "L6 useDefault"
  # a committed config, a leak, and an UNCOMMITTED catch-all allowlist in the working file
  tok="ghp_$(printf '%s' 'Wq8wE5gH7jK9mN1pQ3sT5vW7yZ9bC1dE3fG5')"
  mkdir -p "$r" && git init -q -b main "$r" && git -C "$r" config user.email t@t && git -C "$r" config user.name t && git -C "$r" config commit.gpgsign false
  cp "$REPO/.gitleaks.toml" "$r/.gitleaks.toml"; printf 'token = "%s"\n' "$tok" >"$r/leak.txt"
  git -C "$r" add .gitleaks.toml leak.txt; git -C "$r" commit -q --no-verify -m leak
  printf '\n[[allowlists]]\nregexTarget = "secret"\nregexes = [ %s ]\n' "'''.*'''" >>"$r/.gitleaks.toml"
  bash -c "cd '$r' && gitleaks git --no-banner --redact -l error --exit-code 3 -c .gitleaks.toml . >/dev/null 2>&1"; eq "L6: (control) the old doctor call with the working file is silenced by the uncommitted allowlist" "$?" 0
  out=$(bash -c ". '$REPO/.githooks/gitleaks-lib'; gl_history_scan '$r'"); rc=$?; eq "L6: gl_history_scan (committed config) still finds the leak" "$rc" 3
  [[ $out != *"${tok:4}"* ]] && pass "L6: the scan output never holds the value" || fail "L6 redaction"
  git -C "$r" checkout -q -- .gitleaks.toml
  git -C "$r" rm -q --cached leak.txt; git -C "$r" commit -q --no-verify -m rm
  out=$(bash -c ". '$REPO/.githooks/gitleaks-lib'; gl_history_scan '$r'"); rc=$?; eq "L6: the history still holds the leak after a delete commit" "$rc" 3
}

# the pre-push hook: commits that never ran pre-commit (--no-verify, merge, cherry-pick, rebase, am, an evil merge) are caught
# when they are pushed. Scratch repo + bare remote.
s1_push() {
  local r="$T/pp" rem="$T/pp-remote.git" out rc t n=0 c
  tok_new() { n=$((n + 1)); printf 'ghp_%s%02d' 'Kq8wE5gH7jK9mN1pQ3sT5vW7yZ9bC1dE3f' "$n"; }
  git init -q --bare -b main "$rem"
  mkdir -p "$r/.githooks" && git init -q -b main "$r" && git -C "$r" config user.email t@t && git -C "$r" config user.name t
  git -C "$r" config commit.gpgsign false; git -C "$r" config core.hooksPath .githooks; git -C "$r" remote add origin "$rem"
  cp "$REPO/.githooks/pre-commit" "$REPO/.githooks/pre-push" "$REPO/.githooks/gitleaks-lib" "$r/.githooks/"; cp "$REPO/.gitleaks.toml" "$r/.gitleaks.toml"
  git -C "$r" add .githooks .gitleaks.toml; git -C "$r" commit -q -m base
  expect "pre-push: a clean first push (whole history) passes" git -C "$r" push -q -u origin main
  # back to the remote state, side branches dropped
  s1_reset() {
    git -C "$r" merge --abort 2>/dev/null; git -C "$r" rebase --abort 2>/dev/null; git -C "$r" cherry-pick --abort 2>/dev/null; git -C "$r" am --abort 2>/dev/null
    git -C "$r" checkout -q -f main; git -C "$r" reset -q --hard origin/main; git -C "$r" clean -qfd
    for c in $(git -C "$r" for-each-ref --format='%(refname:short)' refs/heads/ | grep -v '^main$'); do git -C "$r" branch -q -D "$c"; done
  }
  # a commit that skips pre-commit
  nv_commit() { t=$(tok_new); printf 'token = "%s"\n' "$t" >"$r/$1"; git -C "$r" add "$1"; git -C "$r" commit -q --no-verify -m "$1"; }
  push_blocked() { # NAME REFSPEC
    out=$(git -C "$r" push origin "$2" 2>&1); rc=$?
    if ((rc != 0)) && [[ $out == *"pre-push: gitleaks found possible secrets"* && $out == *REDACTED* && $out != *"${t:4}"* ]]; then
      pass "pre-push blocks: $1"
    else fail "pre-push blocks: $1 (rc=$rc) $out"; fi
    if [[ $2 != main ]] && git -C "$r" ls-remote --exit-code origin "refs/heads/$2" >/dev/null 2>&1; then fail "pre-push: $1 reached the remote"; fi
    return 0
  }
  git -C "$r" checkout -q -b side; nv_commit f-side.txt
  push_blocked "a --no-verify commit on a new branch" side
  git -C "$r" checkout -q main; git -C "$r" merge -q --no-ff -m merge side >/dev/null
  expect "(the merge landed on main without any hook)" bash -c "git -C '$r' log --format=%s -3 | grep -q f-side.txt"
  push_blocked "a merge of a --no-verify branch" main
  s1_reset
  git -C "$r" checkout -q -b side2; nv_commit f-cp.txt; git -C "$r" checkout -q main; git -C "$r" cherry-pick side2 >/dev/null 2>&1
  expect "(the cherry-pick landed without a hook)" bash -c "git -C '$r' log --format=%s -1 | grep -q f-cp.txt"
  push_blocked "a cherry-pick" main
  s1_reset
  git -C "$r" checkout -q -b side3; nv_commit f-rb.txt; git -C "$r" checkout -q main
  printf 'm\n' >"$r/m.txt"; git -C "$r" add m.txt; git -C "$r" commit -q -m m
  git -C "$r" checkout -q side3; git -C "$r" rebase -q main >/dev/null 2>&1
  push_blocked "a rebased --no-verify branch" side3
  s1_reset
  git -C "$r" checkout -q -b side4; nv_commit f-am.txt; git -C "$r" format-patch -q -1 -o "$T/pp-patch" >/dev/null; git -C "$r" checkout -q main
  git -C "$r" am -q "$T/pp-patch"/*.patch >/dev/null 2>&1
  expect "(git am landed without pre-commit)" bash -c "git -C '$r' log --format=%s -1 | grep -q f-am.txt"
  push_blocked "git am" main
  rm -rf "$T/pp-patch"; s1_reset
  git -C "$r" checkout -q -b side5; printf 'x\n' >"$r/x5.txt"; git -C "$r" add x5.txt; git -C "$r" commit -q -m x5
  git -C "$r" checkout -q main; printf 'm\n' >"$r/m5.txt"; git -C "$r" add m5.txt; git -C "$r" commit -q -m m5
  git -C "$r" merge -q --no-ff --no-commit side5 >/dev/null 2>&1
  t=$(tok_new); printf 'token = "%s"\n' "$t" >"$r/evil.txt"; git -C "$r" add evil.txt; git -C "$r" commit -q --no-verify -m "evil merge"
  push_blocked "a merge commit that adds a secret of its own (checked against every parent)" main
  s1_reset
  # an uncommitted broad allowlist does not silence the scan (the committed config is used)
  git -C "$r" checkout -q -b side6; nv_commit f-al.txt
  printf '\n[[allowlists]]\nregexTarget = "secret"\nregexes = [ %s ]\n' "'''^ghp_.*'''" >>"$r/.gitleaks.toml"
  push_blocked "a secret while the working-tree .gitleaks.toml allowlists it (only the committed one counts)" side6
  git -C "$r" checkout -q -- .gitleaks.toml
  # fail closed, then the documented bypass
  mkdir -p "$T/nogl2"; for c in git bash env readlink dirname mktemp rm cat head sed; do ln -sf "$(command -v $c)" "$T/nogl2/$c"; done
  out=$(PATH="$T/nogl2" git -C "$r" push origin side6 2>&1); rc=$?
  ((rc != 0)) && [[ $out == *"gitleaks is not installed"* ]] && pass "pre-push: missing gitleaks blocks the push (fail closed)" || fail "pre-push fail closed (rc=$rc): $out"
  out=$(git -C "$r" push --no-verify origin side6 2>&1); rc=$?
  ((rc == 0)) && pass "pre-push: --no-verify is the documented bypass" || fail "pre-push --no-verify: $out"
  expect "pre-push: deleting a remote branch sends no commits and passes" git -C "$r" push -q origin --delete side6
  s1_reset
  git -C "$r" checkout -q -b clean1; printf 'ok\n' >"$r/ok.txt"; git -C "$r" add ok.txt; git -C "$r" commit -q -m ok
  expect "pre-push: a clean new branch passes" git -C "$r" push -q origin clean1
  printf 'ok2\n' >"$r/ok2.txt"; git -C "$r" add ok2.txt; git -C "$r" commit -q -m ok2
  expect "pre-push: a clean fast-forward passes" git -C "$r" push -q origin clean1
  s1_reset
}

# ── 2 atuin ──────────────────────────────────────────────────────────────────────────────────────────────────
make_fake_atuin() { # FILE
  cat >"$1" <<'EOF'
#!/bin/sh
# fake atuin: logs "cwd|argv" and answers the three calls the dotfiles make
printf '%s|%s\n' "$PWD" "$*" >>"${FAKE_LOG:-/dev/null}"
case "$1 $2" in
  "history start") echo 0123456789abcdef0123456789abcdef; [ -n "${FAKE_SLEEP:-}" ] && sleep "$FAKE_SLEEP" ;;
esac
case "$1" in
  search) printf '1\t2s\t5m\t/etc\tfalse\0' ; printf '0\t10ms\t9m\t/tmp\tprintf a\nprintf b\0'; printf '0\t1s\t1h\t/usr\tls -l /usr\0' ;;
esac
exit 0
EOF
  chmod +x "$1"
}

s2() {
  have zsh || { echo "SKIP  section 2 (zsh missing)"; return; }
  make_fake_atuin "$T/bin/atuin"
  local log="$T/atuin.log" sh="$REPO/.config/fzf/atuin-history.sh"
  unguard "$REPO/.config/zsh/cmd-hooks.zsh" "$T/hooks.zsh"

  # recording: preexec / precmd the way zsh calls them
  : >"$log"
  FAKE_SECRET=$FAKE_SECRET FAKE_LOG=$log PATH="$T/bin:$real_path" zsh -f -c '
    source '"$T"'/hooks.zsh
    cd /tmp
    _df_cmd_preexec "echo a"; _df_cmd_precmd
    _df_cmd_preexec "false"; false; _df_cmd_precmd
    _df_cmd_preexec " echo hidden"; _df_cmd_precmd
    _df_cmd_preexec "export API_TOKEN=$FAKE_SECRET"; _df_cmd_precmd
    _df_cmd_preexec "export TOKEN=\$(rbw get x)"; _df_cmd_precmd
    _df_cmd_preexec "export PLAINVAR=literalvalue"; _df_cmd_precmd
    _df_cmd_preexec "typeset -x OTHERVAR=literalvalue"; _df_cmd_precmd
    _df_cmd_preexec "BARELINE=literalvalue"; _df_cmd_precmd
    _df_cmd_preexec "GOOS=linux go build ./..."; _df_cmd_precmd
    _df_cmd_preexec "export PATH=\$PATH:/x"; _df_cmd_precmd
    sleep 0.25' >/dev/null 2>&1
  expect "a plain command is recorded (history start)" grep -q '^/tmp|history start --hook -- echo a$' "$log"
  expect "the start runs in the command's directory" grep -q '^/tmp|history start' "$log"
  expect "history end carries the exit status 1" grep -q 'history end --hook --exit 1 --duration=[0-9]* -- 0123456789abcdef0123456789abcdef' "$log"
  expect "history end of a success has exit 0" grep -q 'history end --hook --exit 0 --duration=' "$log"
  expect "a command with a leading space is not recorded" bash -c "! grep -q 'echo hidden' '$log'"
  expect "a literal secret is not recorded" bash -c "! grep -q 'abcdef123456' '$log'"
  expect "a variable reference is recorded" grep -q 'rbw get x' "$log"
  expect "L1: an assignment with a literal value (export, typeset, bare) never reaches the argv of atuin" bash -c "! grep -q -e PLAINVAR -e OTHERVAR -e BARELINE '$log'"
  expect "L1: a command with an environment prefix is still recorded" grep -q 'GOOS=linux go build' "$log"
  expect "L1: an assignment that only uses a variable is still recorded" grep -q 'export PATH=\$PATH:/x' "$log"
  s2_secrets

  # the recording job is in the background: precmd returns long before a slow atuin finishes
  : >"$log"
  local t0 t1
  t0=$(date +%s%N)
  FAKE_SLEEP=2 FAKE_LOG=$log PATH="$T/bin:$real_path" zsh -f -c 'source '"$T"'/hooks.zsh; _df_cmd_preexec "echo slow"; _df_cmd_precmd' >/dev/null 2>&1
  t1=$(date +%s%N)
  (( (t1 - t0) / 1000000 < 1000 )) && pass "precmd does not wait for atuin ($(( (t1 - t0) / 1000000 )) ms with a 2 s atuin)" || fail "precmd waited for atuin"

  # rows / cycle / header / preview (the Ctrl+R list feeders)
  export ATUIN_BIN="$T/bin/atuin" FAKE_LOG=$log DF_ATUIN_STATE="$T/atuin-state"
  rm -f "$DF_ATUIN_STATE"; : >"$log"
  local plain="$T/plain" repo="$T/gitdir" out
  mkdir -p "$plain" "$repo"; git -C "$repo" init -q 2>/dev/null
  out=$(cd "$plain" && bash "$sh" rows | tr '\0' '@')
  [[ $out == '1'$'\t''2s'$'\t''5m'$'\t''/etc'$'\t''false@'* ]] && pass "rows prints NUL separated records" || fail "rows prints NUL separated records: $out"
  expect "rows asks atuin for newest first and the current filter" grep -q 'search -r --filter-mode global --print0' "$log"
  eq "no state file = filter global" "$(cd "$plain" && bash "$sh" filter)" global
  out=$(cd "$plain" && bash "$sh" cycle +1)
  [[ $out == "reload('$sh' rows)+change-header(filter: directory"* || $out == "reload($sh rows)+change-header(filter: directory"* ]] && pass "cycle +1 outside a repository: global -> directory" || fail "cycle +1 outside a repository: $out"
  eq "state follows" "$(cd "$plain" && bash "$sh" filter)" directory
  (cd "$plain" && bash "$sh" cycle +1 >/dev/null); eq "directory -> session" "$(cd "$plain" && bash "$sh" filter)" session
  (cd "$plain" && bash "$sh" cycle +1 >/dev/null); eq "session -> global (wraps)" "$(cd "$plain" && bash "$sh" filter)" global
  (cd "$plain" && bash "$sh" cycle -1 >/dev/null); eq "global -1 -> session" "$(cd "$plain" && bash "$sh" filter)" session
  rm -f "$DF_ATUIN_STATE"
  (cd "$repo" && bash "$sh" cycle +1 >/dev/null); eq "inside a repository the second filter is workspace" "$(cd "$repo" && bash "$sh" filter)" workspace
  printf 'workspace\n' >"$DF_ATUIN_STATE"
  eq "workspace outside a repository is treated as directory" "$(cd "$plain" && bash "$sh" filter)" directory
  out=$(cd "$plain" && bash "$sh" header)
  [[ $out == "filter: directory"* && $out != *"("* && $out != *")"* ]] && pass "the header names the filter and has no characters that break fzf actions" || fail "header: $out"
  printf 'garbage\n' >"$DF_ATUIN_STATE"; eq "an unknown state falls back to global" "$(cd "$plain" && bash "$sh" filter)" global
  printf '1\t2s\t5m\t/etc\tprintf a\nprintf b\0' >"$T/rec"
  out=$(bash "$sh" preview "$T/rec")
  [[ $out == $'exit 1 · 2s · 5m ago · /etc\nprintf a\nprintf b' ]] && pass "preview shows exit, duration, age, directory and the whole command" || fail "preview: $out"
  unset ATUIN_BIN FAKE_LOG DF_ATUIN_STATE

  # config
  expect "atuin config: no sync, no ai, no daemon, no logs" bash -c "
    f='$REPO/.config/atuin/config.toml'
    grep -q '^auto_sync = false' \$f && grep -q '^sync_address = \"http://127.0.0.1' \$f && grep -q '^update_check = false' \$f &&
    awk '/^\\[ai\\]/{s=1;next} /^\\[/{s=0} s&&/enabled = false/{a=1} END{exit !a}' \$f &&
    awk '/^\\[daemon\\]/{s=1;next} /^\\[/{s=0} s&&/enabled = false/{a=1} END{exit !a}' \$f &&
    awk '/^\\[logs\\]/{s=1;next} /^\\[/{s=0} s&&/enabled = false/{a=1} END{exit !a}' \$f"

  if [[ -n ${DEV_A_REAL:-} ]] && have atuin; then
    mkdir -p "$T/real/cfg/atuin"; cp "$REPO/.config/atuin/config.toml" "$T/real/cfg/atuin/"
    out=$(XDG_CONFIG_HOME="$T/real/cfg" XDG_DATA_HOME="$T/real/data" ATUIN_SESSION=00112233445566778899aabbccddeeff atuin config get -r auto_sync 2>&1)
    eq "real atuin reads auto_sync = false from the repo config" "$out" false
    expect "real atuin made no ~/.atuin" test ! -e "$HOME/.atuin"
  fi

  if ((!QUICK)) && have tmux && have fzf; then s2_tmux; fi
}

# secret-looking command lines: "hide" must match DF_SECRET_CMD_RE, "show" (ordinary dev commands) must not
secret_rows() {
  local gh="ghp_""abcdefghijklmnop1234" gl="glpat-""abcdefghijklmnopqrst" ant="sk-ant-""api03-abcdefghijklmnopqrstu" oai="sk-proj-""AbCdEfGhIjKlMnOpQrStUv"
  printf '%s\n' \
    "hide@@export API_TOKEN=$FAKE_SECRET" \
    "hide@@pg_dump postgres://admin:Zx9PlainPw@db/prod" \
    "hide@@psql postgres://u:pw1234@h/db" \
    "hide@@mysql -uroot -pSecretPw db < dump.sql" \
    "hide@@mysqldump -u root -phunter22 db" \
    "hide@@docker login -u me -p s3cretpw registry.io" \
    "hide@@bw unlock hunter22pw" \
    "hide@@bw login me@x.com hunter22pw" \
    "hide@@export OPENAI_API_KEY=$oai" \
    "hide@@echo $oai" \
    "hide@@echo $ant" \
    "hide@@echo $gh" \
    "hide@@echo $gl" \
    "hide@@curl -H \"X-Api-Key: $FAKE_SECRET\" https://x" \
    "hide@@curl -H 'x-auth-token: ${FAKE_SECRET}x' https://x" \
    'hide@@curl -H "Authorization: Bearer abc" https://x' \
    "hide@@foo --password hunter22" \
    "hide@@sshpass -p x ssh h" \
    'show@@git clone https://github.com/a/b' \
    'show@@git clone https://user:$TOKEN@github.com/a/b' \
    'show@@curl https://host:8080/pkg@1.0' \
    'show@@git clone ssh://git@host:22/x.git' \
    'show@@mysql -u root -p db' \
    'show@@find . -path x -print0' \
    'show@@ls -plah' \
    'show@@docker login -u me --password-stdin' \
    'show@@bw unlock --check' \
    'show@@bw unlock $BW_PW' \
    'show@@rbw unlock' \
    'show@@grep -rn password: src/' \
    'show@@git commit -m "password: reset flow"' \
    'show@@rg token: .' \
    'show@@foo --password $PW' \
    'show@@export TOKEN=$(rbw get x)' \
    'show@@ls -la'
}
s2_secrets() {
  local out rows aenv
  secret_rows >"$T/secret.rows"
  out=$(zsh -f -c '
    source '"$T"'/hooks.zsh
    local row want line got; integer n=0
    while IFS= read -r row; do
      want=${row%%@@*} line=${row#*@@} got=show
      [[ ${(L)line} =~ $DF_SECRET_CMD_RE ]] && got=hide
      [[ $got == $want ]] || print -r -- "BAD want=$want: $line"
      n+=1
    done <'"$T"'/secret.rows
    print -r -- "rows=$n"' 2>&1)
  rows=$(wc -l <"$T/secret.rows")
  [[ $out == "rows=$rows" ]] && pass "M2/L3: $rows secret and false-positive command lines classified as expected" || fail "M2/L3 secret table: $out"
  # atuin's history_filter is the same expression (live second layer, and what `atuin history prune` applies after the import)
  expect "L2: config.toml history_filter is (?i) + DF_SECRET_CMD_RE" python3 -I -c '
import subprocess, sys, tomllib
cfg = tomllib.load(open(sys.argv[1], "rb"))
rx = subprocess.run(["zsh", "-f", "-c", "source %s; print -rn -- $DF_SECRET_CMD_RE" % sys.argv[2]], capture_output=True, text=True).stdout
sys.exit(0 if rx and cfg.get("history_filter") == ["(?i)" + rx] else 1)' "$REPO/.config/atuin/config.toml" "$T/hooks.zsh"
  if have atuin; then
    # the real atuin: the Rust regex accepts the expression, import is unfiltered, prune drops what it matches
    local cfg="$T/l2cfg" data="$T/l2data" cmds imp
    aenv=(XDG_CONFIG_HOME="$cfg" XDG_DATA_HOME="$data" ATUIN_SESSION=00112233445566778899aabbccddeeff)
    mkdir -p "$cfg/atuin" "$data"; cp "$REPO/.config/atuin/config.toml" "$cfg/atuin/"
    sed 's/^[a-z]*@@//' "$T/secret.rows" | awk '{ printf ": %d:0;%s\n", 1700000000 + NR, $0 }' >"$T/l2.zsh_history"
    imp=$(env "${aenv[@]}" HISTFILE="$T/l2.zsh_history" atuin import zsh 2>&1 | tail -1)
    cmds=$(env "${aenv[@]}" atuin history list --format '{command}' 2>/dev/null)
    [[ $cmds == *"Zx9PlainPw"* ]] && pass "L2: (control) atuin import copies a secret line unfiltered" || fail "L2 import control: $imp"
    env "${aenv[@]}" atuin history prune >/dev/null 2>&1
    cmds=$(env "${aenv[@]}" atuin history list --format '{command}' 2>/dev/null)
    [[ $cmds != *"Zx9PlainPw"* && $cmds != *"hunter22"* && $cmds != *"SecretPw"* && $cmds != *"s3cretpw"* && $cmds == *"find . -path x -print0"* && $cmds == *"password: reset flow"* ]] &&
      pass "L2: atuin history prune after the import removes the secret lines and keeps the ordinary ones" || fail "L2 prune: $cmds"
    env "${aenv[@]}" atuin history start --hook -- "mysql -uroot -pLivePw db" >/dev/null 2>&1
    cmds=$(env "${aenv[@]}" atuin history list --format '{command}' 2>/dev/null)
    [[ $cmds != *"LivePw"* ]] && pass "L2: atuin's history_filter also drops a secret at record time" || fail "L2 live filter"
  fi
  # the one-time import in history.zsh prunes after it (import first, prune second)
  local il="$T/import.log" fk="$T/impbin"; mkdir -p "$fk"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"$FAKE_IMPORT_LOG"\nexit 0\n' >"$fk/atuin"; chmod +x "$fk/atuin"
  unguard "$REPO/.config/zsh/history.zsh" "$T/history.zsh"
  : >"$il"
  PATH="$fk:$real_path" FAKE_IMPORT_LOG=$il XDG_DATA_HOME="$T/imp-data" zsh -f -c 'source '"$T"'/history.zsh; sleep 0.6' >/dev/null 2>&1
  eq "L2: history.zsh runs import and then prune on the first shell" "$(tr '\n' ',' <"$il")" "import zsh,history prune,"
  expect "L2: install.sh prunes after its import too" grep -q 'atuin history prune' "$REPO/install.sh"
  expect "L7: the Ctrl+R header is computed with the widget's state file" grep -q 'header "$(DF_ATUIN_STATE=$state ' "$REPO/.config/zsh/history.zsh"
}

# the Ctrl+R list in a private tmux with a fake atuin (full run only)
s2_tmux() {
  mkdir -p "$T/zd" "$T/data/atuin"; : >"$T/data/atuin/history.db"
  cat >"$T/zd/.zshrc" <<EOF
export PATH=$T/bin:$real_path
export FAKE_LOG=$T/atuin-tmux.log
[[ -r $REAL_HOME/.local/state/theme/current/fzfrc ]] && export FZF_DEFAULT_OPTS_FILE=$REAL_HOME/.local/state/theme/current/fzfrc
bindkey -v; KEYTIMEOUT=1
source <(fzf --zsh)
PROMPT='%~ %# '
source \$XDG_CONFIG_HOME/layout/layout-keys.sh 2>/dev/null
source \$XDG_CONFIG_HOME/zsh/layout-keys.zsh 2>/dev/null
for _f in vi-mode cmd-hooks history; do source \$XDG_CONFIG_HOME/zsh/\$_f.zsh; done
EOF
  tmux -L "$SOCK" kill-server 2>/dev/null
  env ZDOTDIR="$T/zd" tmux -L "$SOCK" -f /dev/null new-session -d -x 120 -y 30 "zsh -i; sleep 30"
  sleep 1.5
  tmk() { tmux -L "$SOCK" send-keys "$@"; }
  tmscreen() { tmux -L "$SOCK" capture-pane -p; }
  tmk C-r; sleep 1.2
  local scr; scr=$(tmscreen)
  [[ $scr == *"[I] history>"* ]] && pass "Ctrl+R opens the modal list [I] history>" || fail "Ctrl+R opens the modal list: $scr"
  [[ $scr == *"filter: global"* ]] && pass "the header shows the filter" || fail "the header shows the filter"
  [[ $scr == *"ls -l /usr"* && $scr == *"false"* ]] && pass "the rows come from atuin" || fail "the rows come from atuin"
  tmk Tab; sleep 1; scr=$(tmscreen)
  [[ $scr == *"filter: directory"* || $scr == *"filter: workspace"* ]] && pass "Tab cycles the filter" || fail "Tab cycles the filter"
  tmk Escape; sleep 0.4; scr=$(tmscreen)
  [[ $scr == *"[N] history>"* ]] && pass "Esc is NORMAL" || fail "Esc is NORMAL"
  tmk j; sleep 0.3; tmk -l 'о'; sleep 0.3
  tmk Enter; sleep 0.8; scr=$(tmscreen)
  [[ $scr == *"ls -l /usr"* ]] && pass "j and its ru twin move, Enter puts the command on the line" || fail "j / ru twin / Enter: $scr"
  tmk C-u; tmk C-r; sleep 1; tmk -l 'printf'; sleep 0.6; tmk Enter; sleep 0.6; scr=$(tmscreen)
  [[ $scr == *"printf a"* && $scr == *"printf b"* ]] && pass "a multi-line command arrives whole" || fail "multi-line command: $scr"
  tmux -L "$SOCK" kill-server 2>/dev/null
}

# ── 3 carapace + fzf-tab ─────────────────────────────────────────────────────────────────────────────────────
s3() {
  have zsh || { echo "SKIP  section 3 (zsh missing)"; return; }
  cat >"$T/bin/carapace" <<'EOF'
#!/bin/sh
# fake carapace: `carapace _carapace zsh` prints a completion script for three commands
[ "$1 $2" = "_carapace zsh" ] || exit 1
cat <<'SCRIPT'
export PATH="/fake/carapace/bin:$PATH"
function _carapace_completer {
  compadd -- fake-completion-for-${words[1]}
}
compdef _carapace_completer "alpha" "beta" "gamma"
SCRIPT
EOF
  chmod +x "$T/bin/carapace"
  unguard "$REPO/.config/zsh/completion.zsh" "$T/completion.zsh"
  local cache="$XDG_CACHE_HOME/zsh/carapace.zsh" out
  cat >"$T/s3.zsh" <<EOF
autoload -Uz compinit; compinit -u -d $T/zcompdump
typeset -gA _df_vf_opts _df_vf_act
_df_vf_load() { :; }
source $T/completion.zsh
print -r -- "default=\$_comps[-default-] git=\$_comps[git] docker=\$_comps[docker]"
_df_cara_load
print -r -- "table=\${(kj:,:)_df_cara_cmds} fn=\$+functions[_carapace_completer]"
EOF
  out=$(PATH="$T/bin:$real_path" zsh -f "$T/s3.zsh" 2>&1)
  [[ $out == *"default=_df_carapace_default"* ]] && pass "-default- is the carapace gap filler" || fail "-default-: $out"
  [[ $out == *"git=_git"* ]] && pass "the native git completion is untouched" || fail "git completion: $out"
  [[ $out == *"table="*alpha*beta*gamma* || $out == *"table="*gamma* ]] && pass "the lookup table holds the commands carapace knows" || fail "lookup table: $out"
  expect "the cache is valid zsh" zsh -n "$cache"
  expect "the cache has no PATH line" bash -c "! grep -q '^export PATH=' '$cache'"
  expect "the cache has no compdef line" bash -c "! grep -q '^compdef _carapace_completer' '$cache'"
  expect "the cache keeps the completer function" grep -q '_carapace_completer' "$cache"
  local m1 m2
  touch -d '2 minutes ago' "$cache" "$T/bin/carapace"; touch -d '1 hour ago' "$T/bin/carapace"
  m1=$(stat -c %Y "$cache")
  PATH="$T/bin:$real_path" zsh -f "$T/s3.zsh" >/dev/null 2>&1
  m2=$(stat -c %Y "$cache")
  eq "an unchanged carapace does not rebuild the cache" "$m2" "$m1"
  touch "$T/bin/carapace"
  PATH="$T/bin:$real_path" zsh -f "$T/s3.zsh" >/dev/null 2>&1
  m2=$(stat -c %Y "$cache")
  [[ $m2 -gt $m1 ]] && pass "a newer carapace binary rebuilds the cache" || fail "a newer carapace binary rebuilds the cache"
  # the fallback chooses the completer only for known commands
  cat >"$T/s3b.zsh" <<EOF
autoload -Uz compinit; compinit -u -d $T/zcompdump
typeset -gA _df_vf_opts _df_vf_act
_df_vf_load() { :; }
source $T/completion.zsh
_default() { print -r -- DEFAULT; }
compadd() { print -r -- "CARA:\$*"; }
words=(alpha x); _df_carapace_default
words=(unknowncmd x); _df_carapace_default
words=(/usr/bin/beta x); _df_carapace_default
EOF
  out=$(PATH="$T/bin:$real_path" zsh -f "$T/s3b.zsh" 2>&1 | tr '\n' ' ')
  [[ $out == *"CARA:-- fake-completion-for-alpha "* ]] && pass "a command carapace knows is completed by carapace" || fail "carapace completer: $out"
  [[ $out == *"DEFAULT "* ]] && pass "an unknown command falls back to zsh's _default" || fail "fallback: $out"
  [[ $out == *"CARA:-- fake-completion-for-/usr/bin/beta"* || $out == *"fake-completion-for-/usr/bin/beta "* ]] && pass "a command given by path is looked up by its name" || fail "path lookup: $out"
  # without carapace: no -default- override, zstyles still there
  out=$(PATH="$real_path" zsh -f -c "
    autoload -Uz compinit; compinit -u -d $T/zcompdump2
    typeset -gA _df_vf_opts _df_vf_act; _df_vf_load() { :; }
    (( \$+commands[carapace] )) && print has-carapace
    source $T/completion.zsh
    print \"default=\${_comps[-default-]-none}\"
    zstyle -L ':fzf-tab:*' continuous-trigger" 2>&1 | tr '\n' ' ')
  if [[ $out != *has-carapace* ]]; then
    [[ $out == *"default=none"* || $out == *"default=_default"* ]] && pass "without carapace nothing is overridden" || fail "without carapace: $out"
  fi
  [[ $out == *"continuous-trigger ctrl-l"* ]] && pass "fzf-tab: Ctrl+L is the continuous trigger" || fail "fzf-tab trigger: $out"
  expect "fzf-tab uses the vimfzf command and flags" grep -q "fzf-command _df_ftb_fzf" "$REPO/.config/zsh/completion.zsh"
  expect "the complete label exists in vi-mode.zsh" grep -q 'for label in history files cd atuin complete' "$REPO/.config/zsh/vi-mode.zsh"
  out=$(bash -c ". '$REPO/.config/fzf/vimfzf.sh'; VF_PROMPT=complete VF_PRINT=1 vimfzf" | grep -c -- '--bind')
  ((out > 100)) && pass "vimfzf renders the modal binds for the complete label" || fail "vimfzf complete label ($out binds)"
  if [[ -n ${DEV_A_REAL:-} ]] && have carapace; then
    out=$(carapace _carapace zsh 2>/dev/null | grep -c '^compdef _carapace_completer')
    ((out == 1)) && pass "real carapace prints one compdef line" || fail "real carapace output shape"
  fi
}

# ── 4 cmd-notify ─────────────────────────────────────────────────────────────────────────────────────────────
# fakes: hyprctl answers from $FAKE/clients.json and active.txt; notify-send records its argv (and answers "default" when
# $FAKE/click exists); hyprd records
make_fakes() {
  FAKE="$T/fake"; mkdir -p "$FAKE"
  cat >"$FAKE/hyprctl" <<'EOF'
#!/bin/sh
case "$*" in
  *version*) echo '{"version":"fake"}' ;;
  *clients*) cat "$FAKE/clients.json" ;;
  *activewindow*) printf '{"address":"%s"}\n' "$(cat "$FAKE/active.txt")" ;;
esac
EOF
  cat >"$FAKE/notify-send" <<'EOF'
#!/bin/sh
{ for a in "$@"; do printf '[%s]' "$a"; done; echo; } >>"$FAKE/notify.log"
[ -e "$FAKE/click-removes" ] && echo '[]' >"$FAKE/clients.json"
[ -e "$FAKE/click" ] && echo default
exit 0
EOF
  cat >"$FAKE/hyprd" <<'EOF'
#!/bin/sh
echo "$*" >>"$FAKE/hyprd.log"
EOF
  chmod +x "$FAKE/hyprctl" "$FAKE/notify-send" "$FAKE/hyprd"
  : >"$FAKE/notify.log"; : >"$FAKE/hyprd.log"
  export FAKE CMD_NOTIFY_HYPRCTL="$FAKE/hyprctl" CMD_NOTIFY_NOTIFY="$FAKE/notify-send" CMD_NOTIFY_HYPRD="$FAKE/hyprd" CMD_NOTIFY_STATE="$T/cn-state"
  export HYPRLAND_INSTANCE_SIGNATURE=fake
}
CN="$REPO/.config/hypr/scripts/cmd-notify.sh"
clients_json() { # PID ADDRESS TITLE [PID ADDRESS TITLE ...]
  local out='[' sep=''
  while (($#)); do out+="$sep{\"pid\":$1,\"address\":\"$2\",\"title\":\"$3\"}"; sep=','; shift 3; done
  printf '%s]\n' "$out" >"$FAKE/clients.json"
}
notified() { [[ -s $FAKE/notify.log ]]; }
reset_log() { : >"$FAKE/notify.log"; : >"$FAKE/hyprd.log"; rm -f "$FAKE/click" "$FAKE/click-removes"; }

s4() {
  have jq || { echo "SKIP  section 4 (jq missing)"; return; }
  make_fakes
  make_fake_atuin "$T/bin/atuin"
  local out
  # a "terminal" (owns the window) with a child "shell" one process below it
  setsid bash -c 'bash -c "sleep 600" & echo $! >"$1"; sleep 600' _ "$T/shell.pid" >/dev/null 2>&1 &
  TERM_PID=$!
  for _ in $(seq 1 30); do [[ -s $T/shell.pid ]] && break; sleep 0.1; done
  SHELL_PID=$(<"$T/shell.pid")
  # --- no tmux
  clients_json "$TERM_PID" 0xaaa "zsh"
  echo 0xaaa >"$FAKE/active.txt"
  reset_log
  bash "$CN" notify --exit 0 --ms 65000 --pid "$SHELL_PID"
  notified && fail "terminal in front: no toast" || pass "terminal in front: no toast"
  echo 0xbbb >"$FAKE/active.txt"
  out=$(bash "$CN" locate --pid "$SHELL_PID")
  eq "locate finds the window of the shell through its parent chain" "$out" "0xaaa"$'\t\t\t\t\t\t0'
  DF_CMD='make -j8 all' DF_CMD_DIR="$HOME/job/x" bash "$CN" notify --exit 0 --ms 102000 --pid "$SHELL_PID"
  out=$(cat "$FAKE/notify.log")
  [[ $out == *"[-a][terminal]"* && $out == *"[-i][utilities-terminal]"* && $out == *"[-t][15000]"* && $out == *"[-A][default=Focus]"* ]] && pass "toast: app, icon, timeout and the Focus action" || fail "toast fields: $out"
  [[ $out == *"[Finished in 1m 42s]"* ]] && pass "summary: Finished in 1m 42s" || fail "summary: $out"
  [[ $out == *"make -j8 all"*"in ~/job/x · click to focus"* ]] && pass "body: command and directory with ~" || fail "body: $out"
  reset_log
  DF_CMD='false' DF_CMD_DIR=/tmp bash "$CN" notify --exit 2 --ms 31000 --pid "$SHELL_PID"
  [[ $(cat "$FAKE/notify.log") == *"[Failed (exit 2) after 31s]"* ]] && pass "summary: Failed (exit 2) after 31s" || fail "failed summary"
  reset_log
  DF_CMD='echo "a & b < c > d"' DF_CMD_DIR=/tmp bash "$CN" notify --exit 0 --ms 31000 --pid "$SHELL_PID"
  [[ $(cat "$FAKE/notify.log") == *"a &amp; b &lt; c &gt; d"* ]] && pass "& < > are escaped for dunst markup" || fail "markup escaping"
  reset_log
  DF_CMD="$(printf 'x%.0s' $(seq 1 200))" DF_CMD_DIR=/tmp bash "$CN" notify --exit 0 --ms 31000 --pid "$SHELL_PID"
  [[ $(cat "$FAKE/notify.log") != *"$(printf 'x%.0s' $(seq 1 81))"* && $(cat "$FAKE/notify.log") == *"…"* ]] && pass "the command is cut at 80 characters" || fail "truncation"
  reset_log
  DF_CMD=$'line one\nline two\tend' DF_CMD_DIR=/tmp bash "$CN" notify --exit 0 --ms 31000 --pid "$SHELL_PID"
  [[ $(cat "$FAKE/notify.log") == *"line one line two end"* ]] && pass "newlines and tabs become spaces" || fail "control characters"
  reset_log
  DF_CMD="export API_TOKEN=$FAKE_SECRET" DF_CMD_DIR=/tmp bash "$CN" notify --exit 0 --ms 31000 --pid "$SHELL_PID" --hidden
  [[ $(cat "$FAKE/notify.log") == *"(command hidden)"* && $(cat "$FAKE/notify.log") != *abcdef123456* ]] && pass "--hidden shows (command hidden)" || fail "--hidden"
  if have gitleaks; then
    reset_log
    DF_CMD="curl -H 'Authorization: Bearer ghp_$(printf '%s' 'aB3dE5gH7jK9mN1pQ3sT5vW7yZ9bC1dE3fG5')'" DF_CMD_DIR=/tmp bash "$CN" notify --exit 0 --ms 31000 --pid "$SHELL_PID"
    [[ $(cat "$FAKE/notify.log") == *"(command hidden)"* ]] && pass "a command gitleaks flags is hidden too" || fail "gitleaks hiding: $(cat "$FAKE/notify.log")"
  fi
  reset_log
  bash "$CN" off
  DF_CMD='sleep 40' DF_CMD_DIR=/tmp bash "$CN" notify --exit 0 --ms 40000 --pid "$SHELL_PID"
  notified && fail "switched off: no toast" || pass "switched off: no toast"
  bash "$CN" status >/dev/null 2>&1 && fail "status reports OFF" || pass "status reports OFF (exit 1)"
  bash "$CN" toggle; bash "$CN" status >/dev/null 2>&1 && pass "toggle switches it back on (status exit 0)" || fail "toggle"
  reset_log
  touch "$FAKE/click"
  DF_CMD='sleep 40' DF_CMD_DIR=/tmp bash "$CN" notify --exit 0 --ms 40000 --pid "$SHELL_PID"
  [[ $(cat "$FAKE/hyprd.log") == "focuswindow address:0xaaa" ]] && pass "click: hyprd focuswindow address:0xaaa" || fail "click focus: $(cat "$FAKE/hyprd.log")"
  reset_log; touch "$FAKE/click" "$FAKE/click-removes"
  DF_CMD='sleep 40' DF_CMD_DIR=/tmp bash "$CN" notify --exit 0 --ms 40000 --pid "$SHELL_PID"
  [[ -s $FAKE/hyprd.log ]] && fail "window gone at click: no focus call" || pass "window gone at click: no focus call"
  clients_json "$TERM_PID" 0xaaa "zsh"; reset_log
  # a shell without a window still gets a toast, but no Focus action
  clients_json 999999 0xccc "other"
  DF_CMD='sleep 40' DF_CMD_DIR=/tmp bash "$CN" notify --exit 0 --ms 40000 --pid "$SHELL_PID"
  [[ $(cat "$FAKE/notify.log") == *"Finished in 40s"* && $(cat "$FAKE/notify.log") != *"-A"* ]] && pass "no window found: toast without the Focus action" || fail "no window: $(cat "$FAKE/notify.log")"
  reset_log
  # M3: two windows of ONE process (ghostty Ctrl+Shift+N) and nothing tells which one is the shell's: the focused sibling must not
  # swallow the toast, and there is no Focus action for a window we cannot name
  clients_json "$TERM_PID" 0xaaa "zsh" "$TERM_PID" 0xbbb "zsh"; echo 0xbbb >"$FAKE/active.txt"
  DF_CMD='sleep 40' DF_CMD_DIR=/tmp bash "$CN" notify --exit 0 --ms 40000 --pid "$SHELL_PID"
  [[ $(cat "$FAKE/notify.log") == *"Finished in 40s"* && $(cat "$FAKE/notify.log") != *"-A"* ]] && pass "M3: two windows of one process, none decidable: toast, no Focus action (the focused sibling does not count as in front)" || fail "M3 two windows: $(cat "$FAKE/notify.log")"
  expect "M3: locate says no window for an undecidable pair" bash -c "! bash '$CN' locate --pid '$SHELL_PID'"
  clients_json "$TERM_PID" 0xaaa "zsh"; echo 0xbbb >"$FAKE/active.txt"; reset_log
  # no reachable Hyprland: silent
  out=$(HYPRLAND_INSTANCE_SIGNATURE='' XDG_RUNTIME_DIR="$T/run-empty" CMD_NOTIFY_HYPRCTL=/bin/false bash "$CN" notify --exit 0 --ms 40000 --pid "$SHELL_PID" 2>&1; echo "rc=$?")
  [[ $out == "rc=0" ]] && ! notified && pass "no reachable Hyprland: silent" || fail "no Hyprland: $out"
  # a stale signature in the environment: the newest working instance in the runtime dir is used
  mkdir -p "$T/run/hypr/stale-sig" "$T/run/hypr/good-sig"
  cat >"$FAKE/hyprctl-sig" <<'EOF'
#!/bin/sh
[ "$HYPRLAND_INSTANCE_SIGNATURE" = good-sig ] || exit 1
exec "$FAKE/hyprctl" "$@"
EOF
  chmod +x "$FAKE/hyprctl-sig"
  clients_json "$TERM_PID" 0xaaa "zsh"; echo 0xbbb >"$FAKE/active.txt"
  touch -d '2 minutes ago' "$T/run/hypr/stale-sig"
  DF_CMD='x' DF_CMD_DIR=/tmp HYPRLAND_INSTANCE_SIGNATURE=stale-sig CMD_NOTIFY_HYPRCTL="$FAKE/hyprctl-sig" bash "$CN" notify --exit 0 --ms 40000 --pid "$SHELL_PID"
  notified && pass "a stale Hyprland signature falls back to the live instance" || fail "stale signature"
  rm -rf "$T/run/hypr"
  reset_log

  # --- zsh side against a fake worker
  if have zsh; then
    mkdir -p "$T/zcfg/hypr/scripts"
    cat >"$T/zcfg/hypr/scripts/cmd-notify.sh" <<'EOF'
#!/bin/sh
printf '%s|%s|%s\n' "$*" "$DF_CMD" "$DF_CMD_DIR" >>"$FAKE_WORKER_LOG"
EOF
    chmod +x "$T/zcfg/hypr/scripts/cmd-notify.sh"
    unguard "$REPO/.config/zsh/cmd-hooks.zsh" "$T/hooks.zsh"
    local wl="$T/worker.log"; : >"$wl"
    cat >"$T/s4.zsh" <<EOF
source $T/hooks.zsh
DF_CMD_NOTIFY_MIN=1
run() { _df_cmd_preexec "\$1"; _df_cmd_t0=\$(( EPOCHREALTIME - \${2:-1.5} )); (exit \${3:-0}); _df_cmd_precmd; }
cd /tmp
run "sleep 1.2"
run " sleep 1.2"
run "nvim file.txt"
run "sudo env FOO=1 nvim x"
run "ls"  0.2
run "export API_TOKEN=\$FAKE_SECRET"
SSH_CONNECTION="1 2 3 4" run "sleep 3"
DF_CMD_NOTIFY_MIN=0 run "sleep 3"
run "false" 1.5 1
sleep 0.3
EOF
    FAKE_SECRET=$FAKE_SECRET PATH="$T/bin:$real_path" XDG_CONFIG_HOME="$T/zcfg" FAKE_WORKER_LOG="$wl" zsh -f "$T/s4.zsh" >/dev/null 2>&1
    local n; n=$(grep -c . "$wl")
    [[ $(grep -c '^notify --exit 0 --ms 1[0-9][0-9][0-9] --pid [0-9]*|sleep 1.2|/tmp$' "$wl") == 1 ]] && pass "zsh: a long command calls the worker with exit, ms, pid, command and directory" || fail "zsh worker call: $(cat "$wl")"
    expect "zsh: a leading space never notifies" bash -c "! grep -q '^[^|]*| sleep' '$wl'"
    expect "zsh: an interactive program (nvim, also after sudo env) never notifies" bash -c "! grep -q 'nvim' '$wl'"
    expect "zsh: a short command never notifies" bash -c "! grep -q '|ls|' '$wl'"
    expect "zsh: a secret-looking command is passed with --hidden" grep -q -- '--hidden|export API_TOKEN' "$wl"
    expect "zsh: an ssh login never notifies" bash -c "! grep -q 'sleep 3' '$wl'"
    expect "zsh: a failed command passes its exit status" grep -q 'notify --exit 1 ' "$wl"
    ((n == 3)) && pass "zsh: exactly the three expected worker calls" || fail "zsh: $n worker calls (expected 3): $(cat "$wl")"
  fi

  # L5: the ignore list looks at the alias-expanded line ($3 of preexec) and skips wrappers with their options
  if have zsh; then
    local wl2="$T/worker2.log"; : >"$wl2"
    cat >"$T/s4b.zsh" <<EOF
source $T/hooks.zsh
DF_CMD_NOTIFY_MIN=1
run3() { _df_cmd_preexec "\$1" "\$1" "\${2:-\$1}"; _df_cmd_t0=\$(( EPOCHREALTIME - 1.5 )); (exit 0); _df_cmd_precmd; }
cd /tmp
run3 "lzd" "lazydocker"
run3 "ed x" "nvim x"
run3 "sudo -E nvim x"
run3 "sudo -u root nvim x"
run3 "doas nvim x"
run3 "command nvim x"
run3 "nohup less x"
run3 "env -i FOO=1 nvim x"
run3 "sudo -E make all"
run3 "mk" "make all"
sleep 0.3
EOF
    PATH="$T/bin:$real_path" XDG_CONFIG_HOME="$T/zcfg" FAKE_WORKER_LOG="$wl2" zsh -f "$T/s4b.zsh" >/dev/null 2>&1
    eq "L5: only the two long non-interactive commands notify (alias lzd, sudo -E / -u, doas, command, nohup, env -i are ignored)" "$(sed 's/^[^|]*|//; s/|.*//' "$wl2" | tr '\n' ',')" "sudo -E make all,mk,"
  fi

  # --- tmux (full run): a real client in a fake terminal process
  if ((!QUICK)) && have tmux && have script; then s4_tmux; fi
  kill -- "-$TERM_PID" 2>/dev/null
}

s4_tmux() {
  local tsock="$T/tmux.sock" tm out
  tm() { tmux -S "$tsock" "$@"; }
  tmux -S "$tsock" -f /dev/null new-session -d -s main -x 100 -y 30 "sleep 600"
  tm new-window -d -t main: "sleep 600"       # window 1 stays in the background
  # the "terminal": a process that owns the client (its parent chain reaches it), like ghostty -e tmux attach
  setsid bash -c 'echo $$ >"$1"; tail -f /dev/null | script -qfc "tmux -S $2 attach -t main" /dev/null' _ "$T/term.pid" "$tsock" </dev/null >/dev/null 2>&1 &
  TMUX_TERM_PGID=$!
  for _ in $(seq 1 50); do [[ -s $T/term.pid ]] && tm list-clients 2>/dev/null | grep -q . && break; sleep 0.1; done
  local tpid; tpid=$(<"$T/term.pid")
  local pane0 pane1 win0 win1
  pane0=$(tm list-panes -t main:0 -F '#{pane_id}'); pane1=$(tm list-panes -t main:1 -F '#{pane_id}')
  win0=$(tm display-message -p -t main:0 '#{window_id}'); win1=$(tm display-message -p -t main:1 '#{window_id}')
  tm select-window -t main:0
  clients_json "$tpid" 0xddd "main:zsh"
  export TMUX="$tsock,1,0"
  export CMD_NOTIFY_TMUX=tmux
  # tmux wrapper that always talks to the private server (the worker passes -S itself, this only makes the env explicit)
  echo 0xddd >"$FAKE/active.txt"; reset_log
  out=$(TMUX_PANE=$pane0 bash "$CN" locate --pid 1)
  [[ $out == "0xddd"$'\t'"$tsock"$'\t'main$'\t'"$win0"$'\t'"$pane0"$'\t'*$'\t'1 ]] && pass "locate: window, socket, session, window id, pane id and focused for the active pane" || fail "locate (active pane): $out"
  TMUX_PANE=$pane0 DF_CMD=x DF_CMD_DIR=/tmp bash "$CN" notify --exit 0 --ms 40000 --pid 1
  notified && fail "focused window and active pane: no toast" || pass "focused window and active pane: no toast"
  TMUX_PANE=$pane1 DF_CMD='make' DF_CMD_DIR=/tmp bash "$CN" notify --exit 0 --ms 40000 --pid 1
  notified && pass "a pane in another tmux window of the focused terminal notifies" || fail "other tmux window notifies"
  reset_log; echo 0xeee >"$FAKE/active.txt"
  TMUX_PANE=$pane0 DF_CMD='make' DF_CMD_DIR=/tmp bash "$CN" notify --exit 0 --ms 40000 --pid 1
  notified && pass "terminal not focused: toast" || fail "terminal not focused: toast"
  reset_log; touch "$FAKE/click"
  TMUX_PANE=$pane1 DF_CMD='make' DF_CMD_DIR=/tmp bash "$CN" notify --exit 0 --ms 40000 --pid 1
  sleep 0.3
  [[ $(cat "$FAKE/hyprd.log") == "focuswindow address:0xddd" ]] && pass "click: the terminal window is focused" || fail "click focus: $(cat "$FAKE/hyprd.log")"
  eq "click: the tmux window of the command is selected" "$(tm display-message -p -t main '#{window_id}')" "$win1"
  eq "click: the tmux pane of the command is selected" "$(tm display-message -p -t main '#{pane_id}')" "$pane1"
  # M3: a second window of the same terminal process; the title `main:` says which one shows this session
  clients_json "$tpid" 0xddd "main:zsh" "$tpid" 0xfff "other:zsh"; echo 0xfff >"$FAKE/active.txt"; reset_log
  TMUX_PANE=$pane0 DF_CMD='make' DF_CMD_DIR=/tmp bash "$CN" notify --exit 0 --ms 40000 --pid 1
  notified && pass "M3: the sibling window of the terminal process has focus, the session's own window has not: toast" || fail "M3 sibling focused: silent"
  out=$(TMUX_PANE=$pane0 bash "$CN" locate --pid 1)
  [[ $out == "0xddd"$'\t'* && $out == *$'\t'0 ]] && pass "M3: locate picks the window titled <session>: and reports not focused" || fail "M3 locate: $out"
  echo 0xddd >"$FAKE/active.txt"; reset_log; tm select-window -t main:0
  TMUX_PANE=$pane0 DF_CMD='make' DF_CMD_DIR=/tmp bash "$CN" notify --exit 0 --ms 40000 --pid 1
  notified && fail "M3: the session's own window is in front: no toast" || pass "M3: the session's own window is in front: no toast"
  clients_json "$tpid" 0xddd "main:zsh"
  # L4: a tmux inside a pane of the outer tmux: the inner client's parent chain ends in the outer tmux server
  local isock="$T/tmux-inner.sock" iw ipane
  tmux -S "$isock" -f /dev/null new-session -d -s inner -x 80 -y 20 "sleep 600"
  iw=$(tm new-window -d -P -F '#{window_id}' -t main: "bash -c 'TMUX= tmux -S $isock attach -t inner; sleep 600'")
  for _ in $(seq 1 50); do tmux -S "$isock" list-clients 2>/dev/null | grep -q . && break; sleep 0.1; done
  ipane=$(tmux -S "$isock" list-panes -t inner -F '#{pane_id}')
  tm select-window -t "$iw"; echo 0xddd >"$FAKE/active.txt"; reset_log
  out=$(TMUX="$isock,1,0" TMUX_PANE=$ipane bash "$CN" locate --pid 1)
  [[ $out == "0xddd"$'\t'"$tsock"$'\t'main$'\t'"$iw"$'\t'*$'\t'*$'\t'1 ]] && pass "L4: a nested tmux resolves to the outer terminal window, outer socket, session and window, in front" || fail "L4 locate (in front): $out"
  TMUX="$isock,1,0" TMUX_PANE=$ipane DF_CMD=x DF_CMD_DIR=/tmp bash "$CN" notify --exit 0 --ms 40000 --pid 1
  notified && fail "L4: a nested pane in front: no toast" || pass "L4: a nested pane in front: no toast"
  tm select-window -t main:0
  out=$(TMUX="$isock,1,0" TMUX_PANE=$ipane bash "$CN" locate --pid 1)
  [[ $out == "0xddd"$'\t'"$tsock"$'\t'*$'\t'*$'\t'*$'\t'*$'\t'0 ]] && pass "L4: another outer tmux window is in front: not focused" || fail "L4 locate (outer elsewhere): $out"
  reset_log; touch "$FAKE/click"
  TMUX="$isock,1,0" TMUX_PANE=$ipane DF_CMD='make' DF_CMD_DIR=/tmp bash "$CN" notify --exit 0 --ms 40000 --pid 1
  sleep 0.3
  [[ $(cat "$FAKE/hyprd.log") == "focuswindow address:0xddd" ]] && pass "L4: click focuses the terminal window" || fail "L4 click: $(cat "$FAKE/hyprd.log")"
  eq "L4: click selects the outer tmux window that shows the inner tmux" "$(tm display-message -p -t main '#{window_id}')" "$iw"
  tmux -S "$isock" kill-server 2>/dev/null
  unset TMUX CMD_NOTIFY_TMUX
  kill -- "-$TMUX_TERM_PGID" 2>/dev/null
  if have zsh; then
    # the hook files are skipped for agent shells (CLAUDECODE) and installed for others
    mkdir -p "$T/zd2"
    printf 'for _f in cmd-hooks; do source $XDG_CONFIG_HOME/zsh/$_f.zsh; done\n' >"$T/zd2/.zshrc"
    tm kill-server 2>/dev/null
    tmux -L "$SOCK" -f /dev/null new-session -d -x 100 -y 20 "env ZDOTDIR=$T/zd2 zsh -i; sleep 20"
    tmux -L "$SOCK-b" -f /dev/null new-session -d -x 100 -y 20 "env CLAUDECODE=1 ZDOTDIR=$T/zd2 zsh -i; sleep 20"
    sleep 1.5
    tmux -L "$SOCK" send-keys -l 'print HOOKS=$+functions[_df_cmd_precmd]'; tmux -L "$SOCK" send-keys Enter
    tmux -L "$SOCK-b" send-keys -l 'print HOOKS=$+functions[_df_cmd_precmd]'; tmux -L "$SOCK-b" send-keys Enter
    sleep 0.8
    [[ $(tmux -L "$SOCK" capture-pane -p) == *"HOOKS=1"* ]] && pass "an interactive shell installs the hooks" || fail "interactive shell installs the hooks"
    [[ $(tmux -L "$SOCK-b" capture-pane -p) == *"HOOKS=0"* ]] && pass "an agent shell (CLAUDECODE) does not" || fail "agent shell skips the hooks"
    tmux -L "$SOCK" kill-server 2>/dev/null; tmux -L "$SOCK-b" kill-server 2>/dev/null
  fi
}

# ── 5 overhead ───────────────────────────────────────────────────────────────────────────────────────────────
s5() {
  have zsh || { echo "SKIP  section 5 (zsh missing)"; return; }
  printf '#!/bin/sh\n[ "$2" = start ] && echo 0123456789abcdef0123456789abcdef\nexit 0\n' >"$T/bin/atuin-fast"
  mkdir -p "$T/fast"; cp "$T/bin/atuin-fast" "$T/fast/atuin"; chmod +x "$T/fast/atuin"
  unguard "$REPO/.config/zsh/cmd-hooks.zsh" "$T/hooks.zsh"
  local avg
  avg=$(PATH="$T/fast:$real_path" zsh -f -c '
    source '"$T"'/hooks.zsh
    zmodload zsh/datetime
    float t0=$EPOCHREALTIME
    for i in {1..1000}; do _df_cmd_preexec "echo x"; _df_cmd_precmd; done
    printf "%.3f" $(( EPOCHREALTIME - t0 ))' 2>/dev/null)
  [[ -n $avg ]] && awk -v a="$avg" 'BEGIN { exit !(a < 1.0) }' && pass "hook overhead $avg ms per command (< 1 ms)" || fail "hook overhead $avg ms per command"
}

want 1 && s1
want 2 && s2
want 3 && s3
want 4 && s4
want 5 && s5
printf 'dev-a tests: %d passed, %d failed\n' "$passed" "$fails"
((fails == 0))
