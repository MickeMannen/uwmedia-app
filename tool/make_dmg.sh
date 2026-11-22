#!/usr/bin/env bash
# The Mac download: a disk image holding the app and a link to
# /Applications, so that opening it shows the app to drag there.
#
#   tool/make_dmg.sh <UWMedia.app> <out.dmg>
#
# The app is taken as it is (signed, notarised and stapled before this
# when it is a release). With UWMEDIA_SIGN_IDENTITY set (a Developer ID
# identity, as for tool/bundle_tools.sh) the image is signed too; it is
# then notarised by tool/notarise_mac.sh. Nothing is written beside the
# image but a temporary folder, removed at the end.
#
# hdiutil is what GitHub's macOS 15 runners have; newer systems warn that
# `diskutil image` replaces it, and still run it.
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "usage: tool/make_dmg.sh <UWMedia.app> <out.dmg>" >&2
  exit 2
fi
app=$1
out=$2
if [ ! -d "$app" ]; then
  echo "No app at $app" >&2
  exit 1
fi

name=$(basename "$app" .app)
stage=$(mktemp -d "${TMPDIR:-/tmp}/uwmedia_dmg.XXXXXX")
trap 'rm -rf "$stage"' EXIT

# ditto keeps the signature's extended attributes and the stapled ticket
ditto "$app" "$stage/$name.app"
ln -s /Applications "$stage/Applications"

mkdir -p "$(dirname "$out")"
rm -f "$out"
hdiutil create -volname "$name" -srcfolder "$stage" -fs HFS+ \
  -format UDZO -imagekey zlib-level=9 -ov "$out" >/dev/null

identity="${UWMEDIA_SIGN_IDENTITY:-}"
if [ -n "$identity" ] && [ "$identity" != "-" ]; then
  codesign --force --timestamp --sign "$identity" "$out"
  codesign --verify --strict "$out"
fi

hdiutil verify "$out" >/dev/null
ls -l "$out"
