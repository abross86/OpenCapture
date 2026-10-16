#!/bin/bash
# OpenCapture build script — uses swiftc directly, so no Xcode project is needed
# (same setup as OpenScanX / CheckScanX / HL7Viewer on this machine).
#
#   ./build.sh                 build the .app bundle into build/
#   ./build.sh --run           build, then launch the app
#   ./build.sh --install       build, then copy the app to /Applications
#   ./build.sh --debug         build without optimisation (faster compile, -g)
#   NOTARIZE=1 ./build.sh      build, sign, submit to Apple notary service, staple the ticket,
#                              and write build/OpenCapture.zip ready to distribute
#
# Env overrides:
#   OPENCAPTURE_MIN_MACOS  deployment target (default 14.0)
#   SIGN_IDENTITY          codesign identity; defaults to a Developer ID if one
#                          is installed, else ad-hoc ("-").
#   NOTARY_PROFILE         notarytool keychain profile name (default "OpenCapture").
#                          Create it once with:
#                            xcrun notarytool store-credentials "OpenCapture" \
#                                --apple-id you@example.com --team-id 66S479XTRP
#                          (it asks for an app-specific password from appleid.apple.com)
#
# NOTE on signing: camera/microphone access is a TCC grant keyed on the code
# signature. Ad-hoc signatures change with every build, which makes macOS forget
# the grant (and can leave the app silently without video). A stable Developer
# ID signature keeps the grant across rebuilds.
set -euo pipefail
cd "$(dirname "$0")"

RUN=false; INSTALL=false; DEBUG=false
for arg in "$@"; do
    case "$arg" in
        --run)     RUN=true ;;
        --install) INSTALL=true ;;
        --debug)   DEBUG=true ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

OUT="build"
APP="$OUT/OpenCapture.app"
DEPLOY_MIN="${OPENCAPTURE_MIN_MACOS:-14.0}"
ARCHS="${OPENCAPTURE_ARCHS:-arm64 x86_64}"   # universal by default; set OPENCAPTURE_ARCHS=arm64 for a quick local build
BUNDLE_ID="org.opencapture.app"
VERSION="$(cat VERSION 2>/dev/null || echo 0.1.0)"

if [ -n "${SIGN_IDENTITY:-}" ]; then
    IDENTITY="$SIGN_IDENTITY"
