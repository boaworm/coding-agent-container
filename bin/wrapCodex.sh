#!/usr/bin/env bash
# Launch OpenAI Codex CLI, locked down, inside an Apple `container` VM,
# talking only to the self-hosted models configured for Crush.
# See lockdown-common.sh for exactly what the sandbox can and cannot reach.
#
#   - Model providers come from ~/.config/crush/crush.json (every
#     openai-compat provider). Each launch asks each server what model it is
#     serving right now, since crush.json drifts. Providers keep their Crush
#     names; the first is used unless `--provider <name>` (or
#     WRAPCODEX_PROVIDER) picks another.
#   - $STATE_DIR/etc/models.json is generated from what those servers report
#     and pointed at with model_catalog_json, so /model lists exactly these
#     models instead of the OpenAI ones Codex ships. Each catalog entry must
#     repeat Codex's own base prompt (see codex_base_prompt); if it cannot be
#     recovered, no catalog is written and no router is started.
#   - Because Codex binds one base_url per session, every provider is given the
#     loopback address of codex-model-router.py (started inside the container by
#     codex-model-launch.sh in place of the codex binary), and the router picks
#     the real upstream from the model in each request. That is what makes
#     /model able to move between servers mid-session; --provider still chooses
#     which one the session starts on.
#   - Codex runs with approval policy "never" and sandbox mode
#     danger-full-access: it does not ask before running commands and does not
#     use its own inner sandbox. The container VM is the only boundary.
#   - That config, plus requirements.toml (which forbids web search), is
#     generated on the host into $WRAPCODEX_STATE/etc and mounted read-only at
#     /etc/codex, so Codex cannot change it.
#   - API keys are passed as env vars by name, never in argv.
#   - Codex state (sessions, its own config.toml) lives on the host in
#     $WRAPCODEX_STATE/home (default ~/.codex-container), never in ~/.codex.
#   - AGENTS.md is regenerated each launch from ~/.claude/CLAUDE.md plus
#     AGENTS_container.md (edits made inside are overwritten next launch).
#
# Usage: wrapCodex.sh [--provider NAME] [--rebuild] [--install] [--shell]
#                     [codex args...]
#   --provider use this Crush provider (e.g. vllm, vllm-remote)
#   --rebuild  rebuild the image first
#   --install  install/upgrade Codex into /global/npm (only mode with /global rw)
#   --shell    start bash in the sandbox instead of codex (args go to bash)
#
# Env overrides: WRAPCODEX_STATE, WRAPCODEX_PROVIDER, WRAPAGENT_IMAGE,
#                WRAPAGENT_CPUS, WRAPAGENT_MEMORY, WRAPCLAUDE_GLOBAL
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

AGENT=Codex
AGENT_PKG=@openai/codex
AGENT_BIN=codex
# Inline TUI: no alternate screen, so terminal scrollback and copy/paste work.
AGENT_ARGS=(--no-alt-screen)
STATE_DIR="${WRAPCODEX_STATE:-$HOME/.codex-container}"
CRUSH_CFG="$HOME/.config/crush/crush.json"
# /model changes the model but never the provider a session is bound to, so
# every provider is pointed at codex-model-router.py, a loopback proxy that
# launch.sh starts inside the container and that forwards by model name. That
# is what lets /model hop between servers. Set
# WRAPCODEX_ROUTER=0 to talk to the servers directly again, and
# WRAPCODEX_ROUTER_PORT to move it off port 8777.
ROUTER_ENABLED="${WRAPCODEX_ROUTER:-1}"
ROUTER_PORT="${WRAPCODEX_ROUTER_PORT:-8777}"
router_on=0
router_routes='{}'   # model -> {base_url, env_key}, written to routes.json
router_model=""      # the model this session starts on

# shellcheck source=lockdown-common.sh
source "$SCRIPT_DIR/lockdown-common.sh"

toml_str() { jq -Rn --arg s "$1" '$s'; }

