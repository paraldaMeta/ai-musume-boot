#!/bin/zsh
# Regenerate ./icons/*.icns from ../preview/assets — only needed after swapping
# a character image. build.sh uses the committed icons and does not need this.
#
#   ./make-icons.sh            all four
#   ./make-icons.sh kimi       one
#
# Needs ImageMagick (`brew install imagemagick`) plus the built-in sips and iconutil.
set -euo pipefail

HERE="${0:A:h}"
ASSETS="$HERE/../preview/assets"
ICONS="$HERE/icons"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

command -v magick >/dev/null || { echo "error: ImageMagick not found (brew install imagemagick)" >&2; exit 1; }

# key | where the face is, as x%,y% of the picture
FOCUS=(
  "claude|48,12"
  "codex|47,11"
  "kimi|45,14"
  "workbuddy|45,16"
)

for row in "${FOCUS[@]}"; do
  IFS='|' read -r key focus <<< "$row"
  if (( $# > 0 )) && [[ " $* " != *" $key "* ]]; then continue; fi

  src="$ASSETS/$key.jpg"
  w=$(sips -g pixelWidth "$src" | awk '/pixelWidth/{print $2}')
  h=$(sips -g pixelHeight "$src" | awk '/pixelHeight/{print $2}')
  fx=${focus%,*}; fy=${focus#*,}
  side=$(( h * 55 / 100 ))
  x=$(( w * fx / 100 - side / 2 )); (( x < 0 )) && x=0
  y=$(( h * fy / 100 - side / 4 )); (( y < 0 )) && y=0

  # Rounded square. `-alpha off` must come after the mask so it applies to both
  # images; before it, CopyOpacity throws the photo's colour away.
  magick "$src" -crop "${side}x${side}+${x}+${y}" +repage -resize 824x824 \
    \( -size 824x824 xc:black -fill white -draw "roundrectangle 0,0,823,823,186,186" \) \
    -alpha off -compose CopyOpacity -composite \
    -compose Over -background none -gravity center -extent 1024x1024 "$WORK/$key-1024.png"

  set="$WORK/$key.iconset"
  mkdir -p "$set"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$WORK/$key-1024.png" --out "$set/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$WORK/$key-1024.png" --out "$set/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$set" -o "$ICONS/$key.icns"
  echo "wrote icons/$key.icns"
done
