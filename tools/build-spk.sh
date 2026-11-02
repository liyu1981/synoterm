#!/bin/sh
# Builds a Synology .spk for one architecture.
#
#   tools/build-spk.sh [arch] [version]
#
# arch:    x86_64 | armv8 | armv7   (default: x86_64)
# version: SPK version, "x.y.z-rev" (default: 0.1.1-0001)
#
# Env:
#   SYNOTERM_OS_MIN_VER  override os_min_ver (default: 7.1-42661)
#     e.g. SYNOTERM_OS_MIN_VER=7.1-42218 for a NAS on an older 7.1 build
#   SYNOTERM_NGINX_MOUNT  0 | 1  (default: 0)
#     1 — ship conf/resource + the nginx snippet so DSM itself mounts
#         /synoterm/ (same-origin, no extra port). This uses an *internal
#         worker*, which DSM 7 only allows for Synology-signed packages, so it
#         is off by default: a self-built package is refused with
#         "non-synology-signed package should not use internal worker".
#     0 — no privileged resource at all: DSM serves the UI from ui/web and the
#         terminal talks to the package's own port (see docs/dsm-integration.md).
#   SYNOTERM_UI_STYLE  extjs | vue | url   (default: extjs)
#     extjs — DSM 7.0/7.1 desktop window (`type: "app"` + appWindow class built
#             with Ext.extend(SYNO.SDS.AppWindow, …)). A real DSM window, not a
#             browser popup. This is the target for DSM 7.1.
#     vue   — DSM 7.2+ desktop framework (`<v-app-window>`).
#     url   — documented `.url` registration; opens the URL in a browser
#             window. Kept as a diagnostic fallback.
#
# Output: build/synoterm-<version>-<arch>.spk
set -eu

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

ARCH="${1:-x86_64}"
SPK_VERSION="${2:-0.1.1-0001}"

case "${ARCH}" in
  x86_64) ZIG_TARGET="x86_64-linux-musl" ;;
  armv8)  ZIG_TARGET="aarch64-linux-musl" ;;
  armv7)  ZIG_TARGET="arm-linux-musleabihf" ;;
  *)
    echo "unsupported arch: ${ARCH} (expected x86_64, armv8 or armv7)" >&2
    exit 2
    ;;
esac

OS_MIN_VER="${SYNOTERM_OS_MIN_VER:-7.1-42661}"
NGINX_MOUNT="${SYNOTERM_NGINX_MOUNT:-0}"
case "${NGINX_MOUNT}" in 0|1) ;; *) echo "SYNOTERM_NGINX_MOUNT must be 0 or 1" >&2; exit 2 ;; esac
UI_STYLE="${SYNOTERM_UI_STYLE:-extjs}"
case "${UI_STYLE}" in
  extjs|vue|url) ;;
  *) echo "SYNOTERM_UI_STYLE must be extjs, vue or url, got '${UI_STYLE}'" >&2; exit 2 ;;
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
# Own prefix: leave zig-out/bin/synoterm as the host build for local tests.
zig build -Doptimize=ReleaseSmall -Dtarget="${ZIG_TARGET}" -p "${BUILD}/bin-${ARCH}"

echo "==> frontend bundle"
if [ ! -d frontend/node_modules ]; then
  (cd frontend && npm ci --omit=dev 2>/dev/null || npm install)
fi
(cd frontend && npm run build >/dev/null)

echo "==> staging"
rm -rf "${STAGING}"
mkdir -p "${PAYLOAD}/bin" "${PAYLOAD}/ui/web" "${PAYLOAD}/ui/images"

cp "${BUILD}/bin-${ARCH}/bin/synoterm" "${PAYLOAD}/bin/synoterm"
chmod 755 "${PAYLOAD}/bin/synoterm"

# Always ship the snippet + root helper: without the privileged worker the mount
# is applied by hand (contrib/README.md).
cp -R "${ROOT}/packaging/dsm7/contrib" "${PAYLOAD}/contrib"
if [ "${NGINX_MOUNT}" = "1" ]; then
  mkdir -p "${PAYLOAD}/nginx"
  cp "${ROOT}/packaging/dsm7/contrib/nginx/synoterm.conf" "${PAYLOAD}/nginx/synoterm.conf"
