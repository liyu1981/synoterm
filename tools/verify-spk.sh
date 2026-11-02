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
for path in INFO package.tgz scripts/start-stop-status conf/privilege conf/resource LICENSE PACKAGE_ICON.PNG; do
  check "${path}"
done

for field in package version os_min_ver arch thirdparty dsmuidir dsmappname startable ctl_stop; do
  grep -q "^${field}=" "${WORK}/INFO" || { echo "  MISS INFO field ${field}"; fail=1; }
done

tar -xzf "${WORK}/package.tgz" -C "${WORK}/.." --one-top-level="${WORK}/payload" 2>/dev/null || {
  mkdir -p "${WORK}/payload"
  tar -xzf "${WORK}/package.tgz" -C "${WORK}/payload"
}
for path in bin/synoterm nginx/synoterm.conf ui/config ui/Synoterm.js ui/images/icon_48.png ui/web/index.html ui/web/app.js; do
  if [ -e "${WORK}/payload/${path}" ]; then
    echo "  ok   payload/${path}"
  else
    echo "  MISS payload/${path}"
    fail=1
  fi
done

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
