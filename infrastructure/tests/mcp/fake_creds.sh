#!/usr/bin/env bash
# fake creds-install: keeps the JSON payload it was given on stdin and its arguments (the test inspects them)
cat >"$FAKE_DIR/creds-payload.json"
echo "$*" >"$FAKE_DIR/creds-args.txt"
echo "creds-install called" >>"$FAKE_DIR/argv.log"
