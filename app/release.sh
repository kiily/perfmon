#!/bin/bash
# release.sh — ship a version: bump, build the DMG, publish a GitHub release,
# repoint the Homebrew cask at it. Usage: app/release.sh 1.2.0
# Then on any Mac: brew upgrade --cask kiily/perfmon/perfmon
set -eu
V="${1:?usage: app/release.sh VERSION (e.g. 1.2.0)}"
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$DIR")"
cd "$ROOT"

[ -z "$(git status --porcelain)" ] || { echo "release: commit or stash your changes first" >&2; exit 1; }
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $V" \
  -c "Set :CFBundleVersion $(($(git rev-list --count HEAD) + 1))" "$DIR/Info.plist"
"$DIR/build.sh"
"$DIR/build/Perfmon.app/Contents/MacOS/Perfmon" --selftest >/dev/null || { echo "release: self-test failed" >&2; exit 1; }

git commit -qm "perfmon.app $V" -- "$DIR/Info.plist"
git push -q
gh release create "v$V" "$DIR/build/Perfmon.dmg" --title "Perfmon $V" --generate-notes

SHA=$(shasum -a 256 "$DIR/build/Perfmon.dmg" | cut -d' ' -f1)
sed -i '' -E \
  -e "s/^  version \".*\"/  version \"$V\"/" \
  -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" \
  Casks/perfmon.rb
git commit -qm "cask: perfmon $V" -- Casks/perfmon.rb
git push -q
echo "released v$V → https://github.com/$REPO/releases/tag/v$V"
