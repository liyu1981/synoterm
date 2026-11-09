#!/bin/sh
# Structural checks for a built .spk. Catches the classic packaging mistakes:
# wrong layout, missing setuid relpath, non-executable scripts, missing icons.
#
#   tools/verify-spk.sh build/synoterm-0.1.0-0001-x86_64.spk
set -eu
SPK="${1:?usage: verify-spk.sh <file.spk>}"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

tar -xf "${SPK}" -C "${WORK}"
fail=0

check() {
  if [ -e "${WORK}/$1" ]; then
    echo "  ok   $1"
  else
    echo "  MISS $1"
    fail=1
  fi
}

echo "spk: ${SPK}"
for path in INFO package.tgz scripts/start-stop-status conf/privilege LICENSE PACKAGE_ICON.PNG; do
  check "${path}"
done

grep -q '@OS_MIN_VER@' "${WORK}/INFO" && { echo "  FAIL unresolved @OS_MIN_VER@ in INFO"; fail=1; }
grep -q '@' "${WORK}/INFO" && { echo "  FAIL unresolved @placeholder@ in INFO"; fail=1; }

for field in package version os_min_ver arch thirdparty dsmuidir dsmappname startable ctl_stop; do
  grep -q "^${field}=" "${WORK}/INFO" || { echo "  MISS INFO field ${field}"; fail=1; }
done

tar -xzf "${WORK}/package.tgz" -C "${WORK}/.." --one-top-level="${WORK}/payload" 2>/dev/null || {
  mkdir -p "${WORK}/payload"
  tar -xzf "${WORK}/package.tgz" -C "${WORK}/payload"
}
for path in bin/synoterm ui/config ui/auth-probe.cgi ui/images/icon_48.png ui/web/index.html ui/web/app.js ui/web/icon.svg ui/web/config.js \
            contrib/README.md contrib/install-nginx-mount.sh contrib/uninstall-nginx-mount.sh \
            contrib/diagnose.sh contrib/nginx/synoterm.conf; do
  if [ -e "${WORK}/payload/${path}" ]; then
    echo "  ok   payload/${path}"
  else
    echo "  MISS payload/${path}"
    fail=1
  fi
done

# The UI registration must match the requested flavour.
if grep -q '"appWindow"' "${WORK}/payload/ui/config"; then
  echo "  ok   ui/config style: app (window class)"
  [ -e "${WORK}/payload/ui/Synoterm.js" ] || { echo "  MISS payload/ui/Synoterm.js"; fail=1; }
  grep -q '"type": "app"' "${WORK}/payload/ui/config" || { echo "  FAIL app registration needs type=app"; fail=1; }
  grep -q 'SYNO.SDS.App.Synoterm.Instance' "${WORK}/payload/ui/config" || { echo "  FAIL wrong app class"; fail=1; }
  grep -q 'SYNO.SDS.App.Synoterm.Instance' "${WORK}/INFO" || { echo "  FAIL INFO dsmappname must match"; fail=1; }
  if grep -q 'Ext.extend(SYNO.SDS.AppWindow' "${WORK}/payload/ui/Synoterm.js"; then
    echo "  ok   window class: ExtJS (DSM 7.0/7.1)"
  elif grep -q 'Vue.extend' "${WORK}/payload/ui/Synoterm.js"; then
    echo "  ok   window class: Vue (DSM 7.2+)"
  else
    echo "  FAIL ui/Synoterm.js defines no window class"; fail=1
  fi
elif grep -q '"type": "url"' "${WORK}/payload/ui/config"; then
  echo "  ok   ui/config style: url (browser window)"
  # DSM resolves a relative url against the web root, not /webman/ — a bare
  # "3rdparty/…" becomes /3rdparty/… and 404s. Keep it absolute.
  grep -q '"url": "/webman/3rdparty/' "${WORK}/payload/ui/config" || {
    echo "  FAIL ui/config url must be absolute: /webman/3rdparty/synoterm/web/index.html"
    fail=1
  }
else
  echo "  MISS valid ui/config registration"
  fail=1
fi

# The nginx mount is optional: only Synology-signed packages may use DSM's
# internal workers, so a self-built package must not ship conf/resource.
if [ -e "${WORK}/conf/resource" ]; then
  echo "  ok   conf/resource (privileged nginx mount — only installable when signed)"
  [ -e "${WORK}/payload/nginx/synoterm.conf" ] || { echo "  MISS payload/nginx/synoterm.conf"; fail=1; }
else
  echo "  ok   no conf/resource (no internal worker)"
fi

# One bundle serves both transports: the prefix is fixed, only the origin moves.
config_js="${WORK}/payload/ui/web/config.js"
for expected in 'proxy: "/synoterm"' 'port:' 'httpsPort:'; do
  grep -q "${expected}" "${config_js}" || {
    echo "  FAIL ui/web/config.js must carry ${expected}"; fail=1; }
done

[ -x "${WORK}/payload/ui/auth-probe.cgi" ] || { echo "  FAIL ui/auth-probe.cgi must be executable"; fail=1; }

# The setuid tool must be declared with the same path the payload ships.
if ! grep -q '"relpath": "bin/synoterm"' "${WORK}/conf/privilege"; then
  echo "  MISS conf/privilege tool relpath"
  fail=1
fi

for script in "${WORK}"/scripts/*; do
  mode=$(stat -c '%a' "${script}" 2>/dev/null || stat -f '%Lp' "${script}")
  case "${mode}" in
    *[1357]) ;;
    *) echo "  MISS executable bit on $(basename "${script}") (mode ${mode})"; fail=1 ;;
  esac
done

if [ "${fail}" -ne 0 ]; then
  echo "verify-spk: FAILED"
  exit 1
fi
echo "verify-spk: ok"
