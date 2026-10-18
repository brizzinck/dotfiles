#!/usr/bin/env bash
# User-level dev tools (DEV-d): terminal database / HTTP / forge / local-CI tools that are not repo packages. Never sudo; every
# step is skipped when the installed version is already at least the pin (the pins are the fresh-install floor: sysup moves
# these tools forward later with its go / pipx / npm / cargo steps), a failed step only warns.
#
#   infrastructure/dev/user-tools.sh [--dry-run] [--only NAME[,NAME]]     names: lazysql gh-dash posting gitlab-ci-local glab-tui glab
#   infrastructure/dev/user-tools.sh --shared [--prefix DIR] [--dry-run] [--only NAME[,NAME]] [--check | --stamp]
#
# (posting is the exception: exactly the pin, from the hash lock.)
#
# --shared installs the same pins for the managed users td and yc into one read-only tree, /srv/devtools by default (created by
# `sudo ./apply-system.sh --only users`, owned by the owner, run THIS as the owner, no sudo): bin/ holds links to go/bin (lazysql,
# gh-dash), venv/posting (hash-locked), npm/ (gitlab-ci-local) and cargo/bin (glab-tui, workmux); the managed users never install
# or update there. Names: lazysql gh-dash posting gitlab-ci-local glab-tui workmux. Every tool must be EXACTLY the pin (not
# "at least": nothing else writes there). `.ready` holds the stamp of the pins that were installed; --check (read-only, exit 1 when
# a tool is missing or not the pin) and --stamp (prints the stamp the pins want) serve `usr`, sysup and doctor.
#
# Sources and why (see CLAUDE.md "Dev tools"): `go install module@tag` is verified by sum.golang.org and has no telemetry
# collector (the lazysql release builds ask once and send by default); pipx for posting (with a hash-locked dependency set),
# `npm install -g --ignore-scripts`
# for gitlab-ci-local, `cargo install --locked --version` for glab-tui. Repo packages (hurl, act, glab) come from
# apply-system.sh. No AUR *-bin packages.
set -u

LAZYSQL_VERSION=v0.7.0                 # github.com/jorgerojas26/lazysql
GHDASH_VERSION=v4.26.2                 # github.com/dlvhdr/gh-dash/v4
POSTING_VERSION=2.11.1                 # PyPI posting (pipx, hash-locked: posting-requirements.txt, exact version)
GCL_VERSION=4.76.1                     # npm gitlab-ci-local
GLABTUI_VERSION=0.9.3                  # crates.io glab-tui-crate (binary glab-tui)
WORKMUX_VERSION=0.1.276                # crates.io workmux (shared tree only: the owner's copy comes from install.sh / sysup)

DRY=0 ONLY="" SHARED=0 PREFIX=/srv/devtools MODE=install
while (($#)); do
  case $1 in
    --dry-run) DRY=1 ;;
    --only) ONLY=${2:-}; shift ;;
    --only=*) ONLY=${1#--only=} ;;
    --shared) SHARED=1 ;;
    --prefix) PREFIX=${2:-}; shift ;;
    --prefix=*) PREFIX=${1#--prefix=} ;;
    --check) MODE=check ;;
    --stamp) MODE=stamp ;;
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "usage: user-tools.sh [--dry-run] [--only NAME[,NAME]] | --shared [--prefix DIR] [--check|--stamp] [--dry-run] [--only ...]" >&2; exit 2 ;;
  esac
  shift
