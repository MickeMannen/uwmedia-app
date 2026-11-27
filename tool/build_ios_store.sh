#!/bin/bash
# Builds the iPhone app for the App Store and TestFlight, signs it by hand
# and, with --upload, sends it to App Store Connect.
#
# Signed by hand, as the Mac's store build is (tool/build_store.sh): from
# a command Xcode has no account to sign with, and an App Store Connect
# API key may not use Apple's cloud-managed certificates (2026-11-27). So
# the app is built unsigned, and signed here with the Apple Distribution
# certificate in the keychain and an App Store provisioning profile.
#
# From the environment or tool/local.env (git-ignored):
#   UWMEDIA_SIGN_IDENTITY  "Apple Distribution: Name (TEAMID)"
#   UWMEDIA_IOS_PROFILE    the iOS App Store provisioning profile (a file)
#   ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_FILE   for --upload, as build_store.sh
# Every option but --upload goes to flutter build. With no --build-number
# the build number is the time (yymmddhhmm).
# The result is build/ios_store/UWMedia.ipa.
set -euo pipefail
cd "$(dirname "$0")/.."

upload=false
numbered=false
args=()
for arg in "$@"; do
    case "$arg" in
        --upload) upload=true ;;
        --build-number | --build-number=*) numbered=true; args+=("$arg") ;;
        *) args+=("$arg") ;;
    esac
done
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
needed=(UWMEDIA_SIGN_IDENTITY UWMEDIA_IOS_PROFILE)
if $upload; then
    needed+=(ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_FILE)
fi
for name in "${needed[@]}"; do
    if [ -z "${!name:-}" ]; then
        echo "$name is needed, in the environment or in tool/local.env." >&2
        exit 1
    fi
done
if ! $numbered; then
    args+=(--build-number "$(date +%y%m%d%H%M)")
fi

flutter build ios --release --no-codesign ${args[@]+"${args[@]}"}

out=build/ios_store
rm -rf "$out"
mkdir -p "$out/Payload"
cp -R build/ios/iphoneos/Runner.app "$out/Payload/"
app="$out/Payload/Runner.app"

# The profile inside the app, and the entitlements it gives: what the
# signature must say (the app asks for none of its own).
cp "$UWMEDIA_IOS_PROFILE" "$app/embedded.mobileprovision"
security cms -D -i "$UWMEDIA_IOS_PROFILE" >"$out/profile.plist"
/usr/libexec/PlistBuddy -x -c "Print :Entitlements" "$out/profile.plist" >"$out/entitlements.plist"
# No quarantine mark from a downloaded profile (the Mac's error 91109).
xattr -cr "$app"

find "$app/Frameworks" -depth \( -name '*.framework' -o -name '*.dylib' \) -print0 |
    while IFS= read -r -d '' item; do
        codesign --force --sign "$UWMEDIA_SIGN_IDENTITY" "$item"
    done
codesign --force --sign "$UWMEDIA_SIGN_IDENTITY" \
    --entitlements "$out/entitlements.plist" "$app"
codesign --verify --deep --strict "$app"
echo "Signed $app ($UWMEDIA_SIGN_IDENTITY)"

(cd "$out" && zip -qry UWMedia.ipa Payload)
echo "Packaged $out/UWMedia.ipa"

if $upload; then
    version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Info.plist")
    build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$app/Info.plist")
    # altool looks for AuthKey_<key id>.p8 in this folder.
    API_PRIVATE_KEYS_DIR="$(cd "$(dirname "$ASC_KEY_FILE")" && pwd)"
    export API_PRIVATE_KEYS_DIR
    echo "Uploading $version ($build) to App Store Connect…"
    xcrun altool --upload-app --type ios --file "$out/UWMedia.ipa" \
        --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
    echo "Uploaded $version ($build). Apple processes it before it is in TestFlight."
fi
