# Shared launcher for the locked-down agent sandboxes (wrapCodex.sh,
# wrapCrush.sh). Sourced, not executed. The caller sets:
#
#   AGENT        short name, used in messages and the default state dir
#   AGENT_PKG    npm package that provides the agent
#   AGENT_BIN    command name the package installs
#   AGENT_ARGS   optional array of args always passed to the agent
#   agent_setup  function: prepares $STATE_DIR and appends to run_args
#
# Compared with wrapClaude.sh, these sandboxes are deliberately stricter:
#   - /global is mounted READ-ONLY. The agent can run tools from it but cannot
#     plant or replace anything there (it is on Claude's PATH too).
#     npm/cargo/go installs go to the container's own disk and vanish at exit.
#   - ~/.config is NOT mounted. Only the agent's own config is copied in.
#   - No AWS credentials, no SSH agent, no Anthropic tokens, no host env
#     beyond what is listed explicitly. GitHub is the one exception: a token
#     from the host's gh login is passed in as GH_TOKEN so agents can read
#     from and push to GitHub (set WRAPAGENT_GITHUB=0 to disable; see
#     github-common.sh).
#   - All Linux capabilities are dropped.
#   - The current directory is still the one writable host path.
#
# The agent itself is installed into /global/npm by `--install`, which is the
# only mode that mounts /global read-write (and it mounts nothing else).

IMAGE="${WRAPAGENT_IMAGE:-claude-sandbox:latest}"
CPUS="${WRAPAGENT_CPUS:-4}"
MEMORY="${WRAPAGENT_MEMORY:-4G}"
GLOBAL_DIR="${WRAPCLAUDE_GLOBAL:-/Volumes/ClaudeGlobal}"
WORKDIR="$(pwd -P)"
CHOME=/home/claude

# shellcheck source=github-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/github-common.sh"

die() { echo "wrap$AGENT: $*" >&2; exit 1; }

lockdown_main() {
  local rebuild=0 shell=0 install=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --rebuild) rebuild=1; shift ;;
      --shell)   shell=1; shift ;;
      --install) install=1; shift ;;
      *) break ;;
    esac
  done

  if ! container system status >/dev/null 2>&1; then
    container system start
  fi

  if [[ $rebuild -eq 1 ]] || ! container image inspect "$IMAGE" >/dev/null 2>&1; then
    container build \
      --build-arg USER_UID="$(id -u)" \
      --build-arg USER_GID="$(id -g)" \
      -t "$IMAGE" \
      -f "$REPO_DIR/Dockerfile" \
      "$REPO_DIR"
  fi

  [[ -d "$GLOBAL_DIR" ]] || die "global dir $GLOBAL_DIR not found (is the ClaudeGlobal volume mounted?)."

  if [[ $install -eq 1 ]]; then
    # Only /global, read-write, and nothing from the host besides it.
    container run --rm --cpus "$CPUS" --memory "$MEMORY" \
      --volume "$GLOBAL_DIR:/global" \
      --entrypoint npm "$IMAGE" install -g "$AGENT_PKG@latest"
    exit $?
  fi

  if [[ "$WORKDIR" == "$HOME" || "$WORKDIR" == "/" || "$WORKDIR" == "$GLOBAL_DIR"* ]]; then
    die "refusing to expose $WORKDIR to the sandbox; cd into a project dir first."
  fi
  if [[ ! -e "$GLOBAL_DIR/npm/bin/$AGENT_BIN" && $shell -eq 0 ]]; then
    die "$AGENT_BIN is not installed in $GLOBAL_DIR; run: $(basename "$0") --install"
  fi

  mkdir -p "$STATE_DIR"

  run_args=(
    --rm
    --cpus "$CPUS"
    --memory "$MEMORY"
    --cap-drop ALL
    --volume "$WORKDIR:$WORKDIR"
    --mount "type=bind,source=$GLOBAL_DIR,target=/global,readonly"
    --workdir "$WORKDIR"
    --env TERM="${TERM:-xterm-256color}"
    --env COLORTERM="${COLORTERM:-}"
    # /global is read-only here, so point package managers at scratch space.
    --env NPM_CONFIG_PREFIX="$CHOME/.local/npm"
    --env CARGO_HOME="$CHOME/.local/cargo"
    --env GOPATH="$CHOME/.local/go"
    --env GOFLAGS=-modcacherw
  )

  # GitHub: token + git config via env vars (see github-common.sh).
  GITHUB_ENABLED="${WRAPAGENT_GITHUB:-1}"
  github_setup

  agent_setup

  if [[ -t 0 && -t 1 ]]; then
    run_args+=(--interactive --tty)
  else
    run_args+=(--interactive)
  fi

  if [[ $shell -eq 1 ]]; then
    exec container run "${run_args[@]}" --entrypoint bash "$IMAGE" "$@"
  fi
  # A wrapper may set AGENT_LAUNCHER to a command that stands in for the agent
  # binary (Codex uses it to start its model router first). Arguments are
  # unchanged either way.
  local -a agent_cmd=("/global/npm/bin/$AGENT_BIN")
  if [[ -n ${AGENT_LAUNCHER[0]-} ]]; then
    agent_cmd=("${AGENT_LAUNCHER[@]}")
  fi
  exec container run "${run_args[@]}" --entrypoint /usr/bin/tini "$IMAGE" \
    -- "${agent_cmd[@]}" ${AGENT_ARGS[@]+"${AGENT_ARGS[@]}"} "$@"
}

# Global instructions for the agent: the host's CLAUDE.md (the same rules
# Claude's hooks enforce, which these agents have no hooks for) plus notes
# about this sandbox.
write_instructions() {
  cat "$HOME/.claude/CLAUDE.md" "$REPO_DIR/AGENTS_container.md" > "$1" 2>/dev/null \
    || cp "$REPO_DIR/AGENTS_container.md" "$1"
}
