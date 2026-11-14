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
bin/wrap-common.sh          shared launcher library (sourced, not executed)
bin/wrapClaude.sh           Claude Code launcher
bin/wrapCodex.sh            Codex CLI launcher
bin/wrapCrush.sh            Crush launcher
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
bin/wrapClaude.sh                    # Claude in sandbox, cwd = only writable host path
bin/wrapCodex.sh [--provider NAME]   # Codex against the local openai-compat models
bin/wrapCrush.sh                     # Crush
bin/wrapX.sh --shell                 # bash in that agent's sandbox instead
bin/wrapX.sh --install               # (re)install that agent's npm pkg into the toolkit
bin/wrapX.sh --toolkit               # bash with the toolkit read-write, nothing else mounted
bin/wrapX.sh --rebuild               # force an image rebuild (automatic when the Dockerfile changed)
bin/install-aider.sh                 # Aider into the toolkit (/global/aider)
```

Every launcher accepts `--rebuild`, `--install`, `--toolkit`, `--shell`, and
passes remaining args to the agent. Prereqs on the host: Apple `container`
running, and the `ClaudeGlobal` APFS volume mounted at `/Volumes/ClaudeGlobal`
(launchers abort otherwise). `shellcheck` is not installed on this machine; the
scripts carry `# shellcheck source=...` directives for when it is.

There is no `container` CLI inside a sandbox, so launcher changes cannot be
run end to end from one. What can be done there: `bash -n`, `shellcheck -x`,
and driving the launchers against a stub `container` on PATH with `HOME` and
`WRAPCLAUDE_GLOBAL` pointed at scratch dirs.

## The design: tools, state and working directory are separate

Three things, three places, and the launchers exist to keep them apart:

1. **The toolkit** -- `$GLOBAL_DIR/toolkit` on the host, `/global` in the VM,
   **read-only in every session of every agent**. It holds all three agents
   (`/global/npm/bin/{claude,codex,crush}`), Aider and any shared tools. The
   compilers, `gh` and the rest of the system tooling are in the image. Only
   `--install` and `--toolkit` mount the toolkit read-write, and they mount
   nothing else from the host (no working directory, no state, no
   credentials). No agent is baked into the image.
2. **State** -- `$GLOBAL_DIR/state/<agent>/`, never `$HOME`, never the
   working directory, never visible at `/global`:
   - `sessions/<id>/` -- **one per running session**, created at launch,
     mounted as the agent's home/config, removed at exit. Generated config
     (Codex `etc/` and `router/`, Crush `config/`) lives here too, so one
     launch never rewrites files another session is reading.
   - `seed/` -- what a new session is copied from: login, model picks. When
     a session ends, `agent_finish` saves its copy back if it changed
     (`seed_save`, newest wins).
   - `shared/` -- history every session adds its *own* files to and none
     rewrites (Claude `projects/`, Codex `sessions/`), mounted into each
     session so `--resume` works. Also Crush's per-project data.
3. **The working directory** -- mounted read-write at its host path, and the
   only place the agent's work lands. Launchers and agents must not leave
   their own files in it (Crush's `.crush` is redirected, `.pyc` writing is
   off).

