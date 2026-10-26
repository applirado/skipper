#!/bin/bash
# Baut Skipper.app. Voraussetzung: Xcode oder Command Line Tools (xcode-select --install)
# ./build.sh            → baut Skipper.app in diesem Ordner
# ./build.sh --install  → baut und kopiert nach /Applications
set -euo pipefail
cd "$(dirname "$0")"
APP="Skipper.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "→ Kompiliere…"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos12.0" \
  -framework Cocoa -framework Quartz -framework Carbon \
  Sources/main.swift -o "$APP/Contents/MacOS/Skipper"

cp Info.plist "$APP/Contents/Info.plist"
# Übersetzungen (Resources/<Sprache>.lproj)
cp -R Resources/*.lproj "$APP/Contents/Resources/"

# App-Icon aus dem Finder-Ordnersymbol erzeugen (optional)
if command -v sips >/dev/null && [ -f /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericFolderIcon.icns ]; then
  cp /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericFolderIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" >/dev/null 2>&1 || true
fi

# Signieren: feste Identität aus .signing-identity (siehe setup.sh), sonst ad-hoc
IDENTITY="-"
if [ -s .signing-identity ]; then IDENTITY="$(cat .signing-identity)"; fi
if [ "$IDENTITY" != "-" ] && codesign --force --deep --timestamp=none -s "$IDENTITY" "$APP" 2>/dev/null; then
  echo "→ Signiert mit fester Identität ($IDENTITY)"
else
  [ "$IDENTITY" != "-" ] && echo "⚠︎ Signieren mit $IDENTITY fehlgeschlagen – nutze Ad-hoc-Signatur (./setup.sh ausführen)"
  codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true
fi
echo "✓ Fertig: $(pwd)/$APP"

if [ "${1:-}" = "--install" ]; then
  # Laufende Version sauber beenden (auch die frühere „Explorer.app“), sonst liefe die alte weiter
  for OLD in "$APP" "Explorer.app"; do
    if pgrep -f "/Applications/$OLD/Contents/MacOS/" >/dev/null; then
      osascript -e "quit app \"/Applications/$OLD\"" >/dev/null 2>&1 || true
      for _ in $(seq 1 20); do pgrep -f "/Applications/$OLD/Contents/MacOS/" >/dev/null || break; sleep 0.25; done
    fi
  done
  # Umbenennung: alte Explorer.app (gleiche Bundle-ID) entfernen, damit es nur eine Version gibt
  if [ -d "/Applications/Explorer.app" ] && [ "$(defaults read "/Applications/Explorer.app/Contents/Info" CFBundleIdentifier 2>/dev/null)" = "com.aioxio.explorer" ]; then
    rm -rf "/Applications/Explorer.app"
  fi
  rm -rf "/Applications/$APP"
  cp -R "$APP" /Applications/
  echo "✓ Installiert: /Applications/$APP"
  open "/Applications/$APP"
fi
