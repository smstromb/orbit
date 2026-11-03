#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/build/Orbit.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$PWD/build/module-cache"
TOOLCHAIN="${ORBIT_RUST_TOOLCHAIN:-1.95.0}"
rustup run "$TOOLCHAIN" cargo build --manifest-path scanner/Cargo.toml --release --offline
cp scanner/target/release/orbit-scan "$APP/Contents/MacOS/orbit-scan"
mkdir -p "$PWD/build/Orbit.iconset"
xcrun swift -module-cache-path "$PWD/build/module-cache" scripts/icon.swift "$PWD/build/icon-1024.png"
for SIZE in 16 32 128 256 512; do
  sips -z "$SIZE" "$SIZE" "$PWD/build/icon-1024.png" --out "$PWD/build/Orbit.iconset/icon_${SIZE}x${SIZE}.png" >/dev/null
  DOUBLE=$((SIZE * 2))
  sips -z "$DOUBLE" "$DOUBLE" "$PWD/build/icon-1024.png" --out "$PWD/build/Orbit.iconset/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
python3 scripts/pack_icon.py "$PWD/build/Orbit.iconset" "$APP/Contents/Resources/Orbit.icns"
xcrun swiftc -O -parse-as-library -target arm64-apple-macosx14.0 -module-cache-path "$PWD/build/module-cache" Sources/Orbit.swift Sources/ScanWire.swift Sources/DiskSpace.swift Sources/Worktrees.swift Sources/WorktreeView.swift -o "$APP/Contents/MacOS/Orbit" -framework SwiftUI -framework AppKit
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Orbit</string>
<key>CFBundleIdentifier</key><string>local.orbit.disk-explorer</string>
<key>CFBundleName</key><string>Orbit</string>
<key>CFBundleDisplayName</key><string>Orbit</string>
<key>CFBundleIconFile</key><string>Orbit</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.4.0</string>
<key>CFBundleVersion</key><string>4</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHumanReadableCopyright</key><string>Personal disk explorer</string>
<key>NSDocumentsFolderUsageDescription</key><string>Orbit reads file sizes to visualize your disk usage.</string>
<key>NSDownloadsFolderUsageDescription</key><string>Orbit reads file sizes to visualize your disk usage.</string>
<key>NSDesktopFolderUsageDescription</key><string>Orbit reads file sizes to visualize your disk usage.</string>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP"
printf 'Built %s\n' "$APP"
