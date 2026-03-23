#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 /path/to/linux/bundle [prefix]" >&2
  exit 1
fi

bundle_dir="$1"
prefix="${2:-$HOME/.local}"

if [[ ! -d "$bundle_dir" ]]; then
  echo "Bundle directory not found: $bundle_dir" >&2
  exit 1
fi

install -d "$prefix/share/applications"
install -d "$prefix/share/icons/hicolor/1024x1024/apps"

install -m 0644 "$bundle_dir/share/applications/pushstr.desktop" \
  "$prefix/share/applications/pushstr.desktop"
install -m 0644 "$bundle_dir/share/icons/hicolor/1024x1024/apps/pushstr.png" \
  "$prefix/share/icons/hicolor/1024x1024/apps/pushstr.png"

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$prefix/share/applications" >/dev/null 2>&1 || true
fi

if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -q "$prefix/share/icons/hicolor" >/dev/null 2>&1 || true
fi

echo "Installed Pushstr desktop entry and icon into $prefix"
