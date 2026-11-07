#!/bin/bash
# Builds VoxDesk.app. Usage: ./build.sh                 -> /Applications/VoxDesk.app
#                            ./build.sh ~/Applications
# Signing: set VOXDESK_SIGN_IDENTITY to a codesigning identity name or hash. Without it the first
# "Apple Development" or "Developer ID Application" identity in the keychain is used, else ad-hoc ("-").
# A stable identity matters: macOS ties the Microphone and Accessibility grants to it, and ad-hoc
# signatures change on every build, so the grants would reset.
# VOXDESK_SWIFT_BUILD_FLAGS adds flags to `swift build` (the Homebrew formula passes --disable-sandbox).
# Swift 6.2 or later (Xcode 26 tools) builds both engines; older toolchains build Whisper only.
set -euo pipefail
cd "$(dirname "$0")"
dest="${1:-/Applications}"
app="$dest/VoxDesk.app"
version="${VOXDESK_VERSION:-1.0.0}"

read -r -a swift_flags <<< "${VOXDESK_SWIFT_BUILD_FLAGS:-}"
swift build -c release ${swift_flags[@]+"${swift_flags[@]}"}
bin="$(swift build -c release ${swift_flags[@]+"${swift_flags[@]}"} --show-bin-path)"

mkdir -p .build/icon
cp scripts/make-icon.swift .build/icon/main.swift
swiftc -O .build/icon/main.swift Sources/VoxDesk/Logo.swift -o .build/make-icon
.build/make-icon

# Quit the copy running from this location before replacing it.
if pgrep -f "^$app/Contents/MacOS/VoxDesk" >/dev/null; then
  osascript -e 'tell application id "dev.voxdesk.VoxDesk" to quit' >/dev/null 2>&1 || true
  sleep 1
  pkill -f "^$app/Contents/MacOS/VoxDesk" 2>/dev/null || true
fi

mkdir -p "$dest"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/VoxDesk" "$app/Contents/MacOS/VoxDesk"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
# SwiftPM resource bundles (KeyboardShortcuts' localisations) are found in Contents/Resources.
for b in "$bin"/*.bundle; do
  [ -d "$b" ] && cp -R "$b" "$app/Contents/Resources/"
done

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>VoxDesk</string>
<key>CFBundleDisplayName</key><string>VoxDesk</string>
<key>CFBundleIdentifier</key><string>dev.voxdesk.VoxDesk</string>
<key>CFBundleExecutable</key><string>VoxDesk</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$version</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSMicrophoneUsageDescription</key><string>VoxDesk listens only while you hold or tap its shortcut, and turns your speech into text on this Mac.</string>
<key>NSHumanReadableCopyright</key><string>MIT licensed. Parakeet TDT 0.6B v2 and Parakeet CTC 110M by NVIDIA (CC-BY-4.0) via FluidAudio (Apache-2.0); Whisper by OpenAI (MIT) via WhisperKit by Argmax (MIT); Silero VAD (MIT); KeyboardShortcuts by Sindre Sorhus (MIT).</string>
</dict></plist>
PLIST

identity="${VOXDESK_SIGN_IDENTITY:-}"
if [ -z "$identity" ]; then
  identity="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -Eo '"(Apple Development|Developer ID Application): [^"]+"' | head -1 | tr -d '"' || true)"
fi
identity="${identity:--}"
echo "Signing with: $([ "$identity" = "-" ] && echo "ad-hoc" || echo "$identity")"
codesign --force --options runtime --entitlements Resources/VoxDesk.entitlements --timestamp=none -s "$identity" "$app"
codesign --verify --strict "$app"
echo "Built $app"
