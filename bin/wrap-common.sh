# Shared launcher for every agent sandbox (wrapClaude.sh, wrapCodex.sh,
# wrapCrush.sh). Sourced, not executed. The caller sets:
#
#   AGENT            short name, used in messages and the state dir name
#   AGENT_PKG        npm package that provides the agent
#   AGENT_BIN        command name the package installs
#   AGENT_ARGS       optional array of args always passed to the agent
#   AGENT_KEEP_CAPS  optional, 1 = do not drop Linux capabilities
#   AGENT_LAUNCHER   optional array, runs in place of the agent binary
#   agent_setup      function: fills $SESSION_DIR and appends to run_args
#   agent_finish     optional function, called as `agent_finish DIR PID` when
#                    a session ends: saves what should outlive it to $SEED_DIR
#
# Everything lives on the ClaudeGlobal volume. Nothing is written to $HOME,
# and the working directory gets nothing but the work itself.
#
#   $GLOBAL_DIR/toolkit/                the tool repo: agents and shared tools.
#                                       Mounted at /global, READ-ONLY, in every
#                                       session. Only --install and --toolkit
#                                       mount it read-write, and then nothing
#                                       else from the host is mounted.
#   $GLOBAL_DIR/state/<agent>/seed/     what a new session starts from (login,
#                                       model picks)
#   $GLOBAL_DIR/state/<agent>/shared/   history that sessions only ever add
#                                       their own files to
#   $GLOBAL_DIR/state/<agent>/sessions/<id>/
#                                       one per running session, private to
#                                       it, removed when it ends
#
# Sessions never write to a file another running session writes to, so any
# number of them can run at once, same agent or not. File locks do not cross
# VMs, so the little locking there is happens here on the host.
#
# Not passed in unless a wrapper adds it: ~/.config, AWS credentials, SSH
# keys, Anthropic tokens. GitHub is the exception (see github-common.sh).

IMAGE="${WRAPAGENT_IMAGE:-claude-sandbox:latest}"
# `container build -t NAME` stores the image as docker.io/library/NAME, but
# `container run NAME` prefers an image stored under the bare name, and one
# built by an older `container` can still be lying around. Use the name the
# build writes, so a launch runs what was just built.
[[ $IMAGE == */* ]] || IMAGE="docker.io/library/$IMAGE"
CPUS="${WRAPAGENT_CPUS:-4}"
MEMORY="${WRAPAGENT_MEMORY:-4G}"
GLOBAL_DIR="${WRAPCLAUDE_GLOBAL:-/Volumes/ClaudeGlobal}"
TOOLKIT_DIR="$GLOBAL_DIR/toolkit"
STATE_ROOT="$GLOBAL_DIR/state"
AGENT_STATE="${AGENT_STATE:-$STATE_ROOT/$(tr '[:upper:]' '[:lower:]' <<< "$AGENT")}"
SEED_DIR="$AGENT_STATE/seed"
SHARED_DIR="$AGENT_STATE/shared"
SESSION_DIR="$AGENT_STATE/sessions/$(date +%Y%m%d-%H%M%S)-$$"
WORKDIR="$(pwd -P)"
CHOME=/home/claude
session_started=0

# shellcheck source=github-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/github-common.sh"

die() { echo "wrap$AGENT: $*" >&2; exit 1; }

# Is the launcher with this pid still running?
pid_alive() { ps -p "$1" >/dev/null 2>&1; }

# Host-side locks: a directory holding the owner's pid. A lock whose owner is
# gone is taken over, so a crashed launcher never blocks the next one.
lock_try() {
  local lock="$1" pid
  if ! mkdir "$lock" 2>/dev/null; then
    pid="$(cat "$lock/pid" 2>/dev/null || true)"
    [[ $pid == "$$" ]] && return 0
    if [[ -z $pid ]] || pid_alive "$pid"; then
      return 1
    fi
    rm -rf "$lock"
    mkdir "$lock" 2>/dev/null || return 1
  fi
  echo "$$" > "$lock/pid"
}

lock_acquire() {
  local lock="$1" i=0
  until lock_try "$lock"; do
    if [[ $i -eq 10 ]]; then
      echo "wrap$AGENT: waiting for ${lock##*/} (held by pid $(cat "$lock/pid" 2>/dev/null || echo '?'))..." >&2
    fi
    [[ $i -lt 4500 ]] || die "gave up waiting for $lock; remove it if nothing is using it."
    i=$((i + 1))
    sleep 0.2
  done
}

# Releases only a lock still owned by pid $2 (default: this launcher).
lock_release() {
  local lock="$1" owner="${2:-$$}"
  if [[ "$(cat "$lock/pid" 2>/dev/null || true)" == "$owner" ]]; then
    rm -rf "$lock"
  fi
}

# seed_load NAME DESTDIR: copy a seed file into a new session.
seed_load() {
  if [[ -f "$SEED_DIR/$1" ]]; then
    cp -p "$SEED_DIR/$1" "$2/$1"
  fi
}

