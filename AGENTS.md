# AGENTS.md

Working notes for agents operating **on this repository** (the sandbox launchers
themselves, run on the macOS host). This is not the file injected into sandboxes
— see "Instruction files" below for that distinction.

## What this repo is

Infrastructure, not an application: scripts that run third-party coding agents
(Claude Code, OpenAI Codex CLI, Charm Crush, Aider) inside locked-down Linux VMs
via Apple's `container` runtime on macOS. Each `container run` is its own
lightweight VM; the container cannot see or signal host processes.

There is no build system, test suite, lint config, or package manifest. It is a
handful of Bash scripts plus one Dockerfile. There is no `container` CLI or
Docker Desktop assumption beyond Apple's `container` (the scripts call
`container system status/start`, `container image inspect`, `container build`,
`container run`). Not a git repo.

```
Dockerfile                  image (ubuntu:26.04) shared by all launchers
bin/wrapClaude.sh           Claude Code launcher (the permissive tier)
bin/lockdown-common.sh      shared launcher library (sourced, not executed)
bin/wrapCodex.sh            Codex CLI launcher (strict tier)
bin/wrapCrush.sh            Crush launcher (strict tier)
bin/codex-model-launch.sh   started instead of codex; boots the router, then execs it
bin/codex-model-router.py   loopback proxy that lets codex /model switch servers
bin/github-common.sh        GitHub token + git config injection (sourced by all)
bin/install-aider.sh        one-off Aider installer, runs inside the sandbox
CLAUDE_container.md         extra system-prompt notes for sandboxed Claude
AGENTS_container.md         extra system-prompt notes for sandboxed Codex/Crush
.crush/  tmp/               local scratch, not sources
```

## Commands

There is nothing to build or test locally. The real operations:

```sh
bin/wrapClaude.sh --rebuild          # rebuild image claude-sandbox:latest from Dockerfile
bin/wrapClaude.sh                    # Claude in sandbox, cwd = only writable host path
bin/wrapClaude.sh --shell            # bash in the sandbox instead
bin/wrapCodex.sh [--provider NAME]   # Codex against the local openai-compat models
bin/wrapCrush.sh                     # Crush
bin/wrapCrush.sh --install           # (re)install agent npm pkg into /global/npm
bin/install-aider.sh                 # Aider into /global/aider
```

Every launcher accepts `--rebuild`, `--shell`, and passes remaining args to the
agent. `--install` exists only on the lockdown wrappers. Prereqs on the host:
Apple `container` running, and the `ClaudeGlobal` APFS volume mounted at
`/Volumes/ClaudeGlobal` (launchers abort otherwise). `shellcheck` is not
installed on this machine; the scripts carry `# shellcheck source=...`
directives for when it is.

## Two deliberate sandbox tiers — do not unify them

`wrapClaude.sh` is the **permissive** tier: mounts `~/.config` read-only,
mounts `/global` **read-write** (so `npm install -g` persists via
`NPM_CONFIG_PREFIX=/global/npm`, likewise `CARGO_HOME=/global/cargo`,
`GOPATH=/global/go` from the Dockerfile ENV), mints short-lived AWS creds on the
host (STS) and passes them by env name. It does **not** use
`lockdown-common.sh`.

`wrapCodex.sh` / `wrapCrush.sh` are the **strict** tier via
`lockdown-common.sh`: `--cap-drop ALL`, `/global` **read-only**, no `~/.config`,
no AWS/SSH/Anthropic credentials, and `NPM_CONFIG_PREFIX`/`CARGO_HOME`/`GOPATH`
overridden to throwaway `~/.local/...` paths so installs vanish at exit. The
agent binary always runs as `/global/npm/bin/$AGENT_BIN` under tini. `--install`
is the only mode that mounts `/global` read-write, and it mounts nothing else.
Security-inclined asymmetries between the tiers are intentional. GitHub is the
one credential the strict tier does pass (see below), opt-out via
`WRAPAGENT_GITHUB=0`.

## Adding a new agent wrapper

