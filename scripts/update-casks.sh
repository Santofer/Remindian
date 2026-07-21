#!/usr/bin/env bash
#
# update-casks.sh — keep the Homebrew cask in sync across ALL locations so a
# release can never ship with a drifted version/sha/url:
#   1. Cask/remindian.rb              (in this repo — direct-URL installs)
#   2. Santofer/homebrew-tap          (Casks/remindian.rb — canonical `brew tap`)
#   3. Santofer/homebrew-remindian    (legacy tap — kept in sync so users who
#                                      tapped it are never served a stale build)
#
# Usage:
#   scripts/update-casks.sh <version> <path-to-dmg>
#
# Example:
#   scripts/update-casks.sh 5.12.0 dist/Remindian-5.12.0.dmg
#
# Idempotent and safe to re-run. Requires: shasum, git, curl, gh (authenticated).
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

# --- 2. Verify the cask's download URL actually resolves --------------------
# The cask builds its filename from the version; the release script names the
# DMG separately. When those two drifted (the asset lost its "v" prefix at
# v5.24.0) every `brew install` 404'd for a month before a user reported it
# (#84). Resolve the URL the cask will really request and hard-fail on anything
# other than 200 — a release must never publish a cask that cannot download.
CASK_URL="$(/usr/bin/sed -nE 's/^  url "(.*)".*/\1/p' "$IN_REPO_CASK" \
  | /usr/bin/sed -e "s/#{version}/$VERSION/g")"
echo "Cask URL: $CASK_URL"
HTTP_CODE="$(curl -sIL -o /dev/null -w '%{http_code}' "$CASK_URL" || echo 000)"
if [[ "$HTTP_CODE" != "200" ]]; then
  echo "error: cask download URL does not resolve (HTTP $HTTP_CODE)" >&2
  echo "       $CASK_URL" >&2
  echo "       Publish the release asset first, or fix the url line in $IN_REPO_CASK" >&2
  echo "       so its filename matches the uploaded asset exactly." >&2
  exit 1
fi
echo "URL OK (HTTP 200)"

# Belt-and-braces: the published asset must match the DMG we just built.
REMOTE_SHA="$(curl -sL "$CASK_URL" | shasum -a 256 | cut -d' ' -f1)"
if [[ "$REMOTE_SHA" != "$SHA" ]]; then
  echo "error: published asset SHA does not match the local DMG" >&2
  echo "       local:     $SHA" >&2
  echo "       published: $REMOTE_SHA" >&2
  exit 1
fi
echo "Published asset SHA matches the local DMG"

# --- 3. Tap casks ----------------------------------------------------------
# homebrew-tap is canonical; homebrew-remindian is a legacy tap that some users
# still have installed. Both get the byte-identical cask so neither can serve a
# stale build (the legacy tap was pinned at 5.5.0 and actively *downgraded*
# users who upgraded through it — #84).
push_tap() {
  local repo="$1"
  local dir; dir="$(mktemp -d)"
  git clone --quiet "https://github.com/Santofer/$repo.git" "$dir"
  mkdir -p "$dir/Casks"
  cp "$IN_REPO_CASK" "$dir/Casks/remindian.rb"
  if git -C "$dir" diff --quiet; then
    echo "$repo: already up to date — nothing to push."
  else
    git -C "$dir" add Casks/remindian.rb
    git -C "$dir" -c user.email=aminebenboubker@gmail.com -c user.name=Santofer \
        commit --quiet -m "Update Remindian cask to v$VERSION"
    git -C "$dir" push --quiet origin HEAD
    echo "$repo: pushed cask v$VERSION"
  fi
  rm -rf "$dir"
}

push_tap homebrew-tap
push_tap homebrew-remindian

echo "Done. Verify with: brew update && brew info --cask Santofer/tap/remindian"
