#!/bin/sh
# Builds a Synology .spk for one architecture.
#
#   tools/build-spk.sh [arch] [version]
#
# arch:    x86_64 | armv8 | armv7   (default: x86_64)
# version: SPK version, "x.y.z-rev" (default: 0.1.0-0001)
#
# Env:
#   SYNOTERM_UI_STYLE  url | vue   (default: url)
#     url — documented `.url` registration; works on DSM 7.0/7.1/7.2 and opens
#           the app URL in a DSM-managed window. No SynoToken injection.
#     vue — DSM 7.2 desktop framework (`type: "app"` + <v-app-window>), which
#           does receive `?SynoToken=` on the wrapper script and can forward it.
#           Requires DSM 7.2+.
#
# Output: build/synoterm-<version>-<arch>.spk
set -eu

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

ARCH="${1:-x86_64}"
SPK_VERSION="${2:-0.1.0-0001}"

case "${ARCH}" in
  x86_64) ZIG_TARGET="x86_64-linux-musl" ;;
  armv8)  ZIG_TARGET="aarch64-linux-musl" ;;
  armv7)  ZIG_TARGET="arm-linux-musleabihf" ;;
  *)
    echo "unsupported arch: ${ARCH} (expected x86_64, armv8 or armv7)" >&2
    exit 2
    ;;
esac

UI_STYLE="${SYNOTERM_UI_STYLE:-url}"
case "${UI_STYLE}" in
  url|vue) ;;
  *) echo "SYNOTERM_UI_STYLE must be 'url' or 'vue', got '${UI_STYLE}'" >&2; exit 2 ;;
esac

MAINTAINER="${SYNOTERM_MAINTAINER:-synoterm}"
MAINTAINER_URL="${SYNOTERM_MAINTAINER_URL:-https://github.com/}"
DISTRIBUTOR="${SYNOTERM_DISTRIBUTOR:-synoterm}"
DISTRIBUTOR_URL="${SYNOTERM_DISTRIBUTOR_URL:-https://github.com/}"
SUPPORT_URL="${SYNOTERM_SUPPORT_URL:-https://github.com/}"

BUILD="${ROOT}/build"
STAGING="${BUILD}/spk-${ARCH}"
PAYLOAD="${STAGING}/payload"
OUT="${BUILD}/synoterm-${SPK_VERSION}-${ARCH}.spk"

echo "==> zig build (${ZIG_TARGET})"
zig build -Doptimize=ReleaseSmall -Dtarget="${ZIG_TARGET}"

echo "==> frontend bundle"
if [ ! -d frontend/node_modules ]; then
  (cd frontend && npm ci --omit=dev 2>/dev/null || npm install)
fi
(cd frontend && npm run build >/dev/null)

echo "==> staging"
rm -rf "${STAGING}"
mkdir -p "${PAYLOAD}/bin" "${PAYLOAD}/nginx" "${PAYLOAD}/ui/web" "${PAYLOAD}/ui/images"

cp "${ROOT}/zig-out/bin/synoterm" "${PAYLOAD}/bin/synoterm"
chmod 755 "${PAYLOAD}/bin/synoterm"

cp "${ROOT}/packaging/dsm7/nginx/synoterm.conf" "${PAYLOAD}/nginx/synoterm.conf"
cp "${ROOT}/packaging/dsm7/ui/config.${UI_STYLE}" "${PAYLOAD}/ui/config"
if [ "${UI_STYLE}" = "vue" ]; then
  cp "${ROOT}/packaging/dsm7/ui/Synoterm.js" "${PAYLOAD}/ui/Synoterm.js"
fi
cp "${ROOT}"/frontend/dist/* "${PAYLOAD}/ui/web/"
# The UI is served from /webman/3rdparty/synoterm/web/ while the WebSocket
# lives behind the nginx mount, so tell the bundle where that is.
printf 'window.SYNOTERM_CONFIG = { ws: "/synoterm/ws" };\n' > "${PAYLOAD}/ui/web/config.js"

python3 "${ROOT}/tools/make-icons.py" "${PAYLOAD}/ui/images" >/dev/null
python3 "${ROOT}/tools/make-icons.py" "${STAGING}/icons" >/dev/null
cp "${STAGING}/icons/icon_64.png" "${STAGING}/PACKAGE_ICON.PNG"
cp "${STAGING}/icons/icon_256.png" "${STAGING}/PACKAGE_ICON_256.PNG"
rm -rf "${STAGING}/icons"

cp -R "${ROOT}/packaging/dsm7/conf" "${STAGING}/conf"
cp -R "${ROOT}/packaging/dsm7/scripts" "${STAGING}/scripts"
chmod 755 "${STAGING}"/scripts/*

cp "${ROOT}/LICENSE" "${STAGING}/LICENSE" 2>/dev/null || true

# extractsize is reported by Package Center, in KiB.
EXTRACT_SIZE=$(du -sk "${PAYLOAD}" | awk '{print $1}')

echo "==> INFO"
sed \
  -e "s|@SPK_VERSION@|${SPK_VERSION}|g" \
  -e "s|@ARCH@|${ARCH}|g" \
  -e "s|@EXTRACT_SIZE@|${EXTRACT_SIZE}|g" \
  -e "s|@MAINTAINER@|${MAINTAINER}|g" \
  -e "s|@MAINTAINER_URL@|${MAINTAINER_URL}|g" \
  -e "s|@DISTRIBUTOR@|${DISTRIBUTOR}|g" \
  -e "s|@DISTRIBUTOR_URL@|${DISTRIBUTOR_URL}|g" \
  -e "s|@SUPPORT_URL@|${SUPPORT_URL}|g" \
  "${ROOT}/packaging/dsm7/INFO.template" > "${STAGING}/INFO"

echo "==> package.tgz"
( cd "${PAYLOAD}" && tar -czf "${STAGING}/package.tgz" --format=ustar --owner=0 --group=0 $(ls -A | sort) )

echo "==> ${OUT}"
( cd "${STAGING}" && tar -cf "${OUT}" --format=ustar --owner=0 --group=0 \
    INFO package.tgz scripts conf LICENSE PACKAGE_ICON.PNG PACKAGE_ICON_256.PNG )

echo "ui style: ${UI_STYLE}"
ls -lh "${OUT}"
