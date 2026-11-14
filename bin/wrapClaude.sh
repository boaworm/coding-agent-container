#!/usr/bin/env bash
# Launch Claude Code inside an Apple `container` VM.
#
#   - The current directory is the only writable host path Claude can see.
#   - ~/.config is mounted read-only.
#   - Claude's own state (login, history, settings) lives in a separate dir
#     on the host ($WRAPCLAUDE_STATE, default ~/.claude-container), so the
#     sandbox never touches your real ~/.claude.
#   - $WRAPCLAUDE_GLOBAL (default /Volumes/ClaudeGlobal, a case-sensitive
#     APFS volume) is mounted read-write at /global in every session, for
#     files and tools shared between projects.
#     /global/bin and /global/npm/bin (npm install -g) are on PATH.
#   - AWS: short-lived credentials for $AWS_PROFILE (or "default") are minted
#     on the host at launch and passed in as env vars. Long-lived keys are
#     never passed; they are exchanged for an STS session token first.
#     Set WRAPCLAUDE_AWS=0 to disable.
#   - GitHub: the host's gh login (or $GH_TOKEN / $GITHUB_TOKEN) is passed in
#     as GH_TOKEN, and git is configured through GIT_CONFIG_* env vars to use
#     it for github.com over HTTPS. See github-common.sh.
#     Set WRAPCLAUDE_GITHUB=0 to disable.
#   - The container is a separate VM: host processes are invisible to it and
#     cannot be signalled from inside.
#
# Usage: wrapClaude.sh [--rebuild] [--shell] [claude args...]
#   --rebuild  rebuild the image first
#   --shell    start bash in the sandbox instead of claude (args go to bash)
#
# Env overrides: WRAPCLAUDE_IMAGE, WRAPCLAUDE_STATE, WRAPCLAUDE_GLOBAL,
#                WRAPCLAUDE_CPUS, WRAPCLAUDE_MEMORY, WRAPCLAUDE_AWS,
#                WRAPCLAUDE_AWS_DURATION (seconds, for long-lived keys),
#                WRAPCLAUDE_GITHUB
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck source=github-common.sh
source "$SCRIPT_DIR/github-common.sh"

IMAGE="${WRAPCLAUDE_IMAGE:-claude-sandbox:latest}"
STATE_DIR="${WRAPCLAUDE_STATE:-$HOME/.claude-container}"
CPUS="${WRAPCLAUDE_CPUS:-4}"
MEMORY="${WRAPCLAUDE_MEMORY:-4G}"
GLOBAL_DIR="${WRAPCLAUDE_GLOBAL:-/Volumes/ClaudeGlobal}"
WORKDIR="$(pwd -P)"

if [[ "$WORKDIR" == "$HOME" || "$WORKDIR" == "/" ]]; then
  echo "wrapClaude: refusing to expose $WORKDIR to the sandbox; cd into a project dir first." >&2
  exit 1
fi

rebuild=0
shell=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rebuild) rebuild=1; shift ;;
    --shell)   shell=1; shift ;;
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

if [[ ! -d "$GLOBAL_DIR" ]]; then
  echo "wrapClaude: global dir $GLOBAL_DIR not found (is the ClaudeGlobal volume mounted?)." >&2
  exit 1
fi
mkdir -p "$STATE_DIR" "$GLOBAL_DIR/bin"

# Bring in the host's user-level Claude config. Settings and CLAUDE.md are
# copied fresh each launch (host is the source of truth; edits made inside
# the sandbox are overwritten next time). Hooks and skills are mounted
# read-only so the sandboxed Claude cannot weaken its own guardrails.
# History, transcripts and credentials from the host are NOT exposed.
HOST_CLAUDE="$HOME/.claude"
for f in settings.json settings.local.json; do
  if [[ -f "$HOST_CLAUDE/$f" ]]; then
    cp "$HOST_CLAUDE/$f" "$STATE_DIR/$f"
  else
    rm -f "$STATE_DIR/$f"
  fi
