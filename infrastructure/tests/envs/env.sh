# shellcheck shell=bash
# Source this to try `envs` against the FAKE vault (rbw, bw, pinentry, wl-copy, mise, logger from tests/): never the real one.
#   . infrastructure/tests/envs/env.sh     (prints the scratch directory; ENVS_TEST_ROOT=DIR reuses one)
# It refuses to be sourced (or run) when `rbw` on PATH is not the fake after setting the PATH, so a typo cannot reach the real vault.
_E_HERE=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
_E_BIN="$_E_HERE/bin" _E_VB="$_E_HERE/../vault-browse/bin"
ENVS_TEST_ROOT=${ENVS_TEST_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/envs-test.XXXXXX")}
if ((${#ENVS_TEST_ROOT} > 80)); then   # bw-serve listens on a unix socket `<root>/run/vault/bw.sock`: sun_path holds 107 bytes
  echo "env.sh: $ENVS_TEST_ROOT is too long for the bw-serve unix socket (AF_UNIX path limit); use a short TMPDIR or ENVS_TEST_ROOT=/tmp/ev.XXXX" >&2
  return 1 2>/dev/null || exit 1
fi
export ENVS_TEST_ROOT
export FAKE_DIR="$ENVS_TEST_ROOT/fake" XDG_RUNTIME_DIR="$ENVS_TEST_ROOT/run" XDG_STATE_HOME="$ENVS_TEST_ROOT/state" \
  XDG_CACHE_HOME="$ENVS_TEST_ROOT/cache"   # XDG_CONFIG_HOME stays real: fzf-menu reads ~/.config/fzf/vimfzf.sh from it
export PATH="$_E_BIN:$_E_VB:/usr/bin:/bin"
if [[ $(command -v rbw) != "$_E_VB/rbw" || $(command -v bw) != "$_E_VB/bw" ]]; then
  echo "env.sh: rbw/bw on PATH are not the fakes: refusing" >&2
  return 1 2>/dev/null || exit 1
fi
mkdir -p "$FAKE_DIR" "$XDG_RUNTIME_DIR/vault" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$ENVS_TEST_ROOT/dl"
chmod 700 "$XDG_RUNTIME_DIR" "$XDG_RUNTIME_DIR/vault"
[[ -f $FAKE_DIR/vault.json ]] || cp "$_E_HERE/fixture.json" "$FAKE_DIR/vault.json"
echo '{"email":"test@example.com"}' >"$FAKE_DIR/rbw.json"
: >"$XDG_RUNTIME_DIR/wayland-test"
export ENVS_TOOL_PATH="$_E_BIN:$_E_VB" RBW_BIN=rbw BW_BIN=bw PINENTRY_BIN="$_E_VB/pinentry" VAULT_RBW_CONF="$FAKE_DIR/rbw.json" \
  VAULT_BW_LAUNCH=popen VAULT_BW_SERVE_POLL=0.3 VAULT_BW_RBW_POLL=0.3 VAULT_BW_NODUMP=0 VAULT_CLEAR_AFTER=6 BW_DOWNLOAD_DIR="$ENVS_TEST_ROOT/dl" \
  WAYLAND_DISPLAY=wayland-test ENVS_TEST_ROOT_PID=$$ FAKE_MISE_LOG="$FAKE_DIR/mise.log"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export ENVS_GLOBAL_DIR="$ENVS_TEST_ROOT/global"   # the global scope (envs run -g) of the sandbox: empty = no global project
export FZF_MENU_NO_SERVER=1
unset CLAUDECODE TMUX TMUX_PANE
echo "envs test sandbox: $ENVS_TEST_ROOT"
