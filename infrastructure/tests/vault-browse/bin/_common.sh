# shellcheck shell=bash
# shared by the fake rbw / bw / helpers: FAKE_DIR holds the state; every call logs its argv (never stdin)
: "${FAKE_DIR:?FAKE_DIR is not set}"
log_argv() { printf '%s %s\n' "$1" "${*:2}" >>"$FAKE_DIR/argv.log"; }
vault() { cat "$FAKE_DIR/vault.json"; }
save_vault() { cat >"$FAKE_DIR/vault.json.tmp" && mv "$FAKE_DIR/vault.json.tmp" "$FAKE_DIR/vault.json"; }
