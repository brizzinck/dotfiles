#!/usr/bin/env bash
# User-level dev tools (DEV-d): terminal database / HTTP / forge / local-CI tools that are not repo packages. Never sudo; every
# step is skipped when the installed version is already at least the pin (the pins are the fresh-install floor: sysup moves
# these tools forward later with its go / pipx / npm / cargo steps), a failed step only warns.
#
#   infrastructure/dev/user-tools.sh [--dry-run] [--only NAME[,NAME]]     names: lazysql gh-dash posting gitlab-ci-local glab-tui glab
#
# Sources and why (see CLAUDE.md "Dev tools"): `go install module@tag` is verified by sum.golang.org and has no telemetry
# collector (the lazysql release builds ask once and send by default); pipx for posting, `npm install -g --ignore-scripts`
# for gitlab-ci-local, `cargo install --locked --version` for glab-tui. Repo packages (hurl, act, glab) come from
# apply-system.sh. No AUR *-bin packages.
set -u

LAZYSQL_VERSION=v0.7.0                 # github.com/jorgerojas26/lazysql
GHDASH_VERSION=v4.26.2                 # github.com/dlvhdr/gh-dash/v4
POSTING_VERSION=2.11.1                 # PyPI posting (pipx)
GCL_VERSION=4.76.1                     # npm gitlab-ci-local
GLABTUI_VERSION=0.9.3                  # crates.io glab-tui-crate (binary glab-tui)

DRY=0 ONLY=""
while (($#)); do
  case $1 in
    --dry-run) DRY=1 ;;
    --only) ONLY=${2:-}; shift ;;
    --only=*) ONLY=${1#--only=} ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "usage: user-tools.sh [--dry-run] [--only NAME[,NAME]]" >&2; exit 2 ;;
  esac
  shift
done

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
  if [[ -n $have_v ]] && ver_ge "$have_v" "$POSTING_VERSION"; then log "posting $have_v present (pin $POSTING_VERSION)"; return 0; fi
  log "posting: pipx install posting==$POSTING_VERSION"
  if [[ -n $have_v ]]; then run pipx install --force "posting==$POSTING_VERSION"; else run pipx install "posting==$POSTING_VERSION"; fi \
    || warn "posting: pipx install failed"
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

want lazysql && step_go lazysql github.com/jorgerojas26/lazysql "$LAZYSQL_VERSION" lazysql
want gh-dash && step_go gh-dash github.com/dlvhdr/gh-dash/v4 "$GHDASH_VERSION" gh-dash
want posting && step_posting
want gitlab-ci-local && step_gcl
want glab-tui && step_glabtui && step_glabtui_config
want glab && step_glab
exit 0
