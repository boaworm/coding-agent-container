#!/usr/bin/env bash
# Launch OpenAI Codex CLI, locked down, inside an Apple `container` VM,
# talking only to the self-hosted models configured for Crush.
# See wrap-common.sh for the layout every wrapper shares: read-only toolkit
# at /global, one private state dir per session, nothing written to $HOME.
#
#   - Model providers come from ~/.config/crush/crush.json (every
#     openai-compat provider). Each launch asks each server what model it is
#     serving right now, since crush.json drifts. Providers keep their Crush
#     names; the first is used unless `--provider <name>` (or
#     WRAPCODEX_PROVIDER) picks another.
#   - $SESSION_DIR/etc/models.json is generated from what those servers report
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
#   - Codex's own config.toml (in the session's home, saved to the seed when
#     the session ends) outranks the generated one and remembers the last
#     /model pick, so that pick is read back from the seed, paired with
#     the provider that serves it, and passed on the command line as
#     -c model=/-c model_provider=. Otherwise a session starts on a model whose
#     server it is not pointed at. Codex's thread-spawning tools are passed
#     --disable multi_agent: the local models use them instead of doing the work.
#   - That config, plus requirements.toml (which forbids web search), is
#     generated on the host into this session's own etc/ and mounted read-only
#     at /etc/codex, so Codex cannot change it and no other launch rewrites it.
#   - API keys are passed as env vars by name, never in argv.
#   - Codex's home is per session: config.toml and auth.json are copied from
#     the seed and saved back when the session ends. Rollouts (sessions/) are
#     shared, one file per session, so `codex resume` works everywhere.
#   - AGENTS.md is regenerated each launch from ~/.claude/CLAUDE.md plus
#     AGENTS_container.md (edits made inside are overwritten next launch).
#
# Usage: wrapCodex.sh [--provider NAME] [--rebuild] [--install] [--toolkit]
#                     [--shell] [codex args...]
#   --provider use this Crush provider (e.g. vllm, vllm-remote)
#   --rebuild  rebuild the image first (automatic when the Dockerfile changed)
#   --install  install/upgrade Codex in the toolkit
#   --toolkit  bash with the toolkit mounted read-write and nothing else
#   --shell    start bash in the sandbox instead of codex (args go to bash)
#
# Env overrides: WRAPCODEX_STATE, WRAPCODEX_PROVIDER, WRAPAGENT_IMAGE,
#                WRAPAGENT_CPUS, WRAPAGENT_MEMORY, WRAPCLAUDE_GLOBAL,
#                WRAPCODEX_ROUTER, WRAPCODEX_ROUTER_PORT, WRAPCODEX_MULTI_AGENT
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

AGENT=Codex
AGENT_PKG=@openai/codex
AGENT_BIN=codex
# Inline TUI: no alternate screen, so terminal scrollback and copy/paste work.
AGENT_ARGS=(--no-alt-screen)
AGENT_STATE="${WRAPCODEX_STATE:-}"
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
cfg_model=""         # passed as -c model= so a stale home config cannot pin
cfg_provider=""      # passed as -c model_provider= (the two must agree)

# shellcheck source=wrap-common.sh
source "$SCRIPT_DIR/wrap-common.sh"

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
  bin="$(ls -1 "$TOOLKIT_DIR"/npm/lib/node_modules/@openai/codex/node_modules/@openai/codex-linux-*/vendor/*/bin/codex 2>/dev/null | head -1)" || return 1
  [[ -n $bin ]] || return 1
  cache="$AGENT_STATE/base_instructions.md"
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
    ' "$bin" "$CODEX_PROMPT_START" "$CODEX_PROMPT_END" > "$cache.tmp.$$" \
      || { rm -f "$cache.tmp.$$"; return 1; }
    [[ -s $cache.tmp.$$ ]] || { rm -f "$cache.tmp.$$"; return 1; }
    mv "$cache.tmp.$$" "$cache"
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

