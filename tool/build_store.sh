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
#
# Two options of this script's own (every other one goes to flutter build):
#   --store   sign for the store with the variables above read from
#             tool/local.env (git-ignored), where the environment has none
#   --upload  --store, then send the package to App Store Connect. It needs
#             ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_FILE (the AuthKey_….p8
#             of an App Store Connect API key), in the environment or in
#             tool/local.env.
# With --store or --upload and no --build-number, the build number is the
# time (yymmddhhmm): the store takes each number of a version once, and
# only a higher one than the last.
set -euo pipefail
cd "$(dirname "$0")/.."

store=false
upload=false
numbered=false
args=()
for arg in "$@"; do
    case "$arg" in
        --store) store=true ;;
        --upload) store=true; upload=true ;;
        --build-number | --build-number=*) numbered=true; args+=("$arg") ;;
        *) args+=("$arg") ;;
    esac
done
if $store; then
    if [ -f tool/local.env ]; then
        # What the environment says wins over the file.
        while IFS='=' read -r name value; do
            case "$name" in
                UWMEDIA_* | ASC_*)
                    if [ -z "${!name:-}" ]; then
                        value="${value%\"}"
                        export "$name=${value#\"}"
                    fi
                    ;;
            esac
        done <tool/local.env
    fi
    for name in UWMEDIA_SIGN_IDENTITY UWMEDIA_TEAM_ID UWMEDIA_PROFILE UWMEDIA_INSTALLER_IDENTITY; do
        if [ -z "${!name:-}" ]; then
            echo "--store needs $name, in the environment or in tool/local.env." >&2
            exit 1
        fi
    done
    if $upload; then
        for name in ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_FILE; do
            if [ -z "${!name:-}" ]; then
                echo "--upload needs $name, in the environment or in tool/local.env." >&2
                exit 1
            fi
        done
        if [ ! -f "$ASC_KEY_FILE" ]; then
            echo "--upload: no key file at $ASC_KEY_FILE." >&2
            exit 1
        fi
    fi
    if ! $numbered; then
        args+=(--build-number "$(date +%y%m%d%H%M)")
    fi
fi

identity="${UWMEDIA_SIGN_IDENTITY:--}"
bundle_id="${UWMEDIA_BUNDLE_ID:-$(sed -n 's/^PRODUCT_BUNDLE_IDENTIFIER *= *//p' macos/Runner/Configs/AppInfo.xcconfig)}"

flutter build macos --release --dart-define=UWMEDIA_STORE=true ${args[@]+"${args[@]}"}

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
# A profile downloaded with a browser carries the quarantine mark, and cp
# keeps it; the store refuses a package with one inside (error 91109,
# 2026-11-27).
xattr -cr "$app"
# The store asks what encryption the app has: none of its own.
/usr/libexec/PlistBuddy -c "Add :ITSAppUsesNonExemptEncryption bool false" \
    "$app/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :LSApplicationCategoryType string public.app-category.video" \
    "$app/Contents/Info.plist" 2>/dev/null || true

# The code inside first, each with the same identity, then the app with
# the sandbox's entitlements.
# The hardened runtime only with a real identity: with an ad hoc signature
# it refuses the app's own frameworks at the start ("different Team IDs",
# as an ad hoc signature has no team; seen 2026-11-25).
runtime=(--options runtime)
if [ "$identity" = "-" ]; then
    runtime=()
fi
find "$app/Contents/Frameworks" -depth \( -name '*.framework' -o -name '*.dylib' \) -print0 |
    while IFS= read -r -d '' item; do
        codesign --force --sign "$identity" ${runtime[@]+"${runtime[@]}"} "$item"
    done
codesign --force --sign "$identity" ${runtime[@]+"${runtime[@]}"} \
    --entitlements "$entitlements" "$app"
codesign --verify --deep --strict "$app"
echo "Signed $app ($identity)"

if [ -n "${UWMEDIA_INSTALLER_IDENTITY:-}" ]; then
    productbuild --component "$app" /Applications \
        --sign "$UWMEDIA_INSTALLER_IDENTITY" "$out/UWMedia.pkg"
    echo "Packaged $out/UWMedia.pkg"
fi

if $upload; then
    version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")
    build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$app/Contents/Info.plist")
    # altool looks for AuthKey_<key id>.p8 in this folder.
    API_PRIVATE_KEYS_DIR="$(cd "$(dirname "$ASC_KEY_FILE")" && pwd)"
    export API_PRIVATE_KEYS_DIR
    echo "Uploading $version ($build) to App Store Connect…"
    xcrun altool --upload-app --type macos --file "$out/UWMedia.pkg" \
        --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
    echo "Uploaded $version ($build). Apple processes it before it is in TestFlight."
fi
