#!/bin/bash
# Erzeugt Resources/AppIcon.icns aus Design/AppIcon.svg. Nur nötig, wenn sich das Logo ändert.
# Voraussetzung: rsvg-convert (brew install librsvg)
set -euo pipefail
cd "$(dirname "$0")"
SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET"
for s in 16 32 128 256 512; do
  rsvg-convert -w $s -h $s Design/AppIcon.svg -o "$SET/icon_${s}x${s}.png"
  rsvg-convert -w $((s * 2)) -h $((s * 2)) Design/AppIcon.svg -o "$SET/icon_${s}x${s}@2x.png"
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
rm -rf "$(dirname "$SET")"
echo "✓ Resources/AppIcon.icns"
