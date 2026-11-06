#!/bin/bash
# Builds QuickChat.app into dist/. SwiftPM produces the binary; this script wraps it
# in an app bundle (LSUIElement menu bar app) and signs it.
#
# Signing identity comes from POPCHAT_SIGN_IDENTITY; the default "-" is ad-hoc, which
# is right for local iteration. release.sh sets it to the Developer ID and that branch
# additionally enables the hardened runtime + a secure timestamp, both of which
# notarization refuses to proceed without.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
SIGN_ID="${POPCHAT_SIGN_IDENTITY:--}"
# SwiftPM's generated Bundle.module accessors embed the build-products directory's
# ABSOLUTE PATH as a string literal in the binary (a dev-time fallback lookup), so a
# build made here ships "/Users/<name>/..." inside the executable. release.sh points
# POPCHAT_SCRATCH at a neutral path so the published DMG carries no home directory.
SCRATCH="${POPCHAT_SCRATCH:-.build}"

# SDK: Command Line Tools 27.0 (beta, September 2026) made its default SDK's SwiftUI
# declare @State and friends as MACROS whose plugin (libSwiftUIMacros) ships only
# inside Xcode, so under the CLT every SwiftUI file fails with "plugin for module
# 'SwiftUIMacros' not found". Until a CLT carries the plugin, build against the
# newest installed SDK that predates it. POPCHAT_SDK overrides; empty = toolchain default.
SDK="${POPCHAT_SDK-}"
if [ -z "${POPCHAT_SDK+x}" ]; then
    TOOLCHAIN_PLUGINS="$(dirname "$(xcrun --find swift)")/../lib/swift/host/plugins"
    SDK_DIR="$(dirname "$(xcrun --show-sdk-path)")"
    if [ ! -e "$TOOLCHAIN_PLUGINS/libSwiftUIMacros.dylib" ] \
        && [ "$(xcrun --show-sdk-version | cut -d. -f1)" -ge 27 ] \
        && [ -d "$SDK_DIR/MacOSX26.sdk" ]; then
        SDK="$SDK_DIR/MacOSX26.sdk"
        echo "note: building against $(basename "$(readlink "$SDK" || echo "$SDK")") — the toolchain's default SDK needs Xcode's SwiftUI macro plugin"
    fi
fi

# --build-system native, explicitly: swift-build's newer default backend lays products
# out differently (.build/out/Products/<Config>) and generates a different Bundle.module
# accessor; the paths below and Sources/QuickChatBundleShim are written against native.
swift build -c "$CONFIG" --scratch-path "$SCRATCH" --build-system native ${SDK:+--sdk "$SDK"}

BIN="$SCRATCH/$CONFIG/QuickChat"
APP="dist/QuickChat.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/QuickChat"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # CFBundleIconFile

# SPM dependency resource bundles (KeyboardShortcuts localizations, SwiftMath's math
# fonts) must ship inside the app for Bundle.module lookup to succeed — without them
# SwiftMath traps the first time a message contains LaTeX.
# -L is load-bearing: .build/<config> is a symlink to .build/<triple>/<config>, and
# plain find will not descend into it, so this silently copied nothing.
find -L "$SCRATCH/$CONFIG" -maxdepth 1 -name "*.bundle" -exec cp -R {} "$APP/Contents/Resources/" \;

# Counted, not "is Resources empty" — the icon lives there too and would mask a miss.
if [ "$(find "$APP/Contents/Resources" -maxdepth 1 -name "*.bundle" | wc -l)" -eq 0 ]; then
    echo "error: no resource bundles were copied — LaTeX rendering would crash at runtime" >&2
    exit 1
fi

if [ "$SIGN_ID" = "-" ]; then
    codesign --force --sign - "$APP"
    echo "Built $APP (ad-hoc signed)"
else
    # The nested *.bundle payloads are resource-only (localizations, math fonts, a
    # privacy manifest) — no Mach-O inside, so the app's own signature seals them and
    # signing them individually just fails on the ones lacking an Info.plist.
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
    codesign --verify --strict --deep --verbose=2 "$APP"
    echo "Built $APP (signed: $SIGN_ID)"
fi
# From INSIDE the assembled app, because that is the only place the check means
# anything: the dependencies' Bundle.module accessors never look in Contents/Resources
# (see Sources/QuickChatBundleShim), and a copy that ran fine from .build/ shipped a
# DMG that crashed on the first hotkey recorder or LaTeX message everywhere else.
"$APP/Contents/MacOS/QuickChat" --smoke-bundles
echo "Run with: open $APP"
