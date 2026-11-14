
# Sandbox environment (wrapCodex.sh / wrapCrush.sh)

You are running inside a locked-down Linux container (Ubuntu 26.04 LTS,
arm64), started by Apple's `container` runtime on a macOS host. You are not on
macOS.

Toolchains in the image: GCC/G++ 15, LLVM/Clang 22, Python 3.14, Node.js 22,
Rust (rustup, stable), Go (latest), gh.

## What you can see
- The current project directory is the ONLY writable host path. It is mounted
  at the same absolute path as on the Mac.
- `/global` is a shared tool directory, mounted READ-ONLY. You may run tools
  from it (they are on PATH) but cannot change it.
- Your own state directory is private to this session; other sessions,
  including ones running the same agent right now, have their own.
- Nothing else from the host is visible: no `~/.config`, no `~/.ssh`, no
  `~/.aws`, no credentials other than your own provider login and, if
  GitHub access was granted, the `GH_TOKEN` environment variable.
- GitHub: no SSH keys. If `GH_TOKEN` is set, git is preconfigured to use it
  for github.com over HTTPS (clone/fetch/push work; `git@github.com:` URLs
  are rewritten to HTTPS), and your commit identity is preset. Commits are
  unsigned. Never print `$GH_TOKEN`. If it is missing or requests are
  rejected, ask the user to restart the session (after `gh auth login` on
  the host).
- `/tmp`, your home directory and everything outside the project are discarded
  when the session ends. `npm install -g`, `cargo install` and `go install`
  work but do not persist.
- The project directory is on the Mac's case-insensitive filesystem.
- Host processes are not visible and cannot be affected.

## Installing software
- You run as an unprivileged user with no sudo and no Linux capabilities.
  `apt-get install` and other system-wide installs will fail.
- If a task needs a missing system tool, stop and ask the user to add it to
  the image (the `Dockerfile` at the top of the launcher repo on the host).
  Name the exact packages needed.
- Project-local installs persist but are Linux builds; the user may also work
  on the project natively on macOS:
  - Python: use a `.venv-linux` virtualenv, never `.venv`.
  - Node: check with the user before running `npm install` in a project that
    already has `node_modules`.
