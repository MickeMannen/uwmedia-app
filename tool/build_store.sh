#!/bin/bash
# Builds the Mac App Store variant of the app (spec §10.74,
# docs/design/macos-remove-ffmpeg.md step 7): no ffmpeg and no exiftool
# (--dart-define=UWMEDIA_STORE=true), signed for the App Sandbox with
# macos/Runner/Store.entitlements.
#
# With nothing set the app is signed ad hoc, to try the sandbox on this
# Mac. For the store, set:
#   UWMEDIA_SIGN_IDENTITY       "Apple Distribution: Name (TEAMID)"
#   UWMEDIA_TEAM_ID             the team id
#   UWMEDIA_PROFILE             the Mac App Store provisioning profile (a file)
#   UWMEDIA_INSTALLER_IDENTITY  "3rd Party Mac Developer Installer: Name (TEAMID)"
# and the result is build/store/UWMedia.pkg, ready to upload.
# UWMEDIA_BUNDLE_ID overrides the bundle id of macos/Runner/Configs/AppInfo.xcconfig.
set -euo pipefail
cd "$(dirname "$0")/.."

identity="${UWMEDIA_SIGN_IDENTITY:--}"
bundle_id="${UWMEDIA_BUNDLE_ID:-$(sed -n 's/^PRODUCT_BUNDLE_IDENTIFIER *= *//p' macos/Runner/Configs/AppInfo.xcconfig)}"

flutter build macos --release --dart-define=UWMEDIA_STORE=true "$@"

app=$(ls -d build/macos/Build/Products/Release/*.app | head -1)
out=build/store
rm -rf "$out"
mkdir -p "$out"
cp -R "$app" "$out/"
app="$out/$(basename "$app")"

entitlements="$out/Store.entitlements"
cp macos/Runner/Store.entitlements "$entitlements"
if [ -n "${UWMEDIA_BUNDLE_ID:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$app/Contents/Info.plist"
fi
if [ -n "${UWMEDIA_TEAM_ID:-}" ]; then
    # What the store's signature must say of the app.
    /usr/libexec/PlistBuddy \
        -c "Add :com.apple.application-identifier string $UWMEDIA_TEAM_ID.$bundle_id" \
        -c "Add :com.apple.developer.team-identifier string $UWMEDIA_TEAM_ID" \
        "$entitlements"
fi
if [ -n "${UWMEDIA_PROFILE:-}" ]; then
    cp "$UWMEDIA_PROFILE" "$app/Contents/embedded.provisionprofile"
fi
# The store asks what encryption the app has: none of its own.
/usr/libexec/PlistBuddy -c "Add :ITSAppUsesNonExemptEncryption bool false" \
    "$app/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :LSApplicationCategoryType string public.app-category.video" \
    "$app/Contents/Info.plist" 2>/dev/null || true

# The code inside first, each with the same identity, then the app with
# the sandbox's entitlements.
find "$app/Contents/Frameworks" -depth \( -name '*.framework' -o -name '*.dylib' \) -print0 |
    while IFS= read -r -d '' item; do
        codesign --force --sign "$identity" --options runtime "$item"
    done
codesign --force --sign "$identity" --options runtime \
    --entitlements "$entitlements" "$app"
codesign --verify --deep --strict "$app"
echo "Signed $app ($identity)"

if [ -n "${UWMEDIA_INSTALLER_IDENTITY:-}" ]; then
    productbuild --component "$app" /Applications \
        --sign "$UWMEDIA_INSTALLER_IDENTITY" "$out/UWMedia.pkg"
    echo "Packaged $out/UWMedia.pkg"
fi
