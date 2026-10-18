# shellcheck shell=bash
# shared by the dev fakes: every call appends ONE line (argv, never an environment value) to $FAKE_DIR/dev.log;
# `hashes VAR...` logs sha256 prefixes of environment variables (so a test can compare a value without it being written down)
: "${FAKE_DIR:=$(cat "${XDG_RUNTIME_DIR:-/nonexistent}/devtools-fake-dir" 2>/dev/null)}"   # api scrubs FAKE_DIR from posting's environment
: "${FAKE_DIR:?FAKE_DIR is not set}"
dev_log() { printf '%s\n' "$*" >>"$FAKE_DIR/dev.log"; }
hashes() {
  local v out=""
  for v in "$@"; do
    if [[ -n ${!v+x} ]]; then out+=" $v=$(printf %s "${!v}" | sha256sum | cut -c1-16)"; else out+=" $v=unset"; fi
  done
  printf '%s' "${out# }"
}
# a fake that is meant to stay alive for a `ps` snapshot: FAKE_SLEEP=SECONDS
maybe_sleep() { [[ -n ${FAKE_SLEEP:-} ]] && sleep "$FAKE_SLEEP"; return 0; }
