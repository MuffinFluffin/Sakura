#!/bin/sh
set -e
SRC="$1"
if [ -z "${BUILT_PRODUCTS_DIR:-}" ] || [ -z "${FULL_PRODUCT_NAME:-}" ]; then
	echo "copy_sakura_l10n.sh: need BUILT_PRODUCTS_DIR + FULL_PRODUCT_NAME (Xcode build env)" >&2
	exit 1
fi
if [ ! -d "$SRC" ]; then
	echo "copy_sakura_l10n.sh: missing directory $SRC" >&2
	exit 1
fi
APP_DIR="${BUILT_PRODUCTS_DIR}/${FULL_PRODUCT_NAME}"
DST="${APP_DIR}/SakuraL10n"
rm -rf "${DST}"
mkdir -p "${DST}"
cp -R "${SRC}/." "${DST}/"
