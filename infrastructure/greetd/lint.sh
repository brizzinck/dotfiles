#!/usr/bin/env bash
# Lint the greeter QML with qmllint. qmllint does not know that Quickshell turns Theme.qml into a singleton, so the files are
# copied into a temp dir next to a generated qmldir first. Quickshell's QML modules are found through QML_IMPORT_PATH
# (the installed quickshell package provides /usr/lib/qt6/qml/Quickshell; set it for a scratch extraction).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cp -L "$here"/greeter/*.qml "$tmp"/
{
  echo "singleton Theme 1.0 Theme.qml"; echo "singleton Greeter 1.0 Greeter.qml"
  for f in "$tmp"/*.qml; do
    n="$(basename "$f" .qml)"
    case "$n" in Theme | Greeter | shell) ;; *) echo "$n 1.0 $n.qml" ;; esac
  done
} >"$tmp/qmldir"
args=(-I "$tmp")
for p in ${QML_IMPORT_PATH//:/ }; do args+=(-I "$p"); done
cd "$tmp"
# Two warnings are artefacts of linting outside Quickshell and are filtered: PanelWindow is "not creatable" without the layer-shell
# plugin loaded, and a pragma Singleton needs no qmldir at run time (Quickshell generates it).
out="$(/usr/lib/qt6/bin/qmllint "${args[@]}" "$@" ./*.qml 2>&1 || true)"
filtered="$(printf '%s\n' "$out" | grep -vE 'uncreatable-type|not declared as singleton in qmldir' || true)"
if printf '%s\n' "$filtered" | grep -qE '^(Warning|Error):'; then
  printf '%s\n' "$filtered"
  exit 1
fi
echo "qmllint: clean (2 known tool artefacts filtered)"
