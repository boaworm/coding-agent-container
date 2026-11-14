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
- A **persistent global volume** mounted at `/Volumes/ClaudeGlobal` (an
  APFS volume, case-sensitive is recommended). This is where agent binaries
  and shared tooling live. Override the path with `WRAPCLAUDE_GLOBAL`.
- The agent CLIs installed once into `/global/npm`. See [Installing agents](#installing-agents).
- Optionally, `gh auth login` on the host (so GitHub access works in
  sandboxes) and `aws configure` / `aws sso login` on the host (for the
  Claude sandbox's AWS access).

## The two sandbox tiers

| Tier | Wrappers | `/global` | Capabilities | AWS | `~/.config` | Use |
|------|----------|-----------|--------------|-----|-------------|-----|
| **Permissive** | `wrapClaude.sh` | read-write | full | STS session creds passed in | mounted read-only | General dev with full local tooling |
| **Strict** | `wrapCodex.sh`, `wrapCrush.sh` | read-only | `--cap-drop ALL`, no AWS/SSH keys | none | not mounted | Untrusted/remote code |

The strict wrappers share `bin/lockdown-common.sh`, which handles flag parsing,
image rebuilds, the capability drop, read-only mounts, and launch. A wrapper
only sets a few variables (`AGENT`, `AGENT_PKG`, `AGENT_BIN`, `AGENT_ARGS`),
defines `agent_setup`, and calls `lockdown_main`.

## Installing agents

Each agent CLI is installed once into `/global/npm` and reused by every
session. Only `--install` mounts `/global` read-write; every other mode
mounts it read-only (strict tier) or read-write (Claude tier).

```sh
bin/wrapCrush.sh --install     # Crush into /global/npm
bin/wrapCodex.sh --install     # Codex CLI into /global/npm
# Claude is baked into the image, so no --install is needed.
```

Aider (needs Python ≤ 3.12; the image ships 3.14) is installed separately
into `/global/aider` by `bin/install-aider.sh`, which launches a shell
sandbox and fetches a standalone CPython 3.12:

```sh
bin/install-aider.sh
```

## Usage

### Claude Code (permissive tier)

```sh
bin/wrapClaude.sh              # launch claude in the sandbox cwd
bin/wrapClaude.sh --shell      # drop into bash in the sandbox instead
bin/wrapClaude.sh --rebuild    # rebuild the image first, then launch
```

AWS credentials: short-lived STS session tokens are minted on the host via
`aws sts get-session-token` and passed by env-var name (long-lived keys are
never forwarded directly). Disable with `WRAPCLAUDE_AWS=0`.

GitHub: the host `GH_TOKEN` (or `gh auth token`) is passed as `GH_TOKEN` and
git is configured through `GIT_CONFIG_*` env vars. Disable with
`WRAPCLAUDE_GITHUB=0`.

### Codex CLI (strict tier)

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
   `$WRAPCODEX_STATE/etc`, mounted read-only at `/etc/codex`.
4. Extracts Codex's shipped base prompt from the installed binary so each
   catalog entry can carry it (required by Codex) without overriding it.

### Crush (strict tier)

```sh
bin/wrapCrush.sh
bin/wrapCrush.sh --rebuild
```

Crush reads `~/.config/crush/crush.json` (copied fresh and mounted read-only,
with `AGENTS_container.md` appended to `options.context_paths`). Its data dir
is seeded once from the host's model picks — delete
`~/.crush-container/data/crush.json` to re-seed.

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
| `WRAPCLAUDE_STATE` | `~/.claude-container` | Claude state dir |
| `WRAPCODEX_STATE` | `~/.codex-container` | Codex state dir |
| `WRAPCRUSH_STATE` | `~/.crush-container` | Crush state dir |
| `WRAPCLAUDE_GLOBAL` | `/Volumes/ClaudeGlobal` | shared global volume (all wrappers read this name) |
| `WRAPCLAUDE_CPUS` / `WRAPAGENT_CPUS` | `4` | CPU allocation |
| `WRAPCLAUDE_MEMORY` / `WRAPAGENT_MEMORY` | `4G` | memory limit |
| `WRAPCLAUDE_AWS` | `1` | AWS credential forwarding (Claude only) |
| `WRAPCLAUDE_AWS_DURATION` | `43200` | STS token lifetime in seconds |
| `WRAPCODEX_PROVIDER` | first provider | default Codex provider |
| `WRAPCODEX_ROUTER` | `1` | enable the model router |
| `WRAPCODEX_ROUTER_PORT` | `8777` | router listen port |
| `WRAPCLAUDE_GITHUB` / `WRAPAGENT_GITHUB` | `1` | pass GitHub token to sandbox |

> The strict wrappers read the global-dir path from `WRAPCLAUDE_GLOBAL` and
> CPU/memory from `WRAPAGENT_*`, so overrides do not follow the per-agent
> prefix consistently. This is intentional and kept simple.

## Building the image

All wrappers share one image. Rebuild it explicitly with:

```sh
bin/wrapClaude.sh --rebuild
```

The `Dockerfile` builds on `ubuntu:26.04` and installs GCC/G++ 15, LLVM/Clang
22, Python 3.14, Node.js 22, Rust, Go, AWS CLI v2, gh, and Claude Code. It
forcibly swaps Ubuntu's default uutils coreutils for GNU coreutils so
scripts can rely on GNU flags. The build passes host `id -u`/`id -g` as
`USER_UID`/`USER_GID` so files written into the mounted project keep host
ownership.

## Layout

```
Dockerfile                 # the sandbox image (ubuntu:26.04 + toolchains)
bin/
  wrapClaude.sh            # permissive launcher
  wrapCodex.sh             # strict launcher + config/router generation
  wrapCrush.sh             # strict launcher
  lockdown-common.sh       # shared strict-tier logic (sourced)
  github-common.sh         # shared GitHub credential injection (sourced)
  codex-model-router.py    # loopback proxy: model → upstream server
  codex-model-launch.sh    # starts the router, then execs codex
  install-aider.sh         # installs Aider + Python 3.12 into /global
crush.example.json         # example crush.json to copy & edit
AGENTS_container.md        # runtime system prompt injected into Codex/Crush VMs
CLAUDE_container.md        # runtime system prompt injected into Claude VMs
.gitignore
```

The `*_container.md` files are **runtime prompts**, not repo docs: each
wrapper copies them into the sandbox at launch time so the agent knows its
environment constraints. AGENTS.md is the internal working note for agents
editing this repo itself.
