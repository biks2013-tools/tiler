#!/bin/zsh
# Send a command to the running Tiler: toggle [display-uuid|active] | retile | reload | settings | shortcuts | moveresize | unminimize | nextdesktop | previousdesktop | here | dump
# `dump` writes to the unified log:
#   log show --last 1m --predicate 'subsystem == "com.giorgosmarinos.tiler"' --info
set -euo pipefail
[[ $# -ge 1 ]] || { echo "usage: $0 toggle [display-uuid|active] | retile | reload | settings | shortcuts | moveresize | unminimize | nextdesktop | previousdesktop | here | dump" >&2; exit 1; }
BIN="${TILER_BIN:-/Applications/Tiler.app/Contents/MacOS/Tiler}"
[[ -x "$BIN" ]] || { echo "error: Tiler binary not found at $BIN (set TILER_BIN)" >&2; exit 1; }
"$BIN" --send "$*"