# Probe a server's chat/completions endpoint to discover which reasoning_effort
# values it actually accepts. Codex always sends the standard OpenAI names
# (low/medium/high); some servers (e.g. vLLM on Qwen) rename "high" to "xhigh".
# Returns a JSON map like {"high":"xhigh"} for the router to apply, or {} when
# no translation is needed. The key is piped on stdin so it never appears in
# curl's argv, matching the /models probe above. Only tests "high" — if the
# server rejects it, vLLM's known alias "xhigh" is tried as a fallback.
probe_reasoning_map() {
  local url="$1" key="$2" model="$3"
  local auth="Authorization: Bearer $key"
  local body resp code

  body=$(jq -cn --arg m "$model" --arg e "high" \
    '{model: $m, messages: [{role: "user", content: ""}], reasoning_effort: $e, max_tokens: 1}')
  resp=$(curl -s -m 3 -X POST "$url/chat/completions" \
    -H @- -H "Content-Type: application/json" \
    --data "$body" -w '\n%{http_code}' <<< "$auth" 2>/dev/null) || true
  code="${resp##*$'\n'}"

  [[ "$code" == 200 ]] && { printf '{}'; return 0; }
  printf '%s' "$resp" | grep -qi "reasoning effort" 2>/dev/null \
    || { printf '{}'; return 0; }

  body=$(jq -cn --arg m "$model" --arg e "xhigh" \
    '{model: $m, messages: [{role: "user", content: ""}], reasoning_effort: $e, max_tokens: 1}')
  resp=$(curl -s -m 3 -X POST "$url/chat/completions" \
    -H @- -H "Content-Type: application/json" \
    --data "$body" -w '\n%{http_code}' <<< "$auth" 2>/dev/null) || true
  code="${resp##*$'\n'}"

  [[ "$code" == 200 ]] && printf '{"high":"xhigh"}' || printf '{}'
}