done
# The sandbox's CLAUDE.md is the host's global one plus container-specific
# notes, so Claude knows it is on Linux and how to get software installed.
cat "$HOST_CLAUDE/CLAUDE.md" "$REPO_DIR/CLAUDE_container.md" \
  > "$STATE_DIR/CLAUDE.md" 2>/dev/null || true
config_mounts=()
for d in hooks skills; do
  if [[ -d "$HOST_CLAUDE/$d" ]]; then
    mkdir -p "$STATE_DIR/$d"
    config_mounts+=(--mount "type=bind,source=$HOST_CLAUDE/$d,target=/home/claude/.claude/$d,readonly")
  fi
done

run_args=(
  --rm
  --cpus "$CPUS"
  --memory "$MEMORY"
  --volume "$WORKDIR:$WORKDIR"
  --mount "type=bind,source=$HOME/.config,target=/home/claude/.config,readonly"
  --volume "$STATE_DIR:/home/claude/.claude"
  --volume "$GLOBAL_DIR:/global"
  "${config_mounts[@]}"
  --workdir "$WORKDIR"
  --env TERM="${TERM:-xterm-256color}"
  --env COLORTERM="${COLORTERM:-}"
  # No mouse capture: keep the terminal's own select/copy/paste working.
  --env CLAUDE_CODE_DISABLE_MOUSE=1
)

# Pass through auth tokens if set on the host; otherwise log in once inside
# the container and the credentials persist in $STATE_DIR.
for var in ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN; do
  [[ -n "${!var:-}" ]] && run_args+=(--env "$var")
done

# AWS: export short-lived credentials into this script's environment and
# have the container inherit them by name, so secrets never appear in argv.
aws_profile="${AWS_PROFILE:-default}"
if [[ "${WRAPCLAUDE_AWS:-1}" != 0 ]] && command -v aws >/dev/null 2>&1; then
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  if creds="$(aws configure export-credentials --profile "$aws_profile" --format env-no-export 2>/dev/null)"; then
    while IFS='=' read -r key value; do
      case "$key" in
        AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY|AWS_SESSION_TOKEN) export "$key=$value" ;;
      esac
    done <<< "$creds"
    if [[ -z "${AWS_SESSION_TOKEN:-}" ]]; then
      # Long-lived IAM keys: trade them for a session token instead.
      if sts="$(aws sts get-session-token --profile "$aws_profile" \
                  --duration-seconds "${WRAPCLAUDE_AWS_DURATION:-43200}" \
                  --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
                  --output text 2>/dev/null)"; then
        read -r AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN <<< "$sts"
        export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
      else
        unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
        echo "wrapClaude: could not get an STS session token for AWS profile '$aws_profile'; starting without AWS access." >&2
      fi
    fi
    if [[ -n "${AWS_SESSION_TOKEN:-}" ]]; then
      run_args+=(--env AWS_ACCESS_KEY_ID --env AWS_SECRET_ACCESS_KEY --env AWS_SESSION_TOKEN)
      if region="$(aws configure get region --profile "$aws_profile" 2>/dev/null)" && [[ -n "$region" ]]; then
        run_args+=(--env "AWS_REGION=$region" --env "AWS_DEFAULT_REGION=$region")
      fi
    fi
  else
    echo "wrapClaude: no AWS credentials for profile '$aws_profile' (expired login?); starting without AWS access." >&2
  fi
fi

# GitHub: token + git config via env vars (see github-common.sh).
GITHUB_ENABLED="${WRAPCLAUDE_GITHUB:-1}"
github_setup

if [[ $shell -eq 1 ]]; then
  run_args+=(--entrypoint bash)
fi

if [[ -t 0 && -t 1 ]]; then
  run_args+=(--interactive --tty)
else
  run_args+=(--interactive)
fi

exec container run "${run_args[@]}" "$IMAGE" "$@"