# seed_save FILE: keep a session's file for future sessions, if the session
# changed it. Concurrent sessions each end with their own copy; newest wins.
seed_save() {
  local src="$1" dst
  dst="$SEED_DIR/${src##*/}"
  if [[ -f $src && ( ! -f $dst || $src -nt $dst ) ]]; then
    mkdir -p "$SEED_DIR"
    cp -p "$src" "$dst.tmp.$$" && mv "$dst.tmp.$$" "$dst"
  fi
}

# Global instructions for the agent: the host's CLAUDE.md plus notes about
# this sandbox ($2, default AGENTS_container.md).
write_instructions() {
  local notes="$REPO_DIR/${2:-AGENTS_container.md}"
  cat "$HOME/.claude/CLAUDE.md" "$notes" > "$1" 2>/dev/null || cp "$notes" "$1"
}

# The volume used to hold the tools at its top level, mounted whole. Move
# them under toolkit/ once, so state can sit beside them without being
# visible at /global. Sessions started on the old layout may still be running
# with the whole volume at /global, so each moved entry leaves a relative
# symlink behind (npm -> toolkit/npm) and their paths keep resolving. The
# marker makes an interrupted move resume on the next launch.
toolkit_migrated() { [[ -d $TOOLKIT_DIR && ! -e $STATE_ROOT/toolkit.migrating ]]; }

migrate_toolkit() {
  toolkit_migrated && return 0
  local e name
  echo "wrap$AGENT: moving the tools in $GLOBAL_DIR into $TOOLKIT_DIR (one time)." >&2
  : > "$STATE_ROOT/toolkit.migrating"
  mkdir -p "$TOOLKIT_DIR"
  for e in "$GLOBAL_DIR"/*; do
    name="${e##*/}"
    case "$name" in
      toolkit|state|'*') continue ;;
    esac
    [[ -L $e ]] && continue
    mv "$e" "$TOOLKIT_DIR/$name"
    ln -s "toolkit/$name" "$e"
  done
  rm -f "$STATE_ROOT/toolkit.migrating"
}

# Every launch runs the image built from the current Dockerfile: it is rebuilt
# when the Dockerfile changed since the last build (or on --rebuild). Running
# sessions keep the image they started on.
ensure_image() {
  local force="$1" stamp="$STATE_ROOT/image.stamp" want
  want="$(shasum -a 256 < "$REPO_DIR/Dockerfile" | cut -d' ' -f1) $(id -u):$(id -g) $IMAGE"
  image_current() {
    [[ "$(cat "$stamp" 2>/dev/null || true)" == "$want" ]] \
      && container image inspect "$IMAGE" >/dev/null 2>&1
  }
  if [[ $force -eq 0 ]] && image_current; then
    return 0
  fi
  lock_acquire "$STATE_ROOT/image.lock"
  # Another launcher may have built it while this one waited.
  if [[ $force -eq 1 ]] || ! image_current; then
    container build \
      --build-arg USER_UID="$(id -u)" \
      --build-arg USER_GID="$(id -g)" \
      -t "$IMAGE" \
      -f "$REPO_DIR/Dockerfile" \
      "$REPO_DIR" || { lock_release "$STATE_ROOT/image.lock"; die "image build failed."; }
    echo "$want" > "$stamp"
  fi
  lock_release "$STATE_ROOT/image.lock"
}

# Run something with the toolkit mounted read-write and nothing else from the
# host. One at a time. $1 is the entrypoint, the rest its arguments.
toolkit_run() {
  local entry="$1" rc=0
  shift
  local -a args=(
    --rm --cpus "$CPUS" --memory "$MEMORY"
    --volume "$TOOLKIT_DIR:/global"
    --env NPM_CONFIG_PREFIX=/global/npm
    --env CARGO_HOME=/global/cargo
    --env GOPATH=/global/go
    --interactive
  )
  if [[ -t 0 && -t 1 ]]; then
    args+=(--tty)
  fi
  lock_acquire "$STATE_ROOT/toolkit.lock"
  container run "${args[@]}" --entrypoint "$entry" "$IMAGE" "$@" || rc=$?
  lock_release "$STATE_ROOT/toolkit.lock"
  return "$rc"
}

# End a session: let the agent save what should outlive it, then drop it.
# Call with $AGENT_STATE/lock held.
finish_session() {
  local dir="$1" pid
  [[ $dir == "$AGENT_STATE/sessions/"?* && -d $dir ]] || return 0
  pid="$(cat "$dir/pid" 2>/dev/null || true)"
  if declare -F agent_finish >/dev/null; then
    agent_finish "$dir" "$pid" || true
  fi
  rm -rf "$dir"
}

