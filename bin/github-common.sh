# Shared GitHub credential injection for the wrapper scripts. Sourced, not
# executed. Provides github_setup(), which resolves a GitHub token on the host
# and wires it into the sandbox through environment variables only: the token
# is never written to a file, never passed in argv, and no host credential
# paths are mounted.
#
#   - Token: $GH_TOKEN or $GITHUB_TOKEN from the launcher's environment,
#     otherwise `gh auth token` if gh is installed and logged in on the host.
#     Exported into the container as GH_TOKEN, which gh, the GitHub API and
#     helper tools pick up natively.
#   - Git is configured through GIT_CONFIG_* env vars (no files touched):
#     an HTTPS credential helper for github.com that echoes the token, an
#     insteadOf rewrite so git@github.com: remotes work over HTTPS too, and
#     the host's user.name/user.email so commits work without setup.
#   - Commits are unsigned; there are no GPG keys in the container.
#
# The caller sets GITHUB_ENABLED=0 to skip (WRAPCLAUDE_GITHUB in
# wrapClaude.sh, WRAPAGENT_GITHUB in the lockdown wrappers). A missing token
# is a warning, not a fatal error: the sandbox still starts, git just cannot
# reach GitHub.

github_setup() {
  [[ "${GITHUB_ENABLED:-1}" != 0 ]] || return 0

  local token name email i
  token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  if [[ -z "$token" ]] && command -v gh >/dev/null 2>&1; then
    token="$(gh auth token 2>/dev/null || true)"
  fi
  if [[ -z "$token" ]]; then
    echo "wrap${AGENT:-Claude}: no GitHub token (set GH_TOKEN or run gh auth login on the host); starting without GitHub access." >&2
    return 0
  fi
  # --env GH_TOKEN (by name, not value) hands it to the container without
  # exposing it in the container run argv.
  export GH_TOKEN="$token"
  run_args+=(--env GH_TOKEN)

  local -a keys values
  keys+=("credential.https://github.com.helper")
  values+=('!f() { echo username=x-access-token; echo "password=$GH_TOKEN"; }; f')
  keys+=("url.https://github.com/.insteadOf")
  values+=("git@github.com:")
  if command -v git >/dev/null 2>&1; then
    name="$(git config --get user.name 2>/dev/null || true)"
    email="$(git config --get user.email 2>/dev/null || true)"
    [[ -n "$name" ]] && { keys+=("user.name"); values+=("$name"); }
    [[ -n "$email" ]] && { keys+=("user.email"); values+=("$email"); }
  fi

  for i in "${!keys[@]}"; do
    # The helper value contains the literal text $GH_TOKEN; the container's
    # shell expands it at credential time, so no secret travels in argv.
    run_args+=(--env "GIT_CONFIG_KEY_$i=${keys[i]}" --env "GIT_CONFIG_VALUE_$i=${values[i]}")
  done
  run_args+=(--env "GIT_CONFIG_COUNT=${#keys[@]}")
}