fi
cp "${ROOT}/packaging/dsm7/ui/config.${UI_STYLE}" "${PAYLOAD}/ui/config"
# DSM loads the JS file named as the key in ui/config, so the payload file is
# always Synoterm.js regardless of which wrapper implements the window.
case "${UI_STYLE}" in
  extjs) cp "${ROOT}/packaging/dsm7/ui/Synoterm.extjs.js" "${PAYLOAD}/ui/Synoterm.js" ;;
  vue)   cp "${ROOT}/packaging/dsm7/ui/Synoterm.vue.js" "${PAYLOAD}/ui/Synoterm.js" ;;
esac
cp "${ROOT}"/frontend/dist/* "${PAYLOAD}/ui/web/"
# Tell the bundle where the backend is. It cannot be derived from the page URL:
# with the package the page is served by DSM (/webman/3rdparty/synoterm/web/)
# while the terminal listens on its own port of the same host.
# The UI prefers the same-origin mount when it answers and falls back to the
# package's own port, so one bundle works with and without the manual step.
printf 'window.SYNOTERM_CONFIG = { proxy: "/synoterm", port: 7381 };\n' > "${PAYLOAD}/ui/web/config.js"

# Diagnostic CGI (webman executes *.cgi from the package's ui dir). Harmless at
# runtime; it tells us what DSM hands to a package CGI on this build.
cp "${ROOT}/packaging/dsm7/ui/auth-probe.cgi" "${PAYLOAD}/ui/auth-probe.cgi"
chmod 755 "${PAYLOAD}/ui/auth-probe.cgi"

python3 "${ROOT}/tools/make-icons.py" "${PAYLOAD}/ui/images" >/dev/null
python3 "${ROOT}/tools/make-icons.py" "${STAGING}/icons" >/dev/null
cp "${STAGING}/icons/icon_64.png" "${STAGING}/PACKAGE_ICON.PNG"
cp "${STAGING}/icons/icon_256.png" "${STAGING}/PACKAGE_ICON_256.PNG"
rm -rf "${STAGING}/icons"

cp -R "${ROOT}/packaging/dsm7/conf" "${STAGING}/conf"
if [ "${NGINX_MOUNT}" = "0" ]; then
  # No privileged resource: nothing for DSM's internal workers to do.
  rm -f "${STAGING}/conf/resource"
fi
cp -R "${ROOT}/packaging/dsm7/scripts" "${STAGING}/scripts"
chmod 755 "${STAGING}"/scripts/*

cp "${ROOT}/LICENSE" "${STAGING}/LICENSE" 2>/dev/null || true

# extractsize is reported by Package Center, in KiB.
EXTRACT_SIZE=$(du -sk "${PAYLOAD}" | awk '{print $1}')

echo "==> INFO"
sed \
  -e "s|@SPK_VERSION@|${SPK_VERSION}|g" \
  -e "s|@ARCH@|${ARCH}|g" \
  -e "s|@OS_MIN_VER@|${OS_MIN_VER}|g" \
  -e "s|@EXTRACT_SIZE@|${EXTRACT_SIZE}|g" \
  -e "s|@MAINTAINER@|${MAINTAINER}|g" \
  -e "s|@MAINTAINER_URL@|${MAINTAINER_URL}|g" \
  -e "s|@DISTRIBUTOR@|${DISTRIBUTOR}|g" \
  -e "s|@DISTRIBUTOR_URL@|${DISTRIBUTOR_URL}|g" \
  -e "s|@SUPPORT_URL@|${SUPPORT_URL}|g" \
  "${ROOT}/packaging/dsm7/INFO.template" > "${STAGING}/INFO"

if [ "${NGINX_MOUNT}" = "0" ]; then
  sed -i '/instuninst_restart_services/d' "${STAGING}/INFO"
fi

echo "==> package.tgz"
( cd "${PAYLOAD}" && tar -czf "${STAGING}/package.tgz" --format=ustar --owner=0 --group=0 $(ls -A | sort) )

echo "==> ${OUT}"
( cd "${STAGING}" && tar -cf "${OUT}" --format=ustar --owner=0 --group=0 \
    INFO package.tgz scripts conf LICENSE PACKAGE_ICON.PNG PACKAGE_ICON_256.PNG )

echo "ui style: ${UI_STYLE}, os_min_ver: ${OS_MIN_VER}, nginx mount: ${NGINX_MOUNT}"
ls -lh "${OUT}"
