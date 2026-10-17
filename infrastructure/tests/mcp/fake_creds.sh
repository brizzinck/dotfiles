#!/usr/bin/env bash
# fake creds-install: keeps the JSON payload it was given on stdin (the test inspects it)
cat >"$FAKE_DIR/creds-payload.json"
echo "creds-install called" >>"$FAKE_DIR/argv.log"
