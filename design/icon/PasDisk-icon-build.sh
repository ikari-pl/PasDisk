#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h}"
NAME="PasDisk"
PACKAGING="${ROOT:h:h}/packaging"
[[ -d "$PACKAGING" ]] || { print -u2 'Repository packaging directory is missing'; exit 1; }
mkdir -p "$PACKAGING/${NAME}.iconset"
rsvg-convert -w 1024 -h 1024 "$ROOT/${NAME}.svg" -o "$ROOT/${NAME}.png"
for SIZE in 16 32 128 256 512; do
  MASTER="$ROOT/${NAME}.svg"
  if (( SIZE <= 32 )); then MASTER="$ROOT/${NAME}-small.svg"; fi
  rsvg-convert -w "$SIZE" -h "$SIZE" "$MASTER" -o "$PACKAGING/${NAME}.iconset/icon_${SIZE}x${SIZE}.png"
  DOUBLE=$((SIZE * 2))
  rsvg-convert -w "$DOUBLE" -h "$DOUBLE" "$MASTER" -o "$PACKAGING/${NAME}.iconset/icon_${SIZE}x${SIZE}@2x.png"
done
iconutil -c icns "$PACKAGING/${NAME}.iconset" -o "$PACKAGING/${NAME}.icns"
