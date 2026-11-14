#!/bin/bash
# Runs in place of the Codex binary as tini's child: start the model router,
# wait until it answers, then hand the terminal over to Codex. Codex talks to
# the router as the base_url of every provider; the router forwards by the model
# named in each request, which is what makes /model able to switch servers.
# Started by wrapCodex.sh, which copies this file next to the router.
set -u

port="${CODEX_ROUTER_PORT:-8777}"
router_log="${CODEX_HOME:-$HOME/.codex}/model-router.log"
here="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

mkdir -p "$(dirname "$router_log")" 2>/dev/null
CODEX_ROUTER_ROUTES="${CODEX_ROUTER_ROUTES:-$here/routes.json}"
export CODEX_ROUTER_ROUTES
python3 "$here/codex-model-router.py" >>"$router_log" 2>&1 &
router=$!

for _ in $(seq 100); do
  curl -fsS -m 1 "http://127.0.0.1:$port/health" >/dev/null 2>&1 && break
  kill -0 "$router" 2>/dev/null || break
  sleep 0.1
done
if ! curl -fsS -m 1 "http://127.0.0.1:$port/health" >/dev/null 2>&1; then
  echo "wrapCodex: model router is not answering on port $port; see $router_log" >&2
fi

exec "${CODEX_ROUTER_BIN:-/global/npm/bin/codex}" "$@"
