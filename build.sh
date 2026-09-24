#!/bin/bash
# Builds "Claude Usage Bar.app".
#
#   ./build.sh             build "build/Claude Usage Bar.app"
#   ./build.sh --install   also copy to ~/Applications and launch
#   ./build.sh --zip       also write build/ClaudeUsageBar-<version>.zip and .zip.sha256 (release assets)
#
# Environment:
#   VERSION       app version (default: contents of ./VERSION)
#   UPDATE_REPO   GitHub "owner/repo" the app checks for updates
#                 (default: parsed from `git remote get-url origin`; empty disables updates)
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-$(cat VERSION)}"
VERSION="${VERSION#v}"
if [[ -z "${UPDATE_REPO+x}" ]]; then
    UPDATE_REPO="$(git remote get-url origin 2>/dev/null | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##' || true)"
fi

# Universal binary (Apple silicon + Intel), deployment target macOS 14.
BINS=()
for arch in arm64 x86_64; do
    FLAGS=(-c release --triple "$arch-apple-macosx14.0" --scratch-path ".build/$arch")
    swift build "${FLAGS[@]}"
    BINS+=("$(swift build "${FLAGS[@]}" --show-bin-path)/ClaudeUsageBar")
done

APP="build/Claude Usage Bar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/ClaudeUsageBar"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Claude Usage Bar</string>
    <key>CFBundleDisplayName</key><string>Claude Usage Bar</string>
    <key>CFBundleIdentifier</key><string>io.github.claude-usage-bar</string>
    <key>CFBundleExecutable</key><string>ClaudeUsageBar</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>UpdateRepository</key><string>${UPDATE_REPO}</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP (version $VERSION${UPDATE_REPO:+, updates from $UPDATE_REPO})"

for arg in "$@"; do
    case "$arg" in
    --zip)
        ZIP="build/ClaudeUsageBar-${VERSION}.zip"
        rm -f "$ZIP"
        ditto -c -k --keepParent "$APP" "$ZIP"
        (cd build && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
        echo "Wrote $ZIP and $ZIP.sha256"
        ;;
    --install)
        pkill -x ClaudeUsageBar || true
        mkdir -p ~/Applications
        rm -rf ~/Applications/ClaudeUsageBar.app "$HOME/Applications/Claude Usage Bar.app" # old and current names
        cp -R "$APP" ~/Applications/
        open "$HOME/Applications/Claude Usage Bar.app"
        echo "Installed to ~/Applications and launched"
        ;;
    esac
done