# Sessions whose launcher died without cleaning up (crash, reboot).
reap_sessions() {
  local d pid
  for d in "$AGENT_STATE/sessions"/*/; do
    d="${d%/}"
    [[ -d $d ]] || continue
    pid="$(cat "$d/pid" 2>/dev/null || true)"
    if [[ -n $pid ]] && pid_alive "$pid"; then
      continue
    fi
    finish_session "$d"
  done
}

on_exit() {
  trap - EXIT
  [[ $session_started -eq 1 ]] || return 0
  lock_acquire "$AGENT_STATE/lock"
  finish_session "$SESSION_DIR"
  lock_release "$AGENT_STATE/lock"
}

wrap_main() {
  local rebuild=0 shell=0 install=0 toolkit=0 rc=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --rebuild) rebuild=1; shift ;;
      --shell)   shell=1; shift ;;
      --install) install=1; shift ;;
      --toolkit) toolkit=1; shift ;;
      *) break ;;
    esac
  done

  if ! container system status >/dev/null 2>&1; then
    container system start
  fi

  [[ -d "$GLOBAL_DIR" ]] || die "global dir $GLOBAL_DIR not found (is the ClaudeGlobal volume mounted?)."
  mkdir -p "$STATE_ROOT"
  if ! toolkit_migrated; then
    lock_acquire "$STATE_ROOT/toolkit.lock"
    migrate_toolkit
    lock_release "$STATE_ROOT/toolkit.lock"
  fi
  ensure_image "$rebuild"

  if [[ $install -eq 1 ]]; then
    toolkit_run npm install -g "$AGENT_PKG@latest" || rc=$?
    exit "$rc"
  fi
  if [[ $toolkit -eq 1 ]]; then
    toolkit_run bash "$@" || rc=$?
    exit "$rc"
  fi

  if [[ "$WORKDIR" == "$HOME" || "$WORKDIR" == "/" || "$WORKDIR" == "$GLOBAL_DIR"* ]]; then
    die "refusing to expose $WORKDIR to the sandbox; cd into a project dir first."
  fi
  if [[ ! -e "$TOOLKIT_DIR/npm/bin/$AGENT_BIN" && $shell -eq 0 ]]; then
    echo "wrap$AGENT: $AGENT_BIN is not in the toolkit yet; installing it." >&2
    toolkit_run npm install -g "$AGENT_PKG@latest" \
      || die "could not install $AGENT_PKG; retry with: $(basename "$0") --install"
  fi

  run_args=(
    --rm
    --cpus "$CPUS"
    --memory "$MEMORY"
    --volume "$WORKDIR:$WORKDIR"
    --mount "type=bind,source=$TOOLKIT_DIR,target=/global,readonly"
    --workdir "$WORKDIR"
    --env TERM="${TERM:-xterm-256color}"
    --env COLORTERM="${COLORTERM:-}"
    # /global is read-only, so package managers install to the VM's own disk.
    --env NPM_CONFIG_PREFIX="$CHOME/.local/npm"
    --env CARGO_HOME="$CHOME/.local/cargo"
    --env GOPATH="$CHOME/.local/go"
    --env GOFLAGS=-modcacherw
    # Keep .pyc files out of the working directory.
    --env PYTHONDONTWRITEBYTECODE=1
  )
  if [[ ${AGENT_KEEP_CAPS:-0} != 1 ]]; then
    run_args+=(--cap-drop ALL)
  fi

  # GitHub: token + git config via env vars (see github-common.sh).
  GITHUB_ENABLED="${WRAPAGENT_GITHUB:-1}"
  github_setup

  # This session's private state. From here on the launcher stays around
  # (no exec) so it can clean up when the agent exits.
  mkdir -p "$AGENT_STATE/sessions" "$SEED_DIR" "$SHARED_DIR"
  trap on_exit EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  lock_acquire "$AGENT_STATE/lock"
  reap_sessions
  mkdir -p "$SESSION_DIR"
  echo "$$" > "$SESSION_DIR/pid"
  session_started=1
  agent_setup
  lock_release "$AGENT_STATE/lock"

  if [[ -t 0 && -t 1 ]]; then
    run_args+=(--interactive --tty)
  else
    run_args+=(--interactive)
  fi

  if [[ $shell -eq 1 ]]; then
    container run "${run_args[@]}" --entrypoint bash "$IMAGE" "$@" || rc=$?
    exit "$rc"
  fi
  # A wrapper may set AGENT_LAUNCHER to a command that stands in for the agent
  # binary (Codex uses it to start its model router first). Arguments are
  # unchanged either way.
  local -a agent_cmd=("/global/npm/bin/$AGENT_BIN")
  if [[ -n ${AGENT_LAUNCHER[0]-} ]]; then
    agent_cmd=("${AGENT_LAUNCHER[@]}")
  fi
  container run "${run_args[@]}" --entrypoint /usr/bin/tini "$IMAGE" \
    -- "${agent_cmd[@]}" ${AGENT_ARGS[@]+"${AGENT_ARGS[@]}"} "$@" || rc=$?
  exit "$rc"
}