# Codex's /model picker lists exactly what the model catalog contains, so the
# generated catalog is what keeps the picker to the models these servers
# actually serve. Every entry has to carry a base prompt: give it anything else
# and Codex sends that instead of its own default instructions, so entries
# reuse the prompt Codex ships, lifted out of the installed binary and cached
# per build.
CODEX_PROMPT_START='You are a coding agent running in the Codex CLI'
CODEX_PROMPT_END='ensure you call `update_plan` to mark all steps as `completed`.'

# Prints Codex's default base prompt. Fails if the installed binary does not
# contain it where expected, in which case no catalog is written and Codex keeps
# its own model list.
codex_base_prompt() {
  local bin cache
  bin="$(ls -1 "$GLOBAL_DIR"/npm/lib/node_modules/@openai/codex/node_modules/@openai/codex-linux-*/vendor/*/bin/codex 2>/dev/null | head -1)" || return 1
  [[ -n $bin ]] || return 1
  cache="$STATE_DIR/base_instructions.md"
  if [[ ! -s $cache || $cache -ot "$bin" ]]; then
    perl -e '
      local $/;
      open(my $fh, "<:raw", $ARGV[0]) or die "cannot read $ARGV[0]: $!\n";
      my $data = <$fh>;
      my $start = index($data, $ARGV[1]);
      my $end   = index($data, $ARGV[2], $start);
      die "base prompt not found in $ARGV[0]\n" if $start < 0 || $end < 0;
      binmode(STDOUT, ":raw");
      print substr($data, $start, $end - $start + length($ARGV[2]));
    ' "$bin" "$CODEX_PROMPT_START" "$CODEX_PROMPT_END" > "$cache.tmp" \
      || { rm -f "$cache.tmp"; return 1; }
    [[ -s $cache.tmp ]] || { rm -f "$cache.tmp"; return 1; }
    mv "$cache.tmp" "$cache"
  fi
  cat "$cache"
}

# One model_catalog_json entry. context_window is omitted when unknown so
# Codex falls back to model_context_window.
catalog_entry() {
  local slug="$1" name="$2" url="$3" ctx="$4" priority="$5" base_prompt="$6"
  jq -cn --arg slug "$slug" --arg name "$name" --arg url "$url" \
    --arg bi "$base_prompt" --argjson ctx "${ctx:-null}" --argjson priority "$priority" '
    {
      slug: $slug,
      display_name: ($slug + " (" + $name + ")"),
      description: ("served by " + $name + " at " + $url),
      base_instructions: $bi,
      visibility: "list",
      priority: $priority,
      supported_in_api: true,
      support_verbosity: false,
      shell_type: "unified_exec",
      supported_reasoning_levels: [
        {effort: "low",    description: "Fast responses with lighter reasoning"},
        {effort: "medium", description: "Balances speed and reasoning depth"},
        {effort: "high",   description: "Greater reasoning depth for complex problems"}
      ],
      experimental_supported_tools: [],
      service_tiers: [],
      truncation_policy: {mode: "tokens", limit: 10000}
    } + (if $ctx == null then {} else {context_window: $ctx} end)'
}

# Turns "id<TAB>context window" lines from jq into catalog-usable ones: drops
# the idless ones and any context window that is not a plain number. Kept as a
# filter so both the live /models reply and the crush.json fallback share it.
model_lines_filter() {
  local id c
  while IFS=$'\t' read -r id c; do
    [[ -n $id && $id != null ]] || continue
    [[ $c =~ ^[0-9]+$ ]] || c=""
    printf '%s\t%s\n' "$id" "${c-}"
  done
}

