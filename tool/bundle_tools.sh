#!/bin/bash
# Puts ffmpeg, ffprobe and exiftool into a built desktop app, where the
# app looks for them first (spec §13.2): run after `flutter build <system>
# --release`. The files are fetched and checked by tool/fetch_tools.dart.
#
#   tool/bundle_tools.sh [macos|windows|linux]     (default: this system)
#
# On macOS the app is signed again afterwards, ad hoc unless
# UWMEDIA_SIGN_IDENTITY names an identity: files added to a signed bundle
# break its seal. The Mac App Store build (tool/build_store.sh) takes no
# tools.
set -euo pipefail
cd "$(dirname "$0")/.."

system="${1:-}"
if [ -z "$system" ]; then
  case "$(uname -s)" in
    Darwin) system=macos ;;
    Linux) system=linux ;;
    *) system=windows ;;
  esac
fi

case "$system" in
  macos)
    app=$(ls -d build/macos/Build/Products/Release/*.app 2>/dev/null | head -1)
    [ -n "$app" ] || { echo "No built app: run flutter build macos --release first" >&2; exit 1; }
    bin="$app/Contents/Resources/bin"
    ;;
  windows) bin="build/windows/x64/runner/Release/bin" ;;
  linux) bin="build/linux/x64/release/bundle/bin" ;;
  *) echo "usage: tool/bundle_tools.sh [macos|windows|linux]" >&2; exit 64 ;;
esac
if [ "$system" != macos ] && [ ! -d "$(dirname "$bin")" ]; then
  echo "No built app: run flutter build $system --release first" >&2
  exit 1
fi

dart run tool/fetch_tools.dart "$system" "$bin"

if [ "$system" = macos ]; then
  identity="${UWMEDIA_SIGN_IDENTITY:--}"
  # The tools first (each a program of its own), then the bundle around
  # them.
  for tool in ffmpeg ffprobe; do
    if [ "$identity" = "-" ]; then
      codesign --force --sign - "$bin/$tool"
    else
      codesign --force --options runtime --timestamp --sign "$identity" "$bin/$tool"
    fi
  done
  if [ "$identity" = "-" ]; then
    codesign --force --deep --sign - "$app"
  else
    codesign --force --deep --options runtime --timestamp --sign "$identity" "$app"
  fi
  codesign --verify --deep --strict "$app"
fi
echo "Tools bundled in $bin"
