#!/usr/bin/env bash
# run.sh — start an HDLTool app from source (no build):  ./run.sh hdl-simulator|hdl-viewer|hdlphy [files or folders]
# Installs the npm dependencies (and downloads Electron) on first use.
set -euo pipefail
HERE=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd -P)
[ -x "$HOME/eda/tools/node/bin/node" ] && export PATH="$HOME/eda/tools/node/bin:$PATH"
case "${1:-}" in
    hdl-simulator|simulator) dir=HDLSimulator ;;
    hdl-viewer|viewer) dir=HDLViewer ;;
    hdlphy|phy) dir=HDLPhy ;;
    *) echo "usage: $0 hdl-simulator|hdl-viewer|hdlphy [files or folders]" >&2; exit 2 ;;
esac
shift
args=()
for a in "$@"; do case "$a" in -*) args+=("$a") ;; *) args+=("$(readlink -f "$a" 2> /dev/null || echo "$a")") ;; esac; done
cd "$HERE/$dir"
if [ ! -x node_modules/electron/dist/electron ]; then
    npm install --no-fund --no-audit > /dev/null
    node node_modules/electron/install.js
fi
# chrome-sandbox in node_modules is not setuid root, so run without the Chromium sandbox (local pages only)
exec node_modules/electron/dist/electron . --no-sandbox "${args[@]}"
