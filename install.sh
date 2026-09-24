#!/bin/bash
# Installs the latest Claude Usage Bar release.
#
#   curl -fsSL https://raw.githubusercontent.com/miladbeigi/claude-usage-bar/main/install.sh | bash
#
# Downloads the release zip, verifies its SHA-256, installs "Claude Usage Bar.app" and launches it.
# Files fetched with curl aren't quarantined, so macOS doesn't block the first launch.
#
# Environment:
#   REPO         GitHub "owner/repo" to install from (default: miladbeigi/claude-usage-bar)
#   INSTALL_DIR  where to put the app (default: existing install location, else /Applications if writable,
#                else ~/Applications)
set -euo pipefail

REPO="${REPO:-miladbeigi/claude-usage-bar}"
APP_NAME="Claude Usage Bar.app"

fail() { echo "Error: $*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "Claude Usage Bar only runs on macOS."
major="$(sw_vers -productVersion | cut -d. -f1)"
(( major >= 14 )) || fail "macOS 14 or later is required (you have $(sw_vers -productVersion))."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Finding the latest release of ${REPO}..."
curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" -o "$tmp/release.json" \
    || fail "couldn't reach GitHub."
tag="$(plutil -extract tag_name raw -o - "$tmp/release.json")"
version="${tag#v}"
zip="ClaudeUsageBar-$version.zip"
base="https://github.com/$REPO/releases/download/$tag"

echo "Downloading ${zip}..."
curl -fsSL "$base/$zip" -o "$tmp/$zip" || fail "couldn't download $zip."
curl -fsSL "$base/$zip.sha256" -o "$tmp/$zip.sha256" || fail "couldn't download the checksum."
(cd "$tmp" && shasum -a 256 -c "$zip.sha256" >/dev/null) || fail "checksum mismatch; not installing."

ditto -x -k "$tmp/$zip" "$tmp/unzipped"
[[ -d "$tmp/unzipped/$APP_NAME" ]] || fail "the download didn't contain $APP_NAME."

if [[ -z "${INSTALL_DIR:-}" ]]; then
    for dir in /Applications "$HOME/Applications"; do
        if [[ -d "$dir/$APP_NAME" || -d "$dir/ClaudeUsageBar.app" ]]; then INSTALL_DIR="$dir"; break; fi
    done
fi
if [[ -z "${INSTALL_DIR:-}" ]]; then
    if [[ -w /Applications ]]; then INSTALL_DIR=/Applications; else INSTALL_DIR="$HOME/Applications"; fi
fi
mkdir -p "$INSTALL_DIR"

pkill -x ClaudeUsageBar 2>/dev/null && sleep 1 || true
rm -rf "$INSTALL_DIR/$APP_NAME" "$INSTALL_DIR/ClaudeUsageBar.app" # current and pre-1.1 names
mv "$tmp/unzipped/$APP_NAME" "$INSTALL_DIR/"
xattr -dr com.apple.quarantine "$INSTALL_DIR/$APP_NAME" 2>/dev/null || true

open "$INSTALL_DIR/$APP_NAME"
echo "Installed Claude Usage Bar $version to $INSTALL_DIR and launched it. Look for it in the menu bar."
