#!/bin/sh
set -e
STAGED_DYLIB="$1"
MIN_OS="${2:-17.0}"
if [ -z "$STAGED_DYLIB" ] || [ ! -f "$STAGED_DYLIB" ]; then
	echo "bundle_libretro_psx_framework.sh: missing staged dylib (arg1)" >&2
	exit 1
fi
if [ -z "${BUILT_PRODUCTS_DIR:-}" ] || [ -z "${FULL_PRODUCT_NAME:-}" ]; then
	echo "bundle_libretro_psx_framework.sh: need BUILT_PRODUCTS_DIR + FULL_PRODUCT_NAME" >&2
	exit 1
fi
APP="$BUILT_PRODUCTS_DIR/$FULL_PRODUCT_NAME"
FWK="$APP/Frameworks/MednafenPSX.framework"
mkdir -p "$APP/Frameworks"
rm -f "$APP/Frameworks/mednafen_psx_libretro_ios.dylib"
rm -rf "$FWK"
mkdir -p "$FWK"
cp "$STAGED_DYLIB" "$FWK/MednafenPSX"
chmod 755 "$FWK/MednafenPSX"

cat > "$FWK/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>MednafenPSX</string>
	<key>CFBundleIdentifier</key>
	<string>com.sakura.psx.MednafenPSX</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>MednafenPSX</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>MinimumOSVersion</key>
	<string>${MIN_OS}</string>
</dict>
</plist>
EOF

SIG="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:--}}"
if [ -n "$SIG" ] && [ "$SIG" != "-" ]; then
	codesign --force --sign "$SIG" --timestamp=none "$FWK/MednafenPSX"
	codesign --force --sign "$SIG" --timestamp=none "$FWK"
else
	codesign --force --sign - --timestamp=none "$FWK/MednafenPSX"
	codesign --force --sign - --timestamp=none "$FWK"
fi
