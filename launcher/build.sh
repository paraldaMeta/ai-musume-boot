#!/bin/zsh
# Build the boot-animation launchers into ./build.
#
#   ./build.sh                 build all four
#   ./build.sh kimi codex      build only these
#   ./build.sh --install       build, then copy into ~/Applications
#
# Needs only the Xcode Command Line Tools (`xcode-select --install`):
# swiftc, lipo, codesign. Icons are prebuilt in ./icons (see make-icons.sh).
# Images come from ../preview/assets.
set -euo pipefail

HERE="${0:A:h}"
ASSETS="$HERE/../preview/assets"
ICONS="$HERE/icons"
OUT="$HERE/build"
WORK="$OUT/.work"

INSTALL=0
WANT=()
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) WANT+=("$arg") ;;
  esac
done

# key | launcher name | target bundle id | fallback app names (comma-separated) | name shown while waiting
TABLE=(
  "claude|Claude 娘|com.anthropic.claudefordesktop|Claude.app|Claude"
  "codex|Codex 娘|com.openai.codex|Codex.app|Codex"
  "kimi|Kimi 娘|com.moonshot.kimichat|Kimi.app|Kimi"
  "workbuddy|WorkBuddy 娘|com.tencent.workbuddy.mac|WorkBuddy.app|WorkBuddy"
)

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "error: swiftc not found. Install the Xcode Command Line Tools: xcode-select --install" >&2
  exit 1
fi

mkdir -p "$OUT" "$WORK"

# One universal binary, so the same .app runs on Apple Silicon and Intel Macs.
echo "compiling launcher (arm64 + x86_64)"
for arch in arm64 x86_64; do
  xcrun swiftc -O -swift-version 5 -target "$arch-apple-macosx14.0" \
    -framework Cocoa -framework WebKit \
    -o "$WORK/launcher-$arch" "$HERE/src/Launcher.swift"
done
xcrun lipo -create -output "$WORK/launcher" "$WORK/launcher-arm64" "$WORK/launcher-x86_64"

BUILT=()
for row in "${TABLE[@]}"; do
  IFS='|' read -r key name target_id app_names target_name <<< "$row"
  if (( ${#WANT[@]} > 0 )) && [[ " ${WANT[*]} " != *" $key "* ]]; then continue; fi

  app="$OUT/$name.app"
  echo "building $name.app -> $target_name ($target_id)"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp "$WORK/launcher" "$app/Contents/MacOS/launcher"
  cp "$HERE/src/boot.html" "$app/Contents/Resources/boot.html"
  cp "$ASSETS/$key.jpg" "$ASSETS/$key-line.jpg" "$app/Contents/Resources/"
  cp "$ICONS/$key.icns" "$app/Contents/Resources/AppIcon.icns"

  names_xml=""
  for n in ${(s:,:)app_names}; do names_xml+="<string>$n</string>"; done

  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.bootanime.$key</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundleDisplayName</key><string>$name</string>
  <key>CFBundleExecutable</key><string>launcher</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>BootCharacter</key><string>$key</string>
  <key>BootTargetBundleID</key><string>$target_id</string>
  <key>BootTargetAppNames</key><array>$names_xml</array>
  <key>BootTargetName</key><string>$target_name</string>
</dict>
</plist>
PLIST

  # Ad-hoc signature: enough to run on the machine that built it.
  codesign --force --sign - "$app" 2>/dev/null
  BUILT+=("$app")
done

echo "built into $OUT"

if (( INSTALL )); then
  dest="$HOME/Applications"
  mkdir -p "$dest"
  for app in "${BUILT[@]}"; do
    target="$dest/${app:t}"
    if [[ -e "$target" ]]; then
      existing=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$target/Contents/Info.plist" 2>/dev/null || true)
      if [[ "$existing" != local.bootanime.* ]]; then
        echo "skipped ${app:t}: $target exists and is not one of these launchers" >&2
        continue
      fi
      rm -rf "$target"
    fi
    ditto "$app" "$target"
    echo "installed $target"
  done
  echo "drag them from ~/Applications into the Dock"
fi