Create `bin/wrapX.sh` that: sets `AGENT` (display name), `AGENT_PKG` (npm
package), `AGENT_BIN` (command name in `/global/npm/bin`), optionally
`AGENT_ARGS` (array of always-passed flags, e.g. Codex's `--no-alt-screen`),
sets `STATE_DIR` from a `WRAPX_STATE` env defaulting to `~/.x-container`, defines
an `agent_setup` function (seeds `$STATE_DIR`, appends to `run_args`), then
`source`s `lockdown-common.sh` and calls `lockdown_main "$@"`.
`lockdown_main` handles flag parsing, image rebuild, guards, and `container run`
— wrappers never invoke `container run` themselves. The wrapper must run under
`set -euo pipefail` and set `REPO_DIR` (used to find the Dockerfile and
`*_container.md`).
`AGENT_LAUNCHER` (array) optionally replaces `/global/npm/bin/$AGENT_BIN` as
tini's child, for wrappers that need a sidecar up before the agent starts.

## Instruction files (easy to confuse)

- `CLAUDE_container.md` and `AGENTS_container.md` are **runtime prompts**, not
  repo docs. On each launch the wrappers concatenate the host's
  `~/.claude/CLAUDE.md` plus the appropriate `*_container.md` into the agent's
  global instructions (`$STATE_DIR/CLAUDE.md`, Codex's `~/.codex/AGENTS.md`,
  Crush's `~/.config/crush/AGENTS.md` appended to `options.context_paths`).
  Editing them changes what every sandboxed agent believes about its
  environment; edits made to those files *inside* a sandbox are overwritten
  next launch. Host is always the source of truth for configs copied in
  (`settings.json`, `crush.json`, Codex `config.toml`).
- `AGENTS.md` (this file) is only for work on the launcher repo itself.

## Non-obvious behavior worth knowing

- **`/global` is the agents' persistence layer** (`GLOBAL_DIR`, from
  `WRAPCLAUDE_GLOBAL`, default `/Volumes/ClaudeGlobal`): a dedicated
  case-sensitive APFS volume on the Mac, mounted into every sandbox at
  `/global`. The VM is wiped when the session exits, so anything the agents
  should keep lives here instead — the agent binaries themselves
  (`/global/npm/bin/$AGENT_BIN`, installed by `--install`) and the toolchains
  the image points at (`NPM_CONFIG_PREFIX=/global/npm`, `CARGO_HOME=/global/cargo`,
  `GOPATH=/global/go`, plus `/global/aider`) — rather than being reinstalled
  every launch or landing in the host's real `~/.claude`, `~/.codex` or
  `~/.config`. It is read-write only for the permissive tier and for `--install`;
  the strict tier mounts it read-only and redirects installs at throwaway paths
  under `~/.local`. Per-agent state (login, history, generated config) is a
  separate matter: those are the `$WRAP*_STATE` dirs in `$HOME`, not on this
  volume, and they are what keep a sandboxed agent's state isolated from the
  developer's own dotfiles.
- **Image is shared**: all wrappers use one image, `claude-sandbox:latest`
  (`WRAPCLAUDE_IMAGE` / `WRAPAGENT_IMAGE`). Builds pass host `id -u`/`id -g` as
  `USER_UID`/`USER_GID` so files written into the mounted project keep host
  ownership; the in-container user is always `claude`, home `/home/claude`
  (`$CHOME` in the scripts). gid 20 (`staff` on macOS) collides with Ubuntu's
  `dialout` group — the Dockerfile reuses any group already holding the gid.
- **Launchers refuse bad cwds**: `$HOME`, `/`, and (strict tier only) anything
  under `/Volumes/ClaudeGlobal`.
- **GitHub access** (`bin/github-common.sh`, sourced by all wrappers):
  `github_setup` resolves a token from `GH_TOKEN`/`GITHUB_TOKEN` env or host
  `gh auth token`, exports it, and passes it to the container **by name**
  (`--env GH_TOKEN`, never by value, mirroring the AWS pattern). Git inside the
  container is configured purely through `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_n`/
  `GIT_CONFIG_VALUE_n` env vars: a `!`-shell credential helper for
  `credential.https://github.com` that echoes `x-access-token`/`$GH_TOKEN` (the
  helper value contains the literal `$GH_TOKEN` text, expanded by the
  container's shell at credential time, so the secret never appears in
  `container run` argv), an `insteadOf` rewrite making `git@github.com:` remotes
  work over HTTPS, and host `user.name`/`user.email` for commits. Nothing is
  written to disk; commits are unsigned (no GPG keys in the container). `gh`
  is baked into the image and authenticates off `GH_TOKEN` automatically. A
  missing token is a warning, not fatal. Opt out per tier: `WRAPCLAUDE_GITHUB=0`,
  `WRAPAGENT_GITHUB=0`.
- **Codex config generation** (`write_codex_config` in `bin/wrapCodex.sh:148`)
  reads every `openai-compat` provider from `~/.config/crush/crush.json`, then
  live-probes each server's `/models` (3s curl, header piped via stdin so keys
  never appear in argv) to pick up the model actually being served, falling
  back to `crush.json`'s first model when a server is down. Keys become
  `CODEX_KEY_<NAME>` env vars passed by name. `wire_api` must be `"responses"`.
  Generated `config.toml` sets `approval_policy = "never"` +
  `sandbox_mode = "danger-full-access"` because the VM is the only boundary;
  `requirements.toml` (mounted read-only at `/etc/codex`) pins web search off
  and cannot be overridden from inside.
