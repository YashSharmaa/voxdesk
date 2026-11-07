#!/bin/bash
# Installs VoxDesk: checks the Mac, gets the source (this checkout, or a fresh clone), builds it with build.sh
# and installs /Applications/VoxDesk.app.
#   curl -fsSL https://raw.githubusercontent.com/YashSharmaa/voxdesk/main/install.sh | bash
# VOXDESK_DEST installs somewhere else (for example ~/Applications).
set -euo pipefail

repo="https://github.com/YashSharmaa/voxdesk.git"
dest="${VOXDESK_DEST:-/Applications}"

say() { printf '==> %s\n' "$*"; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "VoxDesk runs on macOS only."
[ "$(uname -m)" = "arm64" ] || die "VoxDesk needs Apple Silicon (M1 or later)."
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 14 ] || die "VoxDesk needs macOS 14 or later (this Mac has $(sw_vers -productVersion))."

if ! xcode-select -p >/dev/null 2>&1 || ! command -v swift >/dev/null 2>&1; then
  say "The Xcode command-line tools are needed to build VoxDesk."
  answer=""
  if [ -r /dev/tty ]; then
    printf 'Run "xcode-select --install" now? [Y/n] ' > /dev/tty
    read -r answer < /dev/tty || true
  fi
  case "$answer" in
    [nN]*) die "Install them with: xcode-select --install" ;;
    *) xcode-select --install || true
       die "Finish the command-line tools installer, then run this script again." ;;
  esac
fi

swift_version="$(swift --version 2>/dev/null | grep -Eo 'Swift version [0-9]+\.[0-9]+' | grep -Eo '[0-9]+\.[0-9]+' | head -1)"
if [ -n "$swift_version" ] && awk -v v="$swift_version" 'BEGIN { split(v, a, "."); exit !(a[1] < 6 || (a[1] == 6 && a[2] < 2)) }'; then
  say "Swift $swift_version is older than 6.2: building the Multilingual (Whisper) engine only."
  say "Update the command-line tools for the Fast English engine."
fi

script_dir=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
if [ -n "$script_dir" ] && [ -f "$script_dir/Package.swift" ] && [ -x "$script_dir/build.sh" ]; then
  src="$script_dir"
  say "Using the checkout at $src"
else
  command -v git >/dev/null 2>&1 || die "git is needed (it comes with the command-line tools)."
  src="${TMPDIR:-/tmp}/voxdesk-src"
  rm -rf "$src"
  say "Cloning $repo"
  git clone --depth 1 "$repo" "$src"
fi

if [ ! -w "$dest" ] && [ -d "$dest" ]; then
  die "$dest is not writable. Run with VOXDESK_DEST=~/Applications, or fix its permissions."
fi

say "Building (the first build fetches the Swift packages and takes a few minutes)"
"$src/build.sh" "$dest"

say "Installed $dest/VoxDesk.app"
say "Open it with: open \"$dest/VoxDesk.app\""
say "Command line: \"$dest/VoxDesk.app/Contents/MacOS/VoxDesk\" --help"