**Concurrency rule: two running sessions never write the same file.** That is
what the per-session dirs are for, and why package-manager homes
(`NPM_CONFIG_PREFIX`, `CARGO_HOME`, `GOPATH`) point at the VM's own disk
(`~/.local`, gone at exit) rather than a shared cache. File locks do not
cross VMs, so the locking that is needed is done by the launchers on the host
(`lock_try`/`lock_acquire` in `wrap-common.sh`: a directory holding the
owner's pid, taken over when the owner is gone): `state/<agent>/lock` around
session create/finish, `state/toolkit.lock` around toolkit writes,
`state/image.lock` around builds. The launcher does not `exec` the container:
it stays as the parent so its EXIT trap can finish the session; sessions whose
launcher died are finished by the next launch of that agent (`reap_sessions`).

What still differs per agent is how much of the host it is handed, not the
layout. Claude gets `~/.config` read-only, short-lived AWS creds, the host's
`~/.claude` settings/hooks/skills, and keeps Linux capabilities
(`AGENT_KEEP_CAPS=1`). Codex and Crush get `--cap-drop ALL`, no `~/.config`,
no AWS/SSH/Anthropic credentials. GitHub goes to all three (see below).

## Adding a new agent wrapper

Create `bin/wrapX.sh` that: sets `AGENT` (display name; lower-cased it names
the state dir), `AGENT_PKG` (npm package), `AGENT_BIN` (command name in
`/global/npm/bin`), optionally `AGENT_ARGS` (array of always-passed flags,
e.g. Codex's `--no-alt-screen`) and `AGENT_STATE` from a `WRAPX_STATE` env
(empty = `$GLOBAL_DIR/state/x`), then `source`s `wrap-common.sh`, defines
`agent_setup` (fills `$SESSION_DIR` from `$SEED_DIR` with `seed_load`, appends
mounts to `run_args`) and optionally `agent_finish DIR PID` (`seed_save` what
should outlive the session; `DIR` may be a dead session being reaped, so use
the argument, not `$SESSION_DIR`), and calls `wrap_main "$@"`.
`wrap_main` handles flag parsing, the image, guards, session lifecycle and
`container run` -- wrappers never invoke `container run` themselves. The
wrapper must run under `set -euo pipefail` and set `REPO_DIR` (used to find
the Dockerfile and `*_container.md`).
`AGENT_LAUNCHER` (array) optionally replaces `/global/npm/bin/$AGENT_BIN` as
tini's child, for wrappers that need a sidecar up before the agent starts.
Anything the agent rewrites in place must be in the session dir; only files
unique to a session may go in `shared/`.

## Instruction files (easy to confuse)

- `CLAUDE_container.md` and `AGENTS_container.md` are **runtime prompts**, not
  repo docs. On each launch the wrappers concatenate the host's
  `~/.claude/CLAUDE.md` plus the appropriate `*_container.md` into the agent's
  global instructions (Claude's `~/.claude/CLAUDE.md`, Codex's `~/.codex/AGENTS.md`,
  Crush's `~/.config/crush/AGENTS.md` appended to `options.context_paths`).
  Editing them changes what every sandboxed agent believes about its
  environment; edits made to those files *inside* a sandbox are overwritten
  next launch. Host is always the source of truth for configs copied in
  (`settings.json`, `crush.json`, Codex `config.toml`).
- `AGENTS.md` (this file) is only for work on the launcher repo itself.

## Non-obvious behavior worth knowing

- **The volume layout** (`GLOBAL_DIR`, from `WRAPCLAUDE_GLOBAL`, default
  `/Volumes/ClaudeGlobal`, a dedicated case-sensitive APFS volume):
  `toolkit/` is what sessions see at `/global`; `state/` sits beside it and
  is never mounted whole. The volume used to *be* the toolkit, mounted whole
  and read-write for Claude; `migrate_toolkit` moves any such top-level
  entries under `toolkit/` on the first launch, leaving a relative symlink
  for each (`npm -> toolkit/npm`) so sessions still running on the old
  layout keep resolving `/global/...`; the symlinks can be deleted once
  those sessions are gone. Likewise each wrapper imports the old `~/.<agent>-container`
  state into its seed once (marker: `seed/.imported`) and leaves the old
  directory for the user to delete.
- **Image is shared**: all wrappers use one image, `claude-sandbox:latest`
  (`WRAPCLAUDE_IMAGE` / `WRAPAGENT_IMAGE`). Builds pass host `id -u`/`id -g` as
  `USER_UID`/`USER_GID` so files written into the mounted project keep host
  ownership; the in-container user is always `claude`, home `/home/claude`
  (`$CHOME` in the scripts). gid 20 (`staff` on macOS) collides with Ubuntu's
  `dialout` group — the Dockerfile reuses any group already holding the gid.
- **The image name is qualified** (`IMAGE` in `wrap-common.sh`): a name
  without a `/` gets `docker.io/library/` in front. `container build -t NAME`
  stores the image under that qualified name, while `container run NAME`
  prefers an image stored under the bare name -- a leftover from an older
  `container` build shadowed every rebuild that way (no `gh`, old env).
- **The image follows the Dockerfile** (`ensure_image`): each launch compares
  a hash of the Dockerfile (plus uid/gid and image name) with
  `state/image.stamp` and rebuilds on a mismatch, so a launch always runs the
  current image. `--rebuild` forces it (e.g. to pick up newer upstream
  releases with an unchanged Dockerfile). Running sessions keep the image
  they started on.
- **Agents come from the toolkit, not the image**: a launch whose agent is
  missing from `toolkit/npm/bin` installs it first; `--install` upgrades it.
  An upgrade replaces files under sessions that are already running that
  agent, so prefer doing it between sessions.
- **Launchers refuse bad cwds**: `$HOME`, `/`, and anything under
  `/Volumes/ClaudeGlobal`.
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
  missing token is a warning, not fatal. Opt out with `WRAPCLAUDE_GITHUB=0` (Claude) or
  `WRAPAGENT_GITHUB=0` (Codex, Crush).
- **Codex config generation** (`write_codex_config` in `bin/wrapCodex.sh`)
  reads every `openai-compat` provider from `~/.config/crush/crush.json`, then
  live-probes each server's `/models` (3s curl, header piped via stdin so keys
  never appear in argv) to pick up the model actually being served, falling
  back to `crush.json`'s first model when a server is down. Keys become
  `CODEX_KEY_<NAME>` env vars passed by name. `wire_api` must be `"responses"`.
  Generated `config.toml` sets `approval_policy = "never"` +
  `sandbox_mode = "danger-full-access"` because the VM is the only boundary;
  `requirements.toml` (mounted read-only at `/etc/codex`) pins web search off
  and cannot be overridden from inside.
- **Codex's own `config.toml` outranks the generated one**
  (`remembered_model` in `bin/wrapCodex.sh`): `/model` and `/settings`
  write `model` into `~/.codex/config.toml`, which `agent_finish` saves to
  the seed, so it reaches every later session and beats
  `/etc/codex/config.toml`. Left alone, that pins a model whose server the
  session is not pointed at. The wrapper reads that pick back from
  `seed/config.toml` (top level of the file only), starts the session on it,
  pairs it with the provider that serves it, and passes both as
  `-c model=`/`-c model_provider=` so neither config file can disagree with
  the other. An explicit `--provider` wins over the remembered model.
  `codex doctor` prints the resolved model/provider pair, and
  `codex debug models` the resolved catalog -- both work without a model
  round-trip.
- **The TUI's agent-spawning tools are off by default** (`--disable
  multi_agent`, `WRAPCODEX_MULTI_AGENT=1` to have them): Codex registers them
  in every session as the `codex_tui` MCP namespace, the local models reach for
  `create_thread` instead of doing the work, and then narrate results that
  never arrived.
- **Codex model catalog** (`codex_base_prompt` + `catalog_entry` in
  `bin/wrapCodex.sh`) — `/model` lists exactly what
  `model_catalog_json` contains, so the wrapper writes
  `$SESSION_DIR/etc/models.json` (mounted at `/etc/codex/models.json`) with one
  entry per model the servers reported. Two Codex quirks make this fiddly:
  an entry **must** carry `base_instructions`, because that string is sent as
  the model's system prompt — entries therefore reuse the prompt extracted
  from the installed binary (cached in `state/codex/base_instructions.md`,
  refreshed when the binary is newer; if extraction fails the catalog is
  skipped and Codex's own model list comes back) — and a model can only be
  used with the session's `model_provider`, which is what the model router
  exists to work around.
- **Codex model router** (`bin/codex-model-router.py`, started by
  `bin/codex-model-launch.sh`) — `turn/start` has no provider field, so `/model`
  alone can never leave the server a session started on (picking the other
  one 404s). The wrapper therefore points *every* provider at
  `http://127.0.0.1:8777/v1` and lets the router pick the upstream from the
  `model` in each request body. `$SESSION_DIR/router` (mounted read-only at
  `/opt/codex-router`) holds the copied scripts plus `routes.json`, which maps
  model -> `{base_url, env_key, reasoning_effort_map?}`: keys stay in the
  `CODEX_KEY_<NAME>` env vars, never in that file. An optional
  `reasoning_effort_map` (e.g. `{"high":"xhigh"}`) lets the router translate
  non-standard reasoning-effort values—vLLM's Qwen models use "xhigh" where
  OpenAI uses "high". The map is probed per server at launch via a trivial
  `/chat/completions` request (see `probe_reasoning_map` in `wrapCodex.sh`). launch.sh waits for `/health` before exec'ing Codex and
  logs to `~/.codex/model-router.log`; the router is a child of the agent
  process, so it dies with the VM, and each VM has its own loopback so
  concurrent sessions can share the port. `--shell` starts no router (a codex
  launched by hand there cannot reach the providers), and `WRAPCODEX_ROUTER=0`
  skips it entirely, putting the real server URLs back in the config. An
  upstream that refuses a request (a local model's half-written tool call gets
  echoed back and the server then calls the whole body unparsable) leaves both
  halves in `~/.codex/model-router-error.json`, named in the log line.
  `routes.json` is per session, so another launch can no longer rewrite it
  under a running router (the router's torn-read retry is left from when it
  could).
- **Codex `~/.codex/tmp` is a tmpfs**: Codex keeps its setuid sandbox helper
  there and garbage-collects "stale" helpers. It is kept off the host share;
  when the Codex home was shared, concurrent sessions deleted each other's
  helpers because file locks don't cross VMs.
- **Crush state**: `~/.config/crush/crush.json` is copied fresh each launch
  into the session's `config/` with the sandbox `AGENTS.md` injected into
  `options.context_paths` via `jq`, and mounted read-only (agent can't loosen
  its own permissions). The data dir `~/.local/share/crush` is the session's
  `data/`, seeded from `seed/crush.json` (model picks; first taken from the
  host's `{models, recent_models}` -- delete the seed file to re-seed).
- **Crush's `.crush` never lands in the working directory**: the generated
  config sets `options.data_directory` to `~/.local/share/crush/project`,
  which is `state/crush/shared/projects/<hash of cwd>`. That directory holds
  a SQLite db, so a host lock (`shared/locks/<hash>`) gives it to one session
  at a time; a second Crush in the same cwd gets a throwaway one in its
  session dir and a warning.
- **Claude state**: the session's `home/` is mounted as `~/.claude`
  (`CLAUDE_CONFIG_DIR`). `.claude.json`, `.credentials.json` and
  `history.jsonl` come from the seed and are saved back at exit;
  `shared/projects` (transcripts) is mounted over `~/.claude/projects`. Host
  `settings.json`/`settings.local.json` and `CLAUDE.md` are copied in each
  launch; host `hooks/` and `skills/` are mounted read-only so the sandboxed
  agent can't weaken its guardrails. The real `~/.claude` is only ever read.
  Auth: pass through `ANTHROPIC_API_KEY`/`CLAUDE_CODE_OAUTH_TOKEN` if set,
  else log in once inside (saved to the seed at exit). With file-based login
  and several sessions open, one session's token refresh is not seen by the
  others; `CLAUDE_CODE_OAUTH_TOKEN` avoids that.
- **AWS handling**: Codex and Crush get no credentials at all. `wrapClaude.sh`
  exports STS creds via `export` + `--env NAME` (by name, never `--env K=V`, so
  secrets stay out of argv); long-lived keys are exchanged with
  `aws sts get-session-token` (`WRAPCLAUDE_AWS_DURATION`, default 43200s);
  `WRAPCLAUDE_AWS=0` disables. Creds can't be refreshed mid-session.

## Dockerfile gotchas

- **The image is a snapshot of the Dockerfile**, rebuilt by the next launch
  after the Dockerfile changes. A session started before that keeps the old
  image, so a tool it cannot find (`gh` was the one that got everyone) means
  the session predates the layer, not that the layer is broken.
  Everything after a changed layer is rebuilt too, so inserting one mid-file
  costs the whole tail.
- Ubuntu 26.04 ships **uutils (Rust) coreutils** by default; the image forcibly
  swaps to GNU coreutils (`--allow-remove-essential
  coreutils-from-gnu coreutils-from-uutils-`). Scripts may rely on GNU-only
  flags/output.
- `fd` is a symlink to `/usr/bin/fdfind`; LLVM tools come via
  `/usr/lib/llvm` symlink → versioned dir on `PATH`.
- **Aider is not in the image** — it needs Python ≤3.12, image ships 3.14.
  `install-aider.sh` runs `wrapClaude.sh --toolkit` and fetches standalone
  CPython 3.12 into `/global/aider`.
- **gh CLI** is installed from the official GitHub release tarball in its own
  layer (like the AWS CLI). The tag is scraped from the `releases/latest`
  redirect; asset names are versioned, so there is no stable download URL.
- **Never `tar` directly into `/global` or the project mount**: GNU tar creates
  mode-000 placeholder files for `../` symlinks, which the host share can't
  open ("Permission denied"). Extract to `/tmp` (container disk) then `cp -a`
  — see `bin/install-aider.sh`.
- `ENTRYPOINT` is bare tini (default command `bash`); the launchers always
  pass their own entrypoint. Containers run with `--rm`; everything outside
  the mounts is discarded at exit.

## Env var reference

| Var | Default | Used by |
|---|---|---|
| `WRAPCLAUDE_IMAGE` / `WRAPAGENT_IMAGE` | `claude-sandbox:latest` | respective wrappers |
| `WRAPCLAUDE_STATE` | `$WRAPCLAUDE_GLOBAL/state/claude` | wrapClaude |
| `WRAPCODEX_STATE` | `$WRAPCLAUDE_GLOBAL/state/codex` | wrapCodex |
| `WRAPCRUSH_STATE` | `$WRAPCLAUDE_GLOBAL/state/crush` | wrapCrush |
| `WRAPCLAUDE_GLOBAL` | `/Volumes/ClaudeGlobal` | all wrappers (one shared name) |
| `WRAPCLAUDE_CPUS` / `WRAPAGENT_CPUS` | `4` | respective |
| `WRAPCLAUDE_MEMORY` / `WRAPAGENT_MEMORY` | `4G` | respective |
| `WRAPCLAUDE_AWS` / `WRAPCLAUDE_AWS_DURATION` | `1` / `43200` | wrapClaude only |
| `WRAPCODEX_PROVIDER` | — (first provider) | wrapCodex |
| `WRAPCODEX_ROUTER` / `WRAPCODEX_ROUTER_PORT` | `1` / `8777` | wrapCodex model router |
| `WRAPCODEX_MULTI_AGENT` | `0` | wrapCodex (set `1` to keep Codex's thread-spawning tools) |
| `WRAPCLAUDE_GITHUB` / `WRAPAGENT_GITHUB` | `1` | Claude / Codex+Crush (set `0` to skip GitHub token) |

Note the naming quirk: every wrapper reads the **global dir** from
`WRAPCLAUDE_GLOBAL`; Codex and Crush read image/CPU/memory from `WRAPAGENT_*`,
and wrapClaude maps its `WRAPCLAUDE_*` equivalents onto those.

## Style

- Bash: `set -euo pipefail`, array-built `run_args`, `die()` for errors
  (`wrap<Agent>:` prefix to stderr). `container run` is last but not
  `exec`ed: the launcher has to outlive it to finish the session.
- The launchers never signal processes; liveness of another launcher is
  checked with `ps -p`.
- The heredoc in `install-aider.sh` runs **inside the Linux sandbox**;
  everything before `exec` runs on macOS. Keep host-side code free of GNU-only
  assumptions, and keep it Bash 3.2-safe: the host really does run the stock
  macOS `/bin/bash` 3.2, so no `mapfile`/`readarray`, no associative arrays or
  `declare -n`, and empty arrays need `${arr[@]+"${arr[@]}"}`. `BASH_REMATCH`
  and `read -r` with process substitution are fine in 3.2.
- These are personal tools, so hard-coded personal paths
  (`/Volumes/ClaudeGlobal`, `~/.config/crush`) are expected, not oversights.
