#!/usr/bin/env bash
# Launch Charm's Crush, locked down, inside an Apple `container` VM.
# See lockdown-common.sh for exactly what the sandbox can and cannot reach.
#
#   - ~/.config/crush/crush.json is copied fresh each launch (host is the
#     source of truth) and mounted read-only, so Crush cannot loosen its own
#     permissions. The rest of ~/.config is not visible.
#   - Crush's data dir (sessions, model picks) lives on the host in
#     $WRAPCRUSH_STATE/data (default ~/.crush-container/data), never in
#     ~/.local/share/crush. It is seeded once from the host's model choices.
#   - Global instructions (~/.claude/CLAUDE.md plus AGENTS_container.md) are
#     added to Crush's context_paths.
#
# Usage: wrapCrush.sh [--rebuild] [--install] [--shell] [crush args...]
#   --rebuild  rebuild the image first
#   --install  install/upgrade Crush into /global/npm (only mode with /global rw)
#   --shell    start bash in the sandbox instead of crush (args go to bash)
#
# Env overrides: WRAPCRUSH_STATE, WRAPAGENT_IMAGE, WRAPAGENT_CPUS,
#                WRAPAGENT_MEMORY, WRAPCLAUDE_GLOBAL
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

AGENT=Crush
AGENT_PKG=@charmland/crush
AGENT_BIN=crush
STATE_DIR="${WRAPCRUSH_STATE:-$HOME/.crush-container}"

# shellcheck source=lockdown-common.sh
source "$SCRIPT_DIR/lockdown-common.sh"

agent_setup() {
  local host_cfg="$HOME/.config/crush/crush.json"
  local host_data="$HOME/.local/share/crush/crush.json"
  local agents_md="$CHOME/.config/crush/AGENTS.md"

  mkdir -p "$STATE_DIR/config" "$STATE_DIR/data"
  write_instructions "$STATE_DIR/config/AGENTS.md"
  if [[ -f "$host_cfg" ]]; then
    jq --arg p "$agents_md" '.options.context_paths = ((.options.context_paths // []) + [$p] | unique)' \
      "$host_cfg" > "$STATE_DIR/config/crush.json"
  else
    jq -n --arg p "$agents_md" '{options: {context_paths: [$p]}}' > "$STATE_DIR/config/crush.json"
  fi
  if [[ ! -f "$STATE_DIR/data/crush.json" && -f "$host_data" ]]; then
    jq '{models, recent_models}' "$host_data" > "$STATE_DIR/data/crush.json"
  fi

  run_args+=(
    --mount "type=bind,source=$STATE_DIR/config,target=$CHOME/.config/crush,readonly"
    --volume "$STATE_DIR/data:$CHOME/.local/share/crush"
  )
}

lockdown_main "$@"