# Writes $1/config.toml (all providers, $PROVIDER as the default) and
# $1/requirements.toml, plus $1/models.json (what /model offers).
write_codex_config() {
  local out="$1/config.toml" default=""
  local name url key var model ctx providers=""
  local catalog="[]" seen="" base_prompt="" catalog_path=""
  local -a served=()
  local line
  [[ -f "$CRUSH_CFG" ]] || die "$CRUSH_CFG not found; there are no local model providers to use."

  if ! base_prompt="$(codex_base_prompt)"; then
    echo "wrapCodex: could not recover the Codex base prompt; /model keeps the built-in list." >&2
    base_prompt=""
  fi
  # The router is only worth starting if /model has something to switch to.
  if [[ $ROUTER_ENABLED != 0 && -n $base_prompt ]]; then
    router_on=1
  fi

  while IFS=$'\t' read -r name url key; do
    url="${url%/}"
    # crush.json may reference an env var ("$FOO") instead of a literal key.
    if [[ $key =~ ^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$ ]]; then
      key="${!BASH_REMATCH[1]:-}"
    fi
    # One entry per model the server reports. The header goes on stdin so the
    # key stays out of curl's argv. No mapfile: these wrappers run under the
    # stock macOS bash 3.2 too.
    served=()
    while IFS= read -r line; do served+=("$line"); done < <(
      curl -fsS -m 3 -H @- "$url/models" <<< "Authorization: Bearer $key" 2>/dev/null \
        | jq -r '.data[]? | "\(.id)\t\(.max_model_len // "")"' 2>/dev/null \
        | model_lines_filter)
    if ((${#served[@]} == 0)); then
      echo "wrapCodex: $name ($url) is not answering; using its models from crush.json." >&2
      while IFS= read -r line; do served+=("$line"); done < <(
        jq -r --arg n "$name" \
          '.providers[$n].models[]? | "\(.id)\t\(.context_window // "")"' "$CRUSH_CFG" \
          | model_lines_filter)
    fi
    ((${#served[@]})) || continue

    var="CODEX_KEY_$(tr -c 'A-Za-z0-9\n' '_' <<< "$name" | tr '[:lower:]' '[:upper:]')"
    export "$var=$key"
    run_args+=(--env "$var")

    for line in ${served[@]+"${served[@]}"}; do
      IFS=$'\t' read -r model ctx <<< "$line"
      if [[ -z $default && ( -z $PROVIDER || $PROVIDER == "$name" ) ]]; then
        default="model_provider = $(toml_str "$name")
model = $(toml_str "$model")
${ctx:+model_context_window = $ctx}"
        router_model="$model"
      fi
      # Two servers can serve the same id; catalog slugs have to be unique.
      if [[ -n $base_prompt && $seen != *"|${model}|"* ]]; then
        seen+="|${model}|"
        router_routes="$(jq -cn --argjson routes "$router_routes" --arg slug "$model" \
          --arg url "$url" --arg key "$var" \
          '$routes + {($slug): {base_url: $url, env_key: $key}}')"
        local entry
        entry="$(catalog_entry "$model" "$name" "$url" "$ctx" \
          "$(jq 'length' <<< "$catalog")" "$base_prompt")" || return 1
        catalog="$(jq -cn --argjson catalog "$catalog" --argjson entry "$entry" \
          '$catalog + [$entry]')"
      fi
    done

    # With the router every provider is the same loopback endpoint; the model
    # in the request body is what decides the real upstream.
    local advertised="$url"
    [[ $router_on -eq 1 ]] && advertised="http://127.0.0.1:$ROUTER_PORT/v1"
    providers+="
[model_providers.$(toml_str "$name")]
name = $(toml_str "$name")
base_url = $(toml_str "$advertised")
env_key = $(toml_str "$var")
wire_api = \"responses\"
"
  done < <(jq -r '.providers // {} | to_entries[]
                  | select(.value.type == "openai-compat")
                  | [.key, .value.base_url, (.value.api_key // "")] | @tsv' "$CRUSH_CFG")

  [[ -n $providers ]] || die "no usable openai-compat providers in $CRUSH_CFG."
  [[ -n $default ]] || die "provider '$PROVIDER' not found in $CRUSH_CFG."

  # The catalog replaces Codex's built-in list wholesale, so the model this
  # session starts on is listed first.
  if [[ $(jq 'length' <<< "$catalog") -gt 0 ]]; then
    jq -n --argjson models "$catalog" --arg first "$router_model" '
      {models: ($models
        | sort_by((if .slug == $first then 0 else 1 end), .priority)
        | to_entries
        | map(.value + {priority: (.key + 1)}))}' > "$1/models.json"
    catalog_path=/etc/codex/models.json
    if [[ $router_on -eq 1 ]]; then
      echo "wrapCodex: /model offers $(jq -r '[.models[].slug] | join(", ")' "$1/models.json"), routed by model name through 127.0.0.1:$ROUTER_PORT." >&2
    else
      echo "wrapCodex: /model offers $(jq -r '[.models[].slug] | join(", ")' "$1/models.json"); use --provider for the other server." >&2
    fi
  else
    rm -f "$1/models.json"
  fi

  {
    echo "# Generated by wrapCodex.sh from $CRUSH_CFG on every launch; edits are lost."
    echo "$default"
    [[ -n $catalog_path ]] && echo "model_catalog_json = $(toml_str "$catalog_path")"
    # No prompts and no inner sandbox: the container is the sandbox.
    echo 'approval_policy = "never"'
    echo 'sandbox_mode = "danger-full-access"'
    echo "$providers"
  } > "$out"

  cat > "$1/requirements.toml" <<'EOF'
# Generated by wrapCodex.sh; enforced by Codex, cannot be overridden inside.
allowed_sandbox_modes = ["read-only", "workspace-write", "danger-full-access"]
allowed_approval_policies = ["untrusted", "on-request", "never"]
allowed_web_search_modes = ["disabled"]
EOF
}

agent_setup() {
  mkdir -p "$STATE_DIR/home" "$STATE_DIR/etc" "$STATE_DIR/router"
  write_codex_config "$STATE_DIR/etc"
  # The router runs as a child of tini's main process, so it is born and dies
  # with this container. Each VM has its own loopback, so concurrent sessions
  # can all use the same port. --shell does not start it.
  if [[ $router_on -eq 1 && $(jq 'length' <<< "$router_routes") -gt 0 ]]; then
    cp "$SCRIPT_DIR/codex-model-router.py" "$SCRIPT_DIR/codex-model-launch.sh" \
      "$STATE_DIR/router/"
    jq -n --argjson routes "$router_routes" --arg port "$ROUTER_PORT" \
      --arg default "$router_model" \
      '{port: ($port | tonumber), default: $default, routes: $routes}' \
      > "$STATE_DIR/router/routes.json"
    run_args+=(
      --volume "$STATE_DIR/router:/opt/codex-router:ro"
      --env "CODEX_ROUTER_PORT=$ROUTER_PORT"
    )
    AGENT_LAUNCHER=(/bin/bash /opt/codex-router/codex-model-launch.sh)
  else
    rm -f "$STATE_DIR/router/routes.json"
  fi
  # Overwritten every launch, so edits Codex makes to it do not stick.
  write_instructions "$STATE_DIR/home/AGENTS.md"
  run_args+=(
    --volume "$STATE_DIR/home:$CHOME/.codex"
    # Per-run scratch: Codex keeps its sandbox helper in ~/.codex/tmp and
    # cleans up helpers it thinks are stale. File locks do not cross VMs, so
    # on the shared mount one session deletes another's helper.
    --tmpfs "$CHOME/.codex/tmp"
    --mount "type=bind,source=$STATE_DIR/etc,target=/etc/codex,readonly"
    --env CODEX_HOME="$CHOME/.codex"
  )
}

PROVIDER="${WRAPCODEX_PROVIDER:-}"
if [[ "${1:-}" == --provider ]]; then
  [[ $# -ge 2 ]] || die "--provider needs a name."
  PROVIDER="$2"
  shift 2
fi

lockdown_main "$@"
