#!/usr/bin/env bash
# Sends a signed Mac app or disk image to Apple for notarisation, waits,
# and staples the ticket to it so that it opens without a connection too.
#
#   tool/notarise_mac.sh <UWMedia.app | UWMedia.dmg>
#
# Needs APPLE_ID, APPLE_TEAM_ID and APPLE_APP_SPECIFIC_PASSWORD in the
# environment (the Release Build workflow's secrets). An app is sent as a
# zip, the form Apple takes; the zip is not kept.
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "usage: tool/notarise_mac.sh <app or dmg>" >&2
  exit 2
fi
target=$1
for name in APPLE_ID APPLE_TEAM_ID APPLE_APP_SPECIFIC_PASSWORD; do
  if [ -z "${!name:-}" ]; then
    echo "$name is not set" >&2
    exit 1
  fi
done

work=$(mktemp -d "${TMPDIR:-/tmp}/uwmedia_notarise.XXXXXX")
trap 'rm -rf "$work"' EXIT
result="$work/result.json"
credentials=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD")

case "$target" in
  *.app)
    upload="$work/notarise.zip"
    ditto -c -k --sequesterRsrc --keepParent "$target" "$upload"
    ;;
  *.dmg)
    upload=$target
    ;;
  *)
    echo "Neither an app nor a disk image: $target" >&2
    exit 1
    ;;
esac

# notarytool can end with 0 for a refused file: the status decides
xcrun notarytool submit "$upload" "${credentials[@]}" --wait --timeout 45m \
  --output-format json > "$result" || true
cat "$result"; echo
id=$(plutil -extract id raw -o - "$result" 2>/dev/null || true)
status=$(plutil -extract status raw -o - "$result" 2>/dev/null || true)
if [ "$status" != "Accepted" ]; then
  if [ -n "$id" ]; then
    xcrun notarytool log "$id" "${credentials[@]}" || true
  fi
  echo "::error::Apple did not notarise $(basename "$target") (status: ${status:-none}); its log is above."
  exit 1
fi

xcrun stapler staple "$target"
xcrun stapler validate "$target"
case "$target" in
  *.app) spctl --assess --type execute -vv "$target" ;;
  *.dmg) spctl --assess --type open --context context:primary-signature -vv "$target" ;;
esac
