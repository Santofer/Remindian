#!/usr/bin/env bash
#
# update-casks.sh — keep the Homebrew cask in sync across BOTH locations so a
# release can never ship with a drifted version/sha:
#   1. Cask/remindian.rb            (in this repo — direct-URL installs)
#   2. Santofer/homebrew-tap        (Casks/remindian.rb — `brew tap` installs)
#
# Usage:
#   scripts/update-casks.sh <version> <path-to-dmg>
#
# Example:
#   scripts/update-casks.sh 5.12.0 dist/Remindian-5.12.0.dmg
#
# Idempotent and safe to re-run. Requires: shasum, git, gh (authenticated).
set -euo pipefail

VERSION="${1:?usage: update-casks.sh <version> <dmg-path>}"
DMG="${2:?usage: update-casks.sh <version> <dmg-path>}"

[[ -f "$DMG" ]] || { echo "error: DMG not found: $DMG" >&2; exit 1; }

SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IN_REPO_CASK="$REPO_ROOT/Cask/remindian.rb"

echo "Version: $VERSION"
echo "SHA256:  $SHA"

# --- 1. In-repo cask -------------------------------------------------------
/usr/bin/sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/" "$IN_REPO_CASK"
/usr/bin/sed -i '' -E "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$IN_REPO_CASK"
echo "Updated $IN_REPO_CASK"

# --- 2. Tap cask -----------------------------------------------------------
TAP_DIR="$(mktemp -d)"
trap 'rm -rf "$TAP_DIR"' EXIT
git clone --quiet https://github.com/Santofer/homebrew-tap.git "$TAP_DIR"
TAP_CASK="$TAP_DIR/Casks/remindian.rb"

# The tap cask is byte-identical to the in-repo cask — copy it over so the two
# never diverge in anything (desc, zap, deps), not just version/sha.
cp "$IN_REPO_CASK" "$TAP_CASK"

if git -C "$TAP_DIR" diff --quiet; then
  echo "Tap cask already up to date — nothing to push."
else
  git -C "$TAP_DIR" add Casks/remindian.rb
  git -C "$TAP_DIR" -c user.email=aminebenboubker@gmail.com -c user.name=Santofer \
      commit --quiet -m "Update Remindian cask to v$VERSION"
  git -C "$TAP_DIR" push --quiet origin main
  echo "Pushed tap cask v$VERSION"
fi

echo "Done. Verify with: brew update && brew info --cask Santofer/tap/remindian"
