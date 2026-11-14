#!/usr/bin/env bash
# Install (or reinstall/upgrade) Aider into the toolkit (/global).
#
# Aider needs Python <= 3.12 and the image ships 3.14, so this fetches a
# standalone CPython 3.12 (astral-sh/python-build-standalone) into
# /global/aider/python, pip-installs aider-chat into it, and links
# /global/bin/aider. It runs inside the sandbox so everything is a Linux build.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --toolkit is the mode that mounts the toolkit read-write (and nothing else).
exec "$SCRIPT_DIR/wrapClaude.sh" --toolkit -s <<'EOF'
set -euo pipefail
dest=/global/aider
arch="$(uname -m)"

url="$(curl -fsSL https://api.github.com/repos/astral-sh/python-build-standalone/releases/latest \
  | jq -r --arg arch "$arch" '.assets[]
      | select(.name | test("^cpython-3\\.12\\.[0-9]+\\+[0-9]+-" + $arch + "-unknown-linux-gnu-install_only\\.tar\\.gz$"))
      | .browser_download_url' \
  | head -1)"
if [[ -z "$url" ]]; then
  echo "install-aider: no Python 3.12 build found for $arch" >&2
  exit 1
fi

[[ -d "$dest" ]] && { chmod -R u+rwX "$dest" 2>/dev/null || true; }
rm -rf "$dest"
mkdir -p "$dest" /global/bin
echo "Downloading ${url##*/}"
# Unpack on the container's own disk, then copy. GNU tar creates mode-000
# placeholder files for symlinks pointing at ../ targets, and the host side
# of the /global share cannot open those, so extracting straight into
# /global fails. The standalone Python is relocatable, so the move is safe.
staging="$(mktemp -d)"
curl -fsSL "$url" | tar -C "$staging" -xz
cp -a "$staging/python" "$dest/"
rm -rf "$staging"
# pip writes absolute paths into console scripts, so install into the final
# location rather than staging.
"$dest/python/bin/python3" -m pip install --no-cache-dir --disable-pip-version-check -q aider-chat
ln -sfn "$dest/python/bin/aider" /global/bin/aider
echo "Installed: $(/global/bin/aider --version)"
EOF