- **Codex model catalog** (`codex_base_prompt` + `catalog_entry` in
  `bin/wrapCodex.sh:84`) — `/model` lists exactly what
  `model_catalog_json` contains, so the wrapper writes
  `$STATE_DIR/etc/models.json` (mounted at `/etc/codex/models.json`) with one
  entry per model the servers reported. Two Codex quirks make this fiddly:
  an entry **must** carry `base_instructions`, because that string is sent as
  the model's system prompt — entries therefore reuse the prompt extracted
  from the installed binary (cached in `$STATE_DIR/base_instructions.md`,
  refreshed when the binary is newer; if extraction fails the catalog is
  skipped and Codex's own model list comes back) — and a model can only be
  used with the session's `model_provider`, which is what the model router
  exists to work around.
- **Codex model router** (`bin/codex-model-router.py`, started by
  `bin/codex-model-launch.sh`) — `turn/start` has no provider field, so `/model`
  alone can never leave the server a session started on (picking the other
  one 404s). The wrapper therefore points *every* provider at
  `http://127.0.0.1:8777/v1` and lets the router pick the upstream from the
  `model` in each request body. `$STATE_DIR/router` (mounted read-only at
  `/opt/codex-router`) holds the copied scripts plus `routes.json`, which maps
  model -> `{base_url, env_key}`: keys stay in the `CODEX_KEY_<NAME>` env vars,
  never in that file. launch.sh waits for `/health` before exec'ing Codex and
  logs to `~/.codex/model-router.log`; the router is a child of the agent
  process, so it dies with the VM, and each VM has its own loopback so
  concurrent sessions can share the port. `--shell` starts no router (a codex
  launched by hand there cannot reach the providers), and `WRAPCODEX_ROUTER=0`
  skips it entirely, putting the real server URLs back in the config.
- **Codex `~/.codex/tmp` is a tmpfs** (`wrapCodex.sh:296`): Codex keeps its
  setuid sandbox helper there and garbage-collects "stale" helpers; on the
  shared host mount, concurrent sessions delete each other's helpers because
  file locks don't cross VMs.
- **Crush seeding**: `~/.config/crush/crush.json` is copied fresh each launch
  with the sandbox `AGENTS.md` injected into `options.context_paths` via `jq`
  and mounted read-only (agent can't loosen its own permissions). The data dir
  `~/.local/share/crush` maps to `$WRAPCRUSH_STATE/data`, seeded **once** from
  the host's model picks (`{models, recent_models}`) — delete
  `~/.crush-container/data/crush.json` to re-seed.
- **Claude state isolation**: Claude's login/history/settings live in
  `$WRAPCLAUDE_STATE` (default `~/.claude-container`), never the real
  `~/.claude`. Host `settings.json`/`settings.local.json` are copied in each
  launch (or deleted if absent host-side); host `hooks/` and `skills/` are
  mounted read-only so the sandboxed agent can't weaken its guardrails.
  Auth: pass through `ANTHROPIC_API_KEY`/`CLAUDE_CODE_OAUTH_TOKEN` if set,
  else log in once inside (persists in the state dir).
- **AWS handling**: strict wrappers pass no credentials at all. `wrapClaude.sh`
  exports STS creds via `export` + `--env NAME` (by name, never `--env K=V`, so
  secrets stay out of argv); long-lived keys are exchanged with
  `aws sts get-session-token` (`WRAPCLAUDE_AWS_DURATION`, default 43200s);
  `WRAPCLAUDE_AWS=0` disables. Creds can't be refreshed mid-session.

## Dockerfile gotchas

- Ubuntu 26.04 ships **uutils (Rust) coreutils** by default; the image forcibly
  swaps to GNU coreutils (`--allow-remove-essential
  coreutils-from-gnu coreutils-from-uutils-`). Scripts may rely on GNU-only
  flags/output.
- `fd` is a symlink to `/usr/bin/fdfind`; LLVM tools come via
  `/usr/lib/llvm` symlink → versioned dir on `PATH`.
- **Aider is not in the image** — it needs Python ≤3.12, image ships 3.14.
  `install-aider.sh` runs `wrapClaude.sh --shell` (with `WRAPCLAUDE_AWS=0`) and
  fetches standalone CPython 3.12 into `/global/aider`.
- **gh CLI** is installed from the official GitHub release tarball in its own
  layer (like the AWS CLI). The tag is scraped from the `releases/latest`
  redirect; asset names are versioned, so there is no stable download URL.
- **Never `tar` directly into `/global` or the project mount**: GNU tar creates
  mode-000 placeholder files for `../` symlinks, which the host share can't
  open ("Permission denied"). Extract to `/tmp` (container disk) then `cp -a`
  — see `bin/install-aider.sh:37`.
- `ENTRYPOINT` is tini + `claude` with `--rm`; everything outside the mounts is
  discarded at exit.

## Env var reference

| Var | Default | Used by |
|---|---|---|
| `WRAPCLAUDE_IMAGE` / `WRAPAGENT_IMAGE` | `claude-sandbox:latest` | respective wrappers |
| `WRAPCLAUDE_STATE` | `~/.claude-container` | wrapClaude |
| `WRAPCODEX_STATE` | `~/.codex-container` | wrapCodex |
| `WRAPCRUSH_STATE` | `~/.crush-container` | wrapCrush |
| `WRAPCLAUDE_GLOBAL` | `/Volumes/ClaudeGlobal` | all wrappers (shared name, even in lockdown-common) |
| `WRAPCLAUDE_CPUS` / `WRAPAGENT_CPUS` | `4` | respective |
| `WRAPCLAUDE_MEMORY` / `WRAPAGENT_MEMORY` | `4G` | respective |
| `WRAPCLAUDE_AWS` / `WRAPCLAUDE_AWS_DURATION` | `1` / `43200` | wrapClaude only |
| `WRAPCODEX_PROVIDER` | — (first provider) | wrapCodex |
| `WRAPCODEX_ROUTER` / `WRAPCODEX_ROUTER_PORT` | `1` / `8777` | wrapCodex model router |
| `WRAPCLAUDE_GITHUB` / `WRAPAGENT_GITHUB` | `1` | respective tiers (set `0` to skip GitHub token) |

Note the shared-name quirk: the strict wrappers read the **global dir** from
`WRAPCLAUDE_GLOBAL` and CPU/memory from `WRAPAGENT_*`, so overrides don't
follow the per-agent prefix consistently.

## Style

- Bash: `set -euo pipefail`, array-built `run_args`, `die()` for errors
  (`wrap<Agent>:` prefix to stderr), `exec container run` last.
- The heredoc in `install-aider.sh` runs **inside the Linux sandbox**;
  everything before `exec` runs on macOS. Keep host-side code free of GNU-only
  assumptions, and keep it Bash 3.2-safe: the host really does run the stock
  macOS `/bin/bash` 3.2, so no `mapfile`/`readarray`, no associative arrays or
  `declare -n`, and empty arrays need `${arr[@]+"${arr[@]}"}`. `BASH_REMATCH`
  and `read -r` with process substitution are fine in 3.2.
- These are personal tools, so hard-coded personal paths
  (`/Volumes/ClaudeGlobal`, `~/.config/crush`) are expected, not oversights.
