#!/usr/bin/env bash
# Launch Claude Code inside an Apple `container` VM.
# See wrap-common.sh for the layout every wrapper shares: read-only toolkit
# at /global, one private state dir per session, nothing written to $HOME.
#
# On top of that, Claude gets more of the host than Codex and Crush do:
#   - ~/.config is mounted read-only.
#   - The host's ~/.claude settings and CLAUDE.md are copied in each launch
#     (host is the source of truth); hooks and skills are mounted read-only so
#     the sandboxed Claude cannot weaken its own guardrails.
#   - AWS: short-lived credentials for $AWS_PROFILE (or "default") are minted
#     on the host at launch and passed in as env vars. Long-lived keys are
#     never passed; they are exchanged for an STS session token first.
#     Set WRAPCLAUDE_AWS=0 to disable.
#   - Linux capabilities are not dropped.
#
# State: login (.credentials.json), .claude.json and prompt history are copied
# from the seed into the session and saved back when it ends. Transcripts
# (projects/) are shared, one file per session, so --resume works everywhere.
# With several sessions open at once, a login token refreshed by one is not
# seen by the others; set CLAUDE_CODE_OAUTH_TOKEN (claude setup-token) on the
# host to avoid logins altogether.
#
# Usage: wrapClaude.sh [--rebuild] [--install] [--toolkit] [--shell] [claude args...]
#   --rebuild  rebuild the image first (automatic when the Dockerfile changed)
#   --install  install/upgrade Claude Code in the toolkit
#   --toolkit  bash with the toolkit mounted read-write and nothing else, for
#              adding shared tools (args go to bash)
#   --shell    start bash in the sandbox instead of claude (args go to bash)
#
# Env overrides: WRAPCLAUDE_IMAGE, WRAPCLAUDE_STATE, WRAPCLAUDE_GLOBAL,
#                WRAPCLAUDE_CPUS, WRAPCLAUDE_MEMORY, WRAPCLAUDE_AWS,
#                WRAPCLAUDE_AWS_DURATION (seconds, for long-lived keys),
#                WRAPCLAUDE_GITHUB
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

AGENT=Claude
AGENT_PKG=@anthropic-ai/claude-code
AGENT_BIN=claude
AGENT_KEEP_CAPS=1
AGENT_STATE="${WRAPCLAUDE_STATE:-}"
WRAPAGENT_IMAGE="${WRAPCLAUDE_IMAGE:-${WRAPAGENT_IMAGE:-}}"
WRAPAGENT_CPUS="${WRAPCLAUDE_CPUS:-${WRAPAGENT_CPUS:-}}"
WRAPAGENT_MEMORY="${WRAPCLAUDE_MEMORY:-${WRAPAGENT_MEMORY:-}}"
WRAPAGENT_GITHUB="${WRAPCLAUDE_GITHUB:-${WRAPAGENT_GITHUB:-}}"
# Copied into each session from the seed and saved back when it ends.
CLAUDE_SEED_FILES=(.claude.json .credentials.json history.jsonl)

# shellcheck source=wrap-common.sh
source "$SCRIPT_DIR/wrap-common.sh"

agent_setup() {
  local home="$SESSION_DIR/home" host="$HOME/.claude" legacy="$HOME/.claude-container"
  local f d var
  mkdir -p "$home" "$SHARED_DIR/projects"

  # State used to live in ~/.claude-container; bring the login and history
  # over once. The old directory is left alone.
  if [[ ! -e $SEED_DIR/.imported && -d $legacy ]]; then
    echo "wrapClaude: importing login and history from $legacy (it can be deleted afterwards)." >&2
    for f in "${CLAUDE_SEED_FILES[@]}"; do
      if [[ -f $legacy/$f ]]; then cp -p "$legacy/$f" "$SEED_DIR/$f"; fi
    done
    if [[ -d $legacy/projects ]]; then
      cp -Rp "$legacy/projects/." "$SHARED_DIR/projects/"
    fi
  fi
  : > "$SEED_DIR/.imported"

  for f in "${CLAUDE_SEED_FILES[@]}"; do
    seed_load "$f" "$home"
  done
  for f in settings.json settings.local.json; do
    if [[ -f $host/$f ]]; then cp "$host/$f" "$home/$f"; fi
  done
  # The sandbox's CLAUDE.md is the host's global one plus container-specific
  # notes, so Claude knows it is on Linux and how to get software installed.
  write_instructions "$home/CLAUDE.md" CLAUDE_container.md

  run_args+=(
    --volume "$home:$CHOME/.claude"
    --volume "$SHARED_DIR/projects:$CHOME/.claude/projects"
    --mount "type=bind,source=$HOME/.config,target=$CHOME/.config,readonly"
    --env CLAUDE_CONFIG_DIR="$CHOME/.claude"
    --env DISABLE_AUTOUPDATER=1
    # No mouse capture: keep the terminal's own select/copy/paste working.
    --env CLAUDE_CODE_DISABLE_MOUSE=1
  )
  for d in hooks skills; do
    if [[ -d $host/$d ]]; then
      mkdir -p "$home/$d"
      run_args+=(--mount "type=bind,source=$host/$d,target=$CHOME/.claude/$d,readonly")
    fi
  done

  # Pass through auth tokens if set on the host; otherwise log in once inside
  # the container and the credentials are saved to the seed at exit.
  for var in ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN; do
    if [[ -n "${!var:-}" ]]; then run_args+=(--env "$var"); fi
  done

  aws_setup
}

agent_finish() {
  local f
  for f in "${CLAUDE_SEED_FILES[@]}"; do
    seed_save "$1/home/$f"
  done
}

# AWS: export short-lived credentials into this script's environment and
# have the container inherit them by name, so secrets never appear in argv.
aws_setup() {
  local aws_profile="${AWS_PROFILE:-default}" creds key value sts region
  [[ "${WRAPCLAUDE_AWS:-1}" != 0 ]] || return 0
  command -v aws >/dev/null 2>&1 || return 0
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  if ! creds="$(aws configure export-credentials --profile "$aws_profile" --format env-no-export 2>/dev/null)"; then
    echo "wrapClaude: no AWS credentials for profile '$aws_profile' (expired login?); starting without AWS access." >&2
    return 0
  fi
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
}

wrap_main "$@"
