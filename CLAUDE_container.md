
# Sandbox environment (wrapClaude.sh)

You are running inside a Linux container (Ubuntu 26.04 LTS, arm64), started by
Apple's `container` runtime on a macOS host. You are not on macOS.

Toolchains in the image: GCC/G++ 15, LLVM/Clang 22 (clang, lld, lldb, clangd,
clang-format, clang-tidy, libc++), Python 3.14, Node.js 22, Rust (rustup,
stable), Go (latest), AWS CLI v2, gh. Aider lives in `/global/aider` with its own
Python 3.12 and is on PATH as `aider`.

## What you can see
- The current project directory is the only writable host path. It is mounted
  at the same absolute path as on the Mac, so paths match the host.
- `~/.config` is the host's config dir, mounted read-only.
- `~/.claude/hooks` and `~/.claude/skills` are read-only.
- `/global` is a persistent, read-write directory shared by every sandbox
  session across all projects (host: `/Volumes/ClaudeGlobal`, a case-sensitive
  APFS volume).
  Use it for tools and files that should outlive the session and be reused
  elsewhere. Do not put project-specific secrets or data there.
- The project directory is on the Mac's case-insensitive filesystem: `Foo`
  and `foo` are the same file there. `/global` and `/tmp` are case-sensitive;
  put anything that needs names differing only in case there.
- Extracting archives with GNU `tar` directly into the project dir or `/global`
  can fail with "Permission denied" on symlinks that point at `../` targets
  (tar's mode-000 placeholders can't be opened through the host share).
  Extract into `/tmp` first, then `cp -a` into place.
- `/tmp` and everything outside the mounts are discarded when the session ends.
- Host processes are not visible and cannot be affected; `ps` shows only this
  container's processes.
- macOS tools (`open`, `pbcopy`, `security`/Keychain, Homebrew, `osascript`) do
  not exist here.
- AWS: there is no `~/.aws`. If AWS access was granted, short-lived credentials
  are in the `AWS_*` environment variables. They cannot be refreshed from
  inside; if they are missing or expired, ask the user to restart the session
  (after `aws login` on the host if needed). Never print their values.
- GitHub: there are no SSH keys. If GitHub access was granted, the token is
  in the `GH_TOKEN` environment variable and git is preconfigured (via
  `GIT_CONFIG_*` env vars) to authenticate to github.com over HTTPS, so
  clone/fetch/push work with both `https://` and `git@github.com:` remotes.
  Commit identity (`user.name`/`user.email`) is preset from the host; commits
  are unsigned. `gh` is installed and uses the same token. Never print
  `$GH_TOKEN`; if it is missing or a request is rejected, ask the user to
  restart the session (after `gh auth login` on the host if needed).

## Installing software
- You run as an unprivileged user (`claude`) with no sudo. `apt-get install`
  and other system-wide installs will fail.
- User-level tools persist if installed under `/global`, which is on PATH:
  `npm install -g` goes to `/global/npm` automatically; standalone Linux
  binaries or scripts go in `/global/bin`. Installs anywhere else in `~` are
  lost at exit.
- If a task needs a system tool or language runtime that is missing, stop and
  ask the user to add it to the image: the Dockerfile is at
  the `Dockerfile` at the top of the launcher repo on the host, and they
  rebuild with `wrapClaude.sh --rebuild`. Name the exact packages needed.
- Project-local installs (into the project directory) persist, but they are
  Linux builds and the user may also work on the same project natively on macOS:
  - Python: use a `.venv-linux` virtualenv, never `.venv`. If you find an
    existing `.venv`, assume it belongs to macOS and do not use or modify it
    (check with `grep home .venv/pyvenv.cfg` if unsure).
  - Node: `node_modules` with native addons (`*.node` files) built here will not
    work on macOS and vice versa. Before running `npm install` in a project that
    already has `node_modules`, check with the user.
