#!/bin/sh
# Development loop: rebuild the frontend, run the server, restart on change.
#
#   tools/dev.sh [port]
set -eu
cd "$(dirname "$0")/.."
PORT="${1:-8080}"

zig build || exit 1
if [ ! -d frontend/node_modules ]; then
  (cd frontend && npm install)
fi
(cd frontend && npm run build >/dev/null)

echo "synoterm dev server on http://127.0.0.1:${PORT}/"
exec ./zig-out/bin/synoterm \
  --listen "${PORT}" \
  --auth dev \
  --web-root frontend/dist
