# Container sandboxes

Run [Claude Code](https://docs.anthropic.com/en/docs/agents-and-sdk/claude-code),
[OpenAI Codex CLI](https://github.com/openai/codex), and [Charm Crush](https://github.com/charmbracelet/crush)
inside locked-down Linux VMs launched with Apple's [`container`](https://github.com/apple/container)
runtime on macOS.

Each `container run` is its own lightweight Linux VM: the host process space,
credentials, and filesystem layout are invisible and unreachable from inside.
The current project directory is the only writable host path a sandbox can
see, so there is no shell-out escape from the sandbox boundary to the rest of
your Mac.

## Requirements

- **macOS** host with the Apple `container` CLI installed and its system
  daemon running (`container system start`).
- A **persistent volume** mounted at `/Volumes/ClaudeGlobal` (an APFS
  volume, case-sensitive is recommended). The toolkit and all agent state
  live here; nothing is written to your home directory. Override the path
  with `WRAPCLAUDE_GLOBAL`.
- Optionally, `gh auth login` on the host (so GitHub access works in
  sandboxes) and `aws configure` / `aws sso login` on the host (for the
  Claude sandbox's AWS access).

## How it is laid out

| What | Host | In the sandbox | Writable by a session |
|------|------|----------------|-----------------------|
| **Toolkit**: the three agents, Aider, shared tools | `/Volumes/ClaudeGlobal/toolkit` | `/global` | no, read-only |
| Compilers, `gh`, system tooling | the image | `/usr/...` | no |
| **Session state**: the agent's home and generated config | `/Volumes/ClaudeGlobal/state/<agent>/sessions/<id>` | `~/.claude`, `~/.codex`, ... | yes, and only by that session; removed at exit |
| Seed (login, model picks) and shared history | `/Volumes/ClaudeGlobal/state/<agent>/{seed,shared}` | copied in / mounted | via the session |
| **Working directory** | wherever you launched | same path | yes, the work and nothing else |

Every session of every agent sees the same read-only toolkit and gets its
own state directory, so you can run as many sessions as you like at once:
several Claudes, several Crushes, any mix, on any repos. Package managers
(`npm -g`, `cargo install`, `go install`) install to the VM's own disk and
vanish with the session.

Each launch uses the image built from the current `Dockerfile` (rebuilt
automatically when the file changes) and whatever is in the toolkit.

Claude is handed more of the host than the other two: `~/.config` read-only,
short-lived AWS credentials, and your `~/.claude` settings, hooks and skills.
Codex and Crush run with `--cap-drop ALL` and get none of that.

The wrappers share `bin/wrap-common.sh`, which handles flag parsing, the
image, mounts, the session lifecycle and launch. A wrapper only sets a few
variables (`AGENT`, `AGENT_PKG`, `AGENT_BIN`, `AGENT_ARGS`), defines
`agent_setup`/`agent_finish`, and calls `wrap_main`.

## The toolkit

A launch installs its agent into the toolkit if it is not there yet. To
upgrade one, or add shared tools, use the two modes that mount the toolkit
read-write (and nothing else from the host):

```sh
bin/wrapClaude.sh --install    # likewise wrapCodex.sh, wrapCrush.sh
bin/wrapClaude.sh --toolkit    # bash with /global writable
bin/install-aider.sh           # Aider + its own Python 3.12 into /global/aider
```

On the first launch after upgrading from the old layout, the tools at the top
of the volume are moved into `toolkit/` and each agent's old
`~/.<agent>-container` state is imported; those old directories can then be
deleted.

## Usage

### Claude Code

```sh
bin/wrapClaude.sh              # launch claude in the sandbox cwd
bin/wrapClaude.sh --shell      # drop into bash in the sandbox instead
bin/wrapClaude.sh --rebuild    # force an image rebuild first, then launch
```

AWS credentials: short-lived STS session tokens are minted on the host via
`aws sts get-session-token` and passed by env-var name (long-lived keys are
never forwarded directly). Disable with `WRAPCLAUDE_AWS=0`.

GitHub: the host `GH_TOKEN` (or `gh auth token`) is passed as `GH_TOKEN` and
git is configured through `GIT_CONFIG_*` env vars. Disable with
`WRAPCLAUDE_GITHUB=0`.

### Codex CLI

```sh
bin/wrapCodex.sh                          # use the first provider in crush.json
bin/wrapCodex.sh --provider vllm-remote   # pick a different provider
bin/wrapCodex.sh --shell                  # bash in the sandbox (no model router)
bin/wrapCodex.sh --rebuild                # rebuild image first
```

Codex binds one `base_url` to a session, but the wrappers point **every**
provider at a loopback [model router](bin/codex-model-router.py)
(started by [codex-model-launch.sh](bin/codex-model-launch.sh) in place of
the `codex` binary). The router reads `routes.json` and forwards each request
to whichever upstream server reports the requested model — that is what lets
`/model` hop between servers mid-session. Disable the router with
`WRAPCODEX_ROUTER=0` (then each provider talks directly to its server).

On every launch the wrapper:
1. Reads `openai-compat` providers from `~/.config/crush/crush.json`.
2. Live-probes each server's `/models` to discover the model actually being
   served (keys are piped via stdin so they never appear in argv).
3. Writes `models.json`, `config.toml`, and `requirements.toml` into
   the session's own `etc/`, mounted read-only at `/etc/codex`.
4. Extracts Codex's shipped base prompt from the installed binary so each
   catalog entry can carry it (required by Codex) without overriding it.

### Crush

```sh
bin/wrapCrush.sh
bin/wrapCrush.sh --rebuild
```

Crush reads `~/.config/crush/crush.json` (copied fresh and mounted read-only,
with `AGENTS_container.md` appended to `options.context_paths`). Its
per-project data (what would be `.crush/` in the repo) is kept on the volume
instead; one Crush session per directory keeps its history, a second
concurrent one in the same directory starts with a throwaway one.

## Configuration

Copy `crush.example.json` to `~/.config/crush/crush.json` and edit it:

```sh
cp crush.example.json ~/.config/crush/crush.json
```

API keys in `crush.json` may be literal or reference an environment variable
(`"$VLLM_API_KEY"` or `"${VLLM_API_KEY}"`), which keeps real keys out of the
config file. The wrappers export the resolved keys as `CODEX_KEY_<NAME>` env
vars (by name, never by value in argv).

## Environment variables

| Variable | Default | Used by |
|---|---|---|
| `WRAPCLAUDE_IMAGE` / `WRAPAGENT_IMAGE` | `claude-sandbox:latest` | image name |
| `WRAPCLAUDE_STATE` | `$WRAPCLAUDE_GLOBAL/state/claude` | Claude state dir |
| `WRAPCODEX_STATE` | `$WRAPCLAUDE_GLOBAL/state/codex` | Codex state dir |
| `WRAPCRUSH_STATE` | `$WRAPCLAUDE_GLOBAL/state/crush` | Crush state dir |
| `WRAPCLAUDE_GLOBAL` | `/Volumes/ClaudeGlobal` | the volume (all wrappers read this name) |
| `WRAPCLAUDE_CPUS` / `WRAPAGENT_CPUS` | `4` | CPU allocation |
| `WRAPCLAUDE_MEMORY` / `WRAPAGENT_MEMORY` | `4G` | memory limit |
| `WRAPCLAUDE_AWS` | `1` | AWS credential forwarding (Claude only) |
| `WRAPCLAUDE_AWS_DURATION` | `43200` | STS token lifetime in seconds |
| `WRAPCODEX_PROVIDER` | first provider | default Codex provider |
| `WRAPCODEX_ROUTER` | `1` | enable the model router |
| `WRAPCODEX_ROUTER_PORT` | `8777` | router listen port |
| `WRAPCLAUDE_GITHUB` / `WRAPAGENT_GITHUB` | `1` | pass GitHub token to sandbox |

> Every wrapper reads the volume path from `WRAPCLAUDE_GLOBAL`; Codex and
> Crush read image/CPU/memory from `WRAPAGENT_*`.

## Building the image

All wrappers share one image. It is rebuilt automatically by the next launch
after the `Dockerfile` changes; force a rebuild (to pick up newer upstream
releases) with:

```sh
bin/wrapClaude.sh --rebuild
```

The `Dockerfile` builds on `ubuntu:26.04` and installs GCC/G++ 15, LLVM/Clang
22, Python 3.14, Node.js 22, Rust, Go, AWS CLI v2 and gh (the agents are in the toolkit). It
forcibly swaps Ubuntu's default uutils coreutils for GNU coreutils so
scripts can rely on GNU flags. The build passes host `id -u`/`id -g` as
`USER_UID`/`USER_GID` so files written into the mounted project keep host
ownership.

## Layout

```
Dockerfile                 # the sandbox image (ubuntu:26.04 + toolchains)
bin/
  wrap-common.sh           # shared launcher logic (sourced)
  wrapClaude.sh            # Claude Code launcher
  wrapCodex.sh             # Codex launcher + config/router generation
  wrapCrush.sh             # Crush launcher
  github-common.sh         # shared GitHub credential injection (sourced)
  codex-model-router.py    # loopback proxy: model → upstream server
  codex-model-launch.sh    # starts the router, then execs codex
  install-aider.sh         # installs Aider + Python 3.12 into the toolkit
crush.example.json         # example crush.json to copy & edit
AGENTS_container.md        # runtime system prompt injected into Codex/Crush VMs
CLAUDE_container.md        # runtime system prompt injected into Claude VMs
.gitignore
```

The `*_container.md` files are **runtime prompts**, not repo docs: each
wrapper copies them into the sandbox at launch time so the agent knows its
environment constraints. AGENTS.md is the internal working note for agents
editing this repo itself.
