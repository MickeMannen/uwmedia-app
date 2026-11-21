#!/bin/bash
# Puts ffmpeg, ffprobe and exiftool into a built desktop app, where the
# app looks for them first (spec §13.2): run after `flutter build <system>
# --release`. The files are fetched and checked by tool/fetch_tools.dart.
#
#   tool/bundle_tools.sh [macos|windows|linux]     (default: this system)
#
# On macOS the app is signed again afterwards, ad hoc unless
# UWMEDIA_SIGN_IDENTITY names a Developer ID identity (its name or its
# hash; then with the hardened runtime and macos/Runner/Release.entitlements,
# ready to notarise): files added to a signed bundle break its seal. The Mac App Store build (tool/build_store.sh) takes no
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
  if [ "$identity" = "-" ]; then
    # The tools first (each a program of its own), then the bundle around
    # them.
    for tool in ffmpeg ffprobe; do
      codesign --force --sign - "$bin/$tool"
    done
    codesign --force --deep --sign - "$app"
  else
    # A Developer ID, for notarising: every program in the bundle signed
    # by itself with the hardened runtime and a timestamp, from the inside
    # out (the tools, the frameworks, then the app), and only the app
    # given the entitlements. No --deep: it would hand the entitlements
    # to everything inside.
    sign() { codesign --force --options runtime --timestamp --sign "$identity" "$@"; }
    for tool in ffmpeg ffprobe; do
      sign "$bin/$tool"
    done
    find "$app/Contents/Frameworks" -depth \( -name '*.dylib' -o -name '*.framework' \) -print0 |
      while IFS= read -r -d '' item; do
        sign "$item"
      done
    sign --entitlements macos/Runner/Release.entitlements "$app"
  fi
  codesign --verify --deep --strict "$app"
fi
echo "Tools bundled in $bin"
