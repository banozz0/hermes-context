#!/bin/sh
# Builds build/HermesContext.app: a menu-bar-only (LSUIElement) bundle around the SwiftPM executable.
# OUT=<dir under app/> puts it elsewhere; UNIVERSAL=1 builds for Apple silicon and Intel.
set -eu
cd "$(dirname "$0")"
set -- -c release --product HermesContext
[ -z "${UNIVERSAL:-}" ] || set -- "$@" --arch arm64 --arch x86_64
swift build "$@"
version=$(sed -n 's/^version = "\(.*\)"$/\1/p' ../pyproject.toml)
app=${OUT:-build}/HermesContext.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$(swift build "$@" --show-bin-path)/HermesContext" "$app/Contents/MacOS/HermesContext"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>HermesContext</string>
    <key>CFBundleIdentifier</key><string>dev.banozz0.hermes-context</string>
    <key>CFBundleName</key><string>Hermes Context</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$app"
echo "$app"