else
    DEV_ID=$(security find-identity -v -p codesigning 2>/dev/null \
             | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')
    if [ -n "$DEV_ID" ]; then IDENTITY="$DEV_ID"; echo "==> Using Developer ID: $IDENTITY"
    else IDENTITY="-"; echo "==> No Developer ID found; ad-hoc signing"; fi
fi

mkdir -p "$OUT"
if $DEBUG; then OPT=(-Onone -g); ARCHS="$(uname -m)"; else OPT=(-O); fi
COMMON_FLAGS=("${OPT[@]}" -swift-version 5 -module-name OpenCapture)
FRAMEWORKS=(-framework AppKit -framework SwiftUI -framework Combine -framework AVFoundation
            -framework CoreImage -framework CoreMedia -framework CoreVideo -framework Metal
            -framework MetalKit -framework Accelerate -framework UniformTypeIdentifiers
            -framework CoreText -framework AudioToolbox -framework CoreAudio)

echo "==> Building OpenCapture.app (${ARCHS}, macOS ${DEPLOY_MIN}+, v${VERSION})"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

SLICES=()
for arch in $ARCHS; do
    echo "    compiling $arch"
    # Small Objective-C helper (exception catcher) compiled with clang and linked into the Swift binary.
    clang -c -O2 -fobjc-arc -arch "$arch" -mmacosx-version-min="$DEPLOY_MIN" \
        Sources/ObjC/ExceptionCatcher.m -o "$OUT/ExceptionCatcher-$arch.o"
    swiftc "${COMMON_FLAGS[@]}" -target "${arch}-apple-macos${DEPLOY_MIN}" \
        -import-objc-header Sources/ObjC/ExceptionCatcher.h \
        Sources/*/*.swift "$OUT/ExceptionCatcher-$arch.o" "${FRAMEWORKS[@]}" -o "$OUT/OpenCapture-$arch"
    SLICES+=("$OUT/OpenCapture-$arch")
    rm -f "$OUT/ExceptionCatcher-$arch.o"
done
lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/OpenCapture"
rm -f "${SLICES[@]}"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>OpenCapture</string>
    <key>CFBundleDisplayName</key><string>OpenCapture</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>OpenCapture</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
    <key>LSMinimumSystemVersion</key><string>${DEPLOY_MIN}</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
    <key>NSHumanReadableCopyright</key><string>OpenCapture — open source, MIT licensed</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
    <key>NSCameraUsageDescription</key><string>OpenCapture needs camera access to show and record video from your capture card or camera.</string>
    <key>NSMicrophoneUsageDescription</key><string>OpenCapture needs microphone access to monitor and record audio from your capture card or audio input.</string>
    <key>NSAppleScriptEnabled</key><true/>
    <key>OSAScriptingDefinition</key><string>OpenCapture.sdef</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp Resources/OpenCapture.sdef "$APP/Contents/Resources/"
[ -d Resources/manual ] && cp -R Resources/manual "$APP/Contents/Resources/manual"

# App icon: rendered programmatically by Tools/makeicon.swift the first time.
if [ ! -f Resources/icon.png ] || [ Tools/makeicon.swift -nt Resources/icon.png ]; then
    echo "==> Rendering Resources/icon.png"
    swiftc -O -framework AppKit Tools/makeicon.swift -o "$OUT/makeicon" && "$OUT/makeicon" Resources/icon.png
fi
if [ -f Resources/icon.png ]; then
    echo "==> Building AppIcon.icns"
    ICONSET="$OUT/AppIcon.iconset"; rm -rf "$ICONSET"; mkdir -p "$ICONSET"
    for spec in "16:icon_16x16" "32:icon_16x16@2x" "32:icon_32x32" "64:icon_32x32@2x" \
                "128:icon_128x128" "256:icon_128x128@2x" "256:icon_256x256" \
                "512:icon_256x256@2x" "512:icon_512x512" "1024:icon_512x512@2x"; do
        size="${spec%%:*}"; name="${spec##*:}"
        sips -s format png -z "$size" "$size" Resources/icon.png --out "$ICONSET/$name.png" >/dev/null 2>&1
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null \
      && echo "    AppIcon.icns written" || echo "    WARNING: iconutil failed"
    rm -rf "$ICONSET"
fi

echo "==> Signing ($IDENTITY)"
ENT="Resources/OpenCapture.entitlements"
if [ "$IDENTITY" = "-" ]; then
    codesign --force --sign "-" --entitlements "$ENT" --identifier "$BUNDLE_ID" "$APP"
else
    # Hardened runtime + secure timestamp are both required by the notary service.
    codesign --force --sign "$IDENTITY" --timestamp --options runtime \
        --entitlements "$ENT" --identifier "$BUNDLE_ID" "$APP"
fi
codesign --verify --strict --deep "$APP" && echo "    signature verified"

echo "==> Built $APP"

if [ -n "${NOTARIZE:-}" ]; then
    if [ "$IDENTITY" = "-" ]; then echo "ERROR: notarization needs a Developer ID signature"; exit 1; fi
    PROFILE="${NOTARY_PROFILE:-OpenCapture}"
    ZIP="$OUT/OpenCapture.zip"
    echo "==> Notarizing with keychain profile '$PROFILE'"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
    echo "==> Stapling ticket"
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    spctl --assess --type execute -vv "$APP"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "==> Notarized app zipped to $ZIP"
fi

if $INSTALL; then
    echo "==> Installing to /Applications/OpenCapture.app"
    rm -rf /Applications/OpenCapture.app
    cp -R "$APP" /Applications/OpenCapture.app
fi
if $RUN; then
    open "$APP"
fi