done
if ((! SHARED)) && [[ $MODE != install ]]; then echo "user-tools.sh: --check and --stamp need --shared" >&2; exit 2; fi
[[ -n $PREFIX && $PREFIX == /* ]] || { echo "user-tools.sh: --prefix must be an absolute path" >&2; exit 2; }

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DOTFILES=$(cd "$HERE/../.." && pwd)
log() { printf '==> %s\n' "$*"; }
warn() { printf 'warn: %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }
want() { [[ -z $ONLY || ,$ONLY, == *,"$1",* ]]; }
# ver_ge A B: A >= B as versions (a leading v is ignored)
ver_ge() { local a=${1#v} b=${2#v}; [[ -n $a && $(printf '%s\n%s\n' "$a" "$b" | sort -V | head -1) == "$b" ]]; }
run() { if ((DRY)); then echo "  would run: $*"; else "$@"; fi; }

gobin() { local d; d=$(go env GOBIN 2>/dev/null); echo "${d:-$(go env GOPATH 2>/dev/null)/bin}"; }
go_version_of() { # binary -> module version stamped by `go install`, empty when missing
  local f; f="$(gobin)/$1"
  [[ -x $f ]] && go version -m "$f" 2>/dev/null | awk '$1 == "mod" {print $3; exit}'
}

step_go() { # name module version binary
  local name=$1 mod=$2 ver=$3 bin=$4 have_v
  have go || { warn "go is not installed: $name skipped"; return 0; }
  have_v=$(go_version_of "$bin")
  if [[ -n $have_v ]] && ver_ge "$have_v" "$ver"; then log "$name $have_v present (pin $ver)"; return 0; fi
  log "$name: go install $mod@$ver"
  run go install "$mod@$ver" || warn "$name: go install failed"
}

step_posting() {
  have pipx || { warn "pipx is not installed: posting skipped"; return 0; }
  local have_v
  have_v=$(pipx list --json 2>/dev/null | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
    print(d["venvs"]["posting"]["metadata"]["main_package"]["package_version"])
except Exception:
    pass' 2>/dev/null)
  # pipx makes the venv and the entry point WITHOUT dependencies, then every package (posting and its 46 dependencies) is
  # installed from posting-requirements.txt with `--require-hashes`: nothing newer than the lock, every file hash-checked
  # (REVIEW-DEV-d #16; the lock is made by posting-lock.py)
  local lock="$HERE/posting-requirements.txt" mark lock_sum have_sum
  [[ -f $lock ]] || { warn "posting: $lock is missing"; return 0; }
  mark="${XDG_STATE_HOME:-$HOME/.local/state}/dev-tools/posting.lock"
  lock_sum=$(sha256sum "$lock" | cut -d' ' -f1); have_sum=$(cat "$mark" 2>/dev/null)
  # exactly the pin, installed from THIS lock (the marker): an older unhashed install, a newer pipx upgrade or a changed lock
  # are all reinstalled
  if [[ $have_v == "$POSTING_VERSION" && $have_sum == "$lock_sum" ]]; then log "posting $have_v present (pin $POSTING_VERSION, lock verified)"; return 0; fi
  log "posting: pipx install --no-deps posting==$POSTING_VERSION, then pip --require-hashes -r posting-requirements.txt"
  if [[ -n $have_v ]]; then run pipx install --force --pip-args=--no-deps "posting==$POSTING_VERSION"; else run pipx install --pip-args=--no-deps "posting==$POSTING_VERSION"; fi \
    && run pipx runpip posting install --require-hashes --no-deps --force-reinstall -r "$lock" \
    || { warn "posting: install failed"; return 0; }
  if ((! DRY)); then mkdir -p "$(dirname "$mark")" && printf '%s\n' "$lock_sum" >"$mark"; fi
}

step_gcl() {
  have npm || { warn "npm is not installed: gitlab-ci-local skipped"; return 0; }
  local have_v
  have_v=$(npm ls -g --depth=0 --json 2>/dev/null | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin)["dependencies"]["gitlab-ci-local"]["version"])
except Exception:
    pass' 2>/dev/null)
  if [[ -n $have_v ]] && ver_ge "$have_v" "$GCL_VERSION"; then log "gitlab-ci-local $have_v present (pin $GCL_VERSION)"; return 0; fi
  log "gitlab-ci-local: npm install -g --ignore-scripts gitlab-ci-local@$GCL_VERSION"
  run npm install -g --ignore-scripts "gitlab-ci-local@$GCL_VERSION" || warn "gitlab-ci-local: npm install failed"
}

step_glabtui() {
  have cargo || { warn "cargo is not installed: glab-tui skipped"; return 0; }
  local have_v
  have_v=$(cargo install --list 2>/dev/null | awk '$1 == "glab-tui-crate" {gsub(/^v|:$/, "", $2); print $2; exit}')
  if [[ -n $have_v ]] && ver_ge "$have_v" "$GLABTUI_VERSION"; then log "glab-tui $have_v present (pin $GLABTUI_VERSION)"; return 0; fi
  log "glab-tui: cargo install --locked --version $GLABTUI_VERSION glab-tui-crate"
  run cargo install --locked --version "$GLABTUI_VERSION" glab-tui-crate || warn "glab-tui: cargo install failed"
}

step_glab() { # telemetry off (the setting is checked on the installed glab; a version without it is left alone)
  have glab || { log "glab is not installed (apply-system.sh --only install): telemetry setting skipped"; return 0; }
  local cur
  cur=$(glab config get telemetry --global 2>/dev/null)
  if [[ $cur == false ]]; then log "glab telemetry is off"; return 0; fi
  if glab config --help 2>&1 | grep -qi 'telemetry' || [[ -n $cur ]]; then
    log "glab: config set --global telemetry false"
    run glab config set --global telemetry false || warn "glab: could not set telemetry=false"
  else
    log "glab has no telemetry setting on this version"
  fi
}

step_glabtui_config() { # glab-tui writes its config itself (Save View): copied once when missing, never stowed
  local dst="${XDG_CONFIG_HOME:-$HOME/.config}/glab-tui/config.toml"
  [[ -f $dst ]] && return 0
  log "glab-tui: config -> $dst"
  if ((DRY)); then echo "  would copy: $HERE/glab-tui-config.toml"; return 0; fi
  install -D -m 644 "$HERE/glab-tui-config.toml" "$dst" || warn "glab-tui: could not copy the config"
}

# ───────────────────────────── --shared: /srv/devtools for td and yc ─────────────────────────────

SHARED_TOOLS="lazysql gh-dash posting gitlab-ci-local glab-tui workmux"

# the stamp of what the pins want: changes with a pin, the posting lock or the python minor version (the venv is tied to it)
shared_stamp() {
  {
    printf 'lazysql=%s\ngh-dash=%s\nposting=%s\ngitlab-ci-local=%s\nglab-tui=%s\nworkmux=%s\n' \
      "$LAZYSQL_VERSION" "$GHDASH_VERSION" "$POSTING_VERSION" "$GCL_VERSION" "$GLABTUI_VERSION" "$WORKMUX_VERSION"
    sha256sum "$HERE/posting-requirements.txt" 2>/dev/null | cut -d' ' -f1
    /usr/bin/python3 -c 'import sys; print(sys.version_info[:2])' 2>/dev/null
  } | sha256sum | cut -d' ' -f1
}

# installed version of one shared tool, empty when missing or broken
sh_have() {
  local name=$1 f
  case $name in
    lazysql|gh-dash)
      f=$PREFIX/go/bin/$name
      [[ -x $f ]] && have go && go version -m "$f" 2>/dev/null | awk '$1 == "mod" {sub(/^v/, "", $3); print $3; exit}' ;;
    posting)
      f=$PREFIX/venv/posting/bin/python
      [[ -x $f && -x $PREFIX/bin/posting && $(cat "$PREFIX/venv/posting.lock" 2>/dev/null) == "$(sha256sum "$HERE/posting-requirements.txt" 2>/dev/null | cut -d' ' -f1)" ]] &&
        "$f" -c 'import importlib.metadata as m; print(m.version("posting"))' 2>/dev/null ;;
    gitlab-ci-local)
      f=$PREFIX/npm/node_modules/gitlab-ci-local/package.json
      [[ -r $f && -e $PREFIX/npm/node_modules/.bin/gitlab-ci-local ]] && python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$f" 2>/dev/null ;;
    glab-tui|workmux)
      [[ -x $PREFIX/cargo/bin/$name ]] || return 0
      have cargo && cargo install --root "$PREFIX/cargo" --list 2>/dev/null |
        awk -v c="$( [[ $name == glab-tui ]] && echo glab-tui-crate || echo workmux )" '$1 == c {gsub(/^v|:$/, "", $2); print $2; exit}' ;;
  esac
}

sh_pin() {
  case $1 in
    lazysql) echo "${LAZYSQL_VERSION#v}" ;;
    gh-dash) echo "${GHDASH_VERSION#v}" ;;
    posting) echo "$POSTING_VERSION" ;;
    gitlab-ci-local) echo "$GCL_VERSION" ;;
    glab-tui) echo "$GLABTUI_VERSION" ;;
    workmux) echo "$WORKMUX_VERSION" ;;
  esac
}

sh_link() { # sh_link NAME TARGET (relative to bin/)
  if ((DRY)); then echo "  would link: $PREFIX/bin/$1 -> $2"; return 0; fi
  mkdir -p "$PREFIX/bin" && ln -sfn -- "$2" "$PREFIX/bin/$1"
}

sh_install() { # one tool; failure only warns (the others still go on)
  local name=$1
  case $name in
    lazysql) run env "GOBIN=$PREFIX/go/bin" go install "github.com/jorgerojas26/lazysql@$LAZYSQL_VERSION" && sh_link lazysql ../go/bin/lazysql ;;
    gh-dash) run env "GOBIN=$PREFIX/go/bin" go install "github.com/dlvhdr/gh-dash/v4@$GHDASH_VERSION" && sh_link gh-dash ../go/bin/gh-dash ;;
    posting)
      # a venv at its final path (the entry point's shebang names it), every package from the hash lock, nothing else
      run python3 -m venv --clear "$PREFIX/venv/posting" &&
        run "$PREFIX/venv/posting/bin/python" -m pip install --disable-pip-version-check --no-cache-dir --require-hashes --no-deps -r "$HERE/posting-requirements.txt" &&
        sh_link posting ../venv/posting/bin/posting &&
        if ((DRY)); then echo "  would write: $PREFIX/venv/posting.lock"; else sha256sum "$HERE/posting-requirements.txt" | cut -d' ' -f1 >"$PREFIX/venv/posting.lock"; fi ;;
    gitlab-ci-local)
      run mkdir -p "$PREFIX/npm" &&
        run npm install --prefix "$PREFIX/npm" --ignore-scripts --no-audit --no-fund --no-save "gitlab-ci-local@$GCL_VERSION" &&
        sh_link gitlab-ci-local ../npm/node_modules/.bin/gitlab-ci-local ;;
    glab-tui) run cargo install --locked --version "$GLABTUI_VERSION" --root "$PREFIX/cargo" glab-tui-crate && sh_link glab-tui ../cargo/bin/glab-tui ;;
    workmux) run cargo install --locked --version "$WORKMUX_VERSION" --root "$PREFIX/cargo" workmux && sh_link workmux ../cargo/bin/workmux ;;
  esac
}

sh_need() { # the program a tool is built with
  case $1 in
    lazysql|gh-dash) echo go ;;
    posting) echo python3 ;;
    gitlab-ci-local) echo npm ;;
    glab-tui|workmux) echo cargo ;;
  esac
}

shared_main() {
  local name stale=() missing_prog=() bad=0 want_v have_v stamp
  stamp=$(shared_stamp)
  if [[ $MODE == stamp ]]; then echo "$stamp"; return 0; fi
  for name in $SHARED_TOOLS; do
    want "$name" || continue
    want_v=$(sh_pin "$name"); have_v=$(sh_have "$name")
    if [[ $have_v == "$want_v" ]]; then
      [[ $MODE == check ]] || log "$name $have_v present (pin $want_v)"
    else
      stale+=("$name")
      [[ $MODE == check ]] && echo "$name: ${have_v:-missing} (pin $want_v)"
    fi
  done
  if [[ $MODE == check ]]; then
    ((${#stale[@]} == 0)) || return 1
    [[ -n $ONLY || $(sed -n 's/^stamp=//p' "$PREFIX/.ready" 2>/dev/null) == "$stamp" ]] && return 0
    echo "stamp: $PREFIX/.ready does not match the pins"
    return 1
  fi
  if ((! DRY)); then
    [[ -d $PREFIX && -w $PREFIX ]] || { warn "$PREFIX is missing or not writable for $(id -un): sudo ./apply-system.sh --only users creates it, then run this as the owner"; return 1; }
    [[ $(id -u) -ne 0 ]] || { warn "run --shared as the owner, not as root (the tree must belong to the owner)"; return 1; }
  fi
  umask 022
  for name in "${stale[@]}"; do
    have "$(sh_need "$name")" || { warn "$(sh_need "$name") is not installed: $name skipped"; missing_prog+=("$name"); continue; }
    log "$name: installing $(sh_pin "$name") into $PREFIX"
    sh_install "$name" || { warn "$name: install failed"; bad=1; }
  done
  if ((! DRY)); then
    chmod -R go-w,go+rX "$PREFIX" 2>/dev/null
    # .ready only when the whole set is right (a --only run or a failed tool keeps the old stamp, so --check stays red)
    if [[ -z $ONLY ]] && ((bad == 0)) && ((${#missing_prog[@]} == 0)); then
      printf 'stamp=%s\ntime=%s\n' "$stamp" "$(date -Is)" >"$PREFIX/.ready"
      for name in $SHARED_TOOLS; do printf '%s=%s\n' "$name" "$(sh_pin "$name")" >>"$PREFIX/.ready"; done
      chmod 644 "$PREFIX/.ready"
      log "$PREFIX/.ready written"
    fi
  fi
  ((bad == 0)) && ((${#missing_prog[@]} == 0))
}

if ((SHARED)); then
  shared_main
  exit $?
fi

want lazysql && step_go lazysql github.com/jorgerojas26/lazysql "$LAZYSQL_VERSION" lazysql
want gh-dash && step_go gh-dash github.com/dlvhdr/gh-dash/v4 "$GHDASH_VERSION" gh-dash
want posting && step_posting
want gitlab-ci-local && step_gcl
want glab-tui && step_glabtui && step_glabtui_config
want glab && step_glab
exit 0
