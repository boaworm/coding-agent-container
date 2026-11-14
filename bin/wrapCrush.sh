#!/usr/bin/env bash
# Launch Charm's Crush inside an Apple `container` VM.
# See wrap-common.sh for the layout every wrapper shares: read-only toolkit
# at /global, one private state dir per session, nothing written to $HOME.
#
#   - ~/.config/crush/crush.json is copied fresh each launch (host is the
#     source of truth) and mounted read-only, so Crush cannot loosen its own
#     permissions. The rest of ~/.config is not visible.
#   - Crush's own data dir (model picks) is per session: copied from the seed,
#     saved back when the session ends. The seed starts from the host's picks.
#   - Crush's per-project data (the .crush directory: sessions db, logs) is
#     kept out of the working directory, in shared/projects/<hash of cwd>.
#     It is a SQLite db, so one session at a time owns it; a second Crush in
#     the same directory gets a private, throwaway one instead.
#   - Global instructions (~/.claude/CLAUDE.md plus AGENTS_container.md) are
#     added to Crush's context_paths.
#
# Usage: wrapCrush.sh [--rebuild] [--install] [--toolkit] [--shell] [crush args...]
#   --rebuild  rebuild the image first (automatic when the Dockerfile changed)
#   --install  install/upgrade Crush in the toolkit
#   --toolkit  bash with the toolkit mounted read-write and nothing else
#   --shell    start bash in the sandbox instead of crush (args go to bash)
#
# Env overrides: WRAPCRUSH_STATE, WRAPAGENT_IMAGE, WRAPAGENT_CPUS,
#                WRAPAGENT_MEMORY, WRAPAGENT_GITHUB, WRAPCLAUDE_GLOBAL
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

AGENT=Crush
AGENT_PKG=@charmland/crush
AGENT_BIN=crush
AGENT_STATE="${WRAPCRUSH_STATE:-}"

# shellcheck source=wrap-common.sh
source "$SCRIPT_DIR/wrap-common.sh"

agent_setup() {
  local host_cfg="$HOME/.config/crush/crush.json"
  local host_data="$HOME/.local/share/crush/crush.json"
  local legacy="$HOME/.crush-container/data/crush.json"
  local agents_md="$CHOME/.config/crush/AGENTS.md"
  local data_dir="$CHOME/.local/share/crush"
  local key project lock

  mkdir -p "$SESSION_DIR/config" "$SESSION_DIR/data/project"
  if [[ ! -f $SEED_DIR/crush.json ]]; then
    if [[ -f $legacy ]]; then
      cp -p "$legacy" "$SEED_DIR/crush.json"
    elif [[ -f $host_data ]]; then
      jq '{models, recent_models}' "$host_data" > "$SEED_DIR/crush.json"
    fi
  fi
  seed_load crush.json "$SESSION_DIR/data"

  # data_directory is where Crush would otherwise create .crush in the cwd.
  write_instructions "$SESSION_DIR/config/AGENTS.md"
  if [[ -f "$host_cfg" ]]; then
    jq --arg p "$agents_md" --arg d "$data_dir/project" \
      '.options.context_paths = ((.options.context_paths // []) + [$p] | unique)
       | .options.data_directory = $d' \
      "$host_cfg" > "$SESSION_DIR/config/crush.json"
  else
    jq -n --arg p "$agents_md" --arg d "$data_dir/project" \
      '{options: {context_paths: [$p], data_directory: $d}}' > "$SESSION_DIR/config/crush.json"
  fi

  key="$(printf '%s' "$WORKDIR" | shasum | cut -c1-16)"
  project="$SHARED_DIR/projects/$key"
  lock="$SHARED_DIR/locks/$key"
  mkdir -p "$SHARED_DIR/projects" "$SHARED_DIR/locks"
  if lock_try "$lock"; then
    mkdir -p "$project"
    printf '%s\n' "$lock" > "$SESSION_DIR/project.lock"
  else
    echo "wrapCrush: another Crush session is open in $WORKDIR; this one's session history will not be kept." >&2
    project="$SESSION_DIR/data/project"
  fi

  run_args+=(
    --mount "type=bind,source=$SESSION_DIR/config,target=$CHOME/.config/crush,readonly"
    --volume "$SESSION_DIR/data:$data_dir"
    --volume "$project:$data_dir/project"
  )
}

agent_finish() {
  local lock
  seed_save "$1/data/crush.json"
  if [[ -f $1/project.lock ]]; then
    lock="$(cat "$1/project.lock")"
    if [[ $lock == "$SHARED_DIR/locks/"?* ]]; then lock_release "$lock" "$2"; fi
  fi
}

wrap_main "$@"
