#!/usr/bin/env bash
# fake picker: prints the rows whose id is listed in $FAKE_PICK_IDS (space separated)
rows=$(cat); : >"$FAKE_DIR/pick-rows.txt"; printf '%s\n' "$rows" >"$FAKE_DIR/pick-rows.txt"
for id in $FAKE_PICK_IDS; do grep -P "^$id\t" <<<"$rows"; done
