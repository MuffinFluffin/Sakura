#!/bin/sh
set -e
CPP_DIR="$1"
if [ -z "${BUILT_PRODUCTS_DIR:-}" ] || [ -z "${FULL_PRODUCT_NAME:-}" ]; then
	echo "compile_sakura_presentation_metallib.sh: need BUILT_PRODUCTS_DIR + FULL_PRODUCT_NAME (Xcode build env)" >&2
	exit 1
fi
APP_DIR="$BUILT_PRODUCTS_DIR/$FULL_PRODUCT_NAME"
SRC_PRES="$CPP_DIR/SakuraPresentation.metal"
SRC_NEU="$CPP_DIR/SakuraNeuralComposite.metal"
SRC_SMAA="$CPP_DIR/SakuraSMAA.metal"
AIR_P="${TMPDIR:-/tmp}/sak_pres_${$}_presentation.air"
AIR_N="${TMPDIR:-/tmp}/sak_pres_${$}_neural.air"
AIR_S="${TMPDIR:-/tmp}/sak_pres_${$}_smaa.air"
METALLIB="$APP_DIR/SakuraPresentation.metallib"
if [ ! -f "$SRC_PRES" ] || [ ! -f "$SRC_NEU" ] || [ ! -f "$SRC_SMAA" ]; then
	echo "compile_sakura_presentation_metallib.sh: missing $SRC_PRES / $SRC_NEU / $SRC_SMAA" >&2
	exit 1
fi
mkdir -p "$APP_DIR"
rm -f "$AIR_P" "$AIR_N" "$AIR_S"
XCRUN_SDK=""
case "${PLATFORM_NAME:-}" in
iphoneos) XCRUN_SDK=iphoneos ;;
iphonesimulator) XCRUN_SDK=iphonesimulator ;;
esac
if [ -n "$XCRUN_SDK" ]; then
	xcrun --sdk "$XCRUN_SDK" metal -I"$CPP_DIR" -c "$SRC_PRES" -o "$AIR_P"
	xcrun --sdk "$XCRUN_SDK" metal -I"$CPP_DIR" -c "$SRC_NEU" -o "$AIR_N"
	xcrun --sdk "$XCRUN_SDK" metal -I"$CPP_DIR" -c "$SRC_SMAA" -o "$AIR_S"
else
	xcrun metal -I"$CPP_DIR" -c "$SRC_PRES" -o "$AIR_P"
	xcrun metal -I"$CPP_DIR" -c "$SRC_NEU" -o "$AIR_N"
	xcrun metal -I"$CPP_DIR" -c "$SRC_SMAA" -o "$AIR_S"
fi
xcrun metallib "$AIR_P" "$AIR_N" "$AIR_S" -o "$METALLIB"
rm -f "$AIR_P" "$AIR_N" "$AIR_S"
L10N_SRC="$CPP_DIR/../swift/Resources/SakuraL10n"
exec /bin/sh "$CPP_DIR/copy_sakura_l10n.sh" "$L10N_SRC"