# What the user last chose with /model. Codex keeps it in its own config.toml,
# which is saved to the seed when a session ends and so outlives it. Only
# that file's top level is read, so no provider's keys can be mistaken for it.
remembered_model() {
  local f="$SEED_DIR/config.toml" m=""
  [[ -f $f ]] || return 1
  m="$(sed -n '/^\[/q; s/^[[:space:]]*model[[:space:]]*=[[:space:]]*"\{0,1\}\([^"[:space:]]*\)"\{0,1\}[[:space:]]*$/\1/p' "$f" | head -1)"
  [[ -n $m ]] || return 1
  printf '%s\n' "$m"
}

# Writes $1/config.toml (all providers, $PROVIDER as the default) and
# $1/requirements.toml, plus $1/models.json (what /model offers).
write_codex_config() {
  local out="$1/config.toml" default=""
  local name url key var model ctx providers=""
  local catalog="[]" seen="" base_prompt="" catalog_path=""
  local fb_name="" fb_model="" fb_ctx="" pick_name="" pick_model="" pick_ctx=""
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

  # Codex writes its own model into its home config.toml and that
  # file outranks the generated one, so the last /model pick is honoured rather
  # than fought -- and the provider has to follow it, or the session asks one
  # server for another server's model. An explicit --provider still wins.
  local want=""
  [[ $provider_explicit -eq 1 ]] || want="$(remembered_model || true)"

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

    # Probe reasoning level support: some servers (vLLM) use "xhigh" where
    # OpenAI uses "high".  Record a translation map per server so the router
    # can rewrite the value before forwarding (see probe_reasoning_map above).
    local re_map='{}' probe_model=''
    if [[ $router_on -eq 1 && ${#served[@]} -gt 0 ]]; then
      IFS=$'\t' read -r probe_model _ <<< "${served[0]}"
      re_map="$(probe_reasoning_map "$url" "$key" "$probe_model")"
    fi

    var="CODEX_KEY_$(tr -c 'A-Za-z0-9\n' '_' <<< "$name" | tr '[:lower:]' '[:upper:]')"
    export "$var=$key"
    run_args+=(--env "$var")

    for line in ${served[@]+"${served[@]}"}; do
      IFS=$'\t' read -r model ctx <<< "$line"
      # The remembered pick may belong to a provider this loop only reaches
      # later, so the provider's own first model is kept as the fallback.
      if [[ -z $fb_model && ( -z $PROVIDER || $PROVIDER == "$name" ) ]]; then
        fb_name="$name"; fb_model="$model"; fb_ctx="$ctx"
      fi
      if [[ -n $want && $model == "$want" && $pick_model != "$want" ]]; then
        pick_name="$name"; pick_model="$model"; pick_ctx="$ctx"
      fi
      # Two servers can serve the same id; catalog slugs have to be unique.
      if [[ -n $base_prompt && $seen != *"|${model}|"* ]]; then
        seen+="|${model}|"
        router_routes="$(jq -cn --argjson routes "$router_routes" --arg slug "$model" \
          --arg url "$url" --arg key "$var" --argjson re_map "$re_map" \
          '$routes + {($slug): ({base_url: $url, env_key: $key} + (if ($re_map | length) > 0 then {reasoning_effort_map: $re_map} else {} end))}')"
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

  if [[ -n $pick_model ]]; then
    fb_name="$pick_name"; fb_model="$pick_model"; fb_ctx="$pick_ctx"
  fi
  if [[ -n $fb_model ]]; then
    default="model_provider = $(toml_str "$fb_name")
model = $(toml_str "$fb_model")
${fb_ctx:+model_context_window = $fb_ctx}"
    router_model="$fb_model"
    cfg_model="$fb_model"
    cfg_provider="$fb_name"
  fi

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
  local home="$SESSION_DIR/home" etc="$SESSION_DIR/etc" router="$SESSION_DIR/router"
  local legacy="$HOME/.codex-container/home" f
  mkdir -p "$home" "$etc" "$router" "$SHARED_DIR/sessions"

  # State used to live in ~/.codex-container; bring it over once. The old
  # directory is left alone.
  if [[ ! -e $SEED_DIR/.imported && -d $legacy ]]; then
    echo "wrapCodex: importing state from $legacy (it can be deleted afterwards)." >&2
    for f in config.toml auth.json; do
      if [[ -f $legacy/$f ]]; then cp -p "$legacy/$f" "$SEED_DIR/$f"; fi
    done
    if [[ -d $legacy/sessions ]]; then
      cp -Rp "$legacy/sessions/." "$SHARED_DIR/sessions/"
    fi
  fi
  : > "$SEED_DIR/.imported"
  seed_load config.toml "$home"
  seed_load auth.json "$home"

  write_codex_config "$etc"
  # What the session starts on is pinned on the command line, because Codex's
  # own config.toml outranks the generated one and would otherwise keep a
  # model from one server paired with another server.
  if [[ -n $cfg_model ]]; then
    AGENT_ARGS+=(-c "model=$cfg_model" -c "model_provider=$cfg_provider")
  fi
  # The TUI hands every session its thread-spawning tools (create_thread and
  # friends). The local models reach for them unprompted and then describe
  # work they never did, so they are off unless explicitly asked for.
  if [[ ${WRAPCODEX_MULTI_AGENT:-0} == 0 ]]; then
    AGENT_ARGS+=(--disable multi_agent)
  fi
  # The router runs as a child of tini's main process, so it is born and dies
  # with this container. Each VM has its own loopback, so concurrent sessions
  # can all use the same port, and each has its own routes.json. --shell does
  # not start it.
  if [[ $router_on -eq 1 && $(jq 'length' <<< "$router_routes") -gt 0 ]]; then
    cp "$SCRIPT_DIR/codex-model-router.py" "$SCRIPT_DIR/codex-model-launch.sh" "$router/"
    jq -n --argjson routes "$router_routes" --arg port "$ROUTER_PORT" \
      --arg default "$router_model" \
      '{port: ($port | tonumber), default: $default, routes: $routes}' \
      > "$router/routes.json"
    run_args+=(
      --volume "$router:/opt/codex-router:ro"
      --env "CODEX_ROUTER_PORT=$ROUTER_PORT"
    )
    AGENT_LAUNCHER=(/bin/bash /opt/codex-router/codex-model-launch.sh)
  fi
  write_instructions "$home/AGENTS.md"
  run_args+=(
    --volume "$home:$CHOME/.codex"
    --volume "$SHARED_DIR/sessions:$CHOME/.codex/sessions"
    # Codex keeps its setuid sandbox helper in ~/.codex/tmp; keep that on the
    # VM's own disk rather than the host share.
    --tmpfs "$CHOME/.codex/tmp"
    --mount "type=bind,source=$etc,target=/etc/codex,readonly"
    --env CODEX_HOME="$CHOME/.codex"
  )
}

agent_finish() {
  seed_save "$1/home/config.toml"
  seed_save "$1/home/auth.json"
}

PROVIDER="${WRAPCODEX_PROVIDER:-}"
provider_explicit=0
[[ -n $PROVIDER ]] && provider_explicit=1
if [[ "${1:-}" == --provider ]]; then
  [[ $# -ge 2 ]] || die "--provider needs a name."
  PROVIDER="$2"
  provider_explicit=1
  shift 2
fi

wrap_main "$@"
