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

grep -q '@OS_MIN_VER@' "${WORK}/INFO" && { echo "  FAIL unresolved @OS_MIN_VER@ in INFO"; fail=1; }
grep -q '@' "${WORK}/INFO" && { echo "  FAIL unresolved @placeholder@ in INFO"; fail=1; }

for field in package version os_min_ver arch thirdparty dsmuidir dsmappname startable ctl_stop; do
  grep -q "^${field}=" "${WORK}/INFO" || { echo "  MISS INFO field ${field}"; fail=1; }
done

tar -xzf "${WORK}/package.tgz" -C "${WORK}/.." --one-top-level="${WORK}/payload" 2>/dev/null || {
  mkdir -p "${WORK}/payload"
  tar -xzf "${WORK}/package.tgz" -C "${WORK}/payload"
}
for path in bin/synoterm nginx/synoterm.conf ui/config ui/images/icon_48.png ui/web/index.html ui/web/app.js; do
  if [ -e "${WORK}/payload/${path}" ]; then
    echo "  ok   payload/${path}"
  else
    echo "  MISS payload/${path}"
    fail=1
  fi
done

# Exactly one of the two supported UI registrations must be present.
if grep -q '"type": "url"' "${WORK}/payload/ui/config"; then
  echo "  ok   ui/config style: url"
  if [ -e "${WORK}/payload/ui/Synoterm.js" ]; then
    echo "  WARN ui/Synoterm.js shipped with the url style (unused)"
  fi
elif grep -q '"appWindow"' "${WORK}/payload/ui/config"; then
  echo "  ok   ui/config style: vue"
  [ -e "${WORK}/payload/ui/Synoterm.js" ] || { echo "  MISS payload/ui/Synoterm.js"; fail=1; }
else
  echo "  MISS valid ui/config registration"
  fail=1
fi

# The shipped binary must match the declared architecture and be static
# (musl) so it runs on any DSM 7.1+ regardless of the NAS toolchain.
declared=$(sed -n 's/^arch="\(.*\)"$/\1/p' "${WORK}/INFO")
python3 - "${WORK}/payload/bin/synoterm" "${declared}" <<'ELF'
import struct, sys
path, declared = sys.argv[1], sys.argv[2]
data = open(path, "rb").read(64)
if data[:4] != b"\x7fELF":
    print(f"  FAIL {path} is not an ELF binary"); sys.exit(1)
machine = struct.unpack_from("<H", data, 18)[0]
expected = {"x86_64": 62, "armv8": 183, "armv7": 40}.get(declared)
if expected is None:
    print(f"  WARN unknown arch {declared}; skipping ELF check"); sys.exit(0)
if machine != expected:
    print(f"  FAIL ELF machine {machine} does not match arch={declared} ({expected})"); sys.exit(1)
print(f"  ok   ELF machine {machine} matches arch={declared}")
ELF
[ $? -eq 0 ] || fail=1

if command -v readelf >/dev/null 2>&1; then
  if readelf -l "${WORK}/payload/bin/synoterm" 2>/dev/null | grep -q INTERP; then
    echo "  FAIL binary has a dynamic interpreter (not static musl)"
    fail=1
  else
    echo "  ok   statically linked"
  fi
fi
if LC_ALL=C grep -qa 'GLIBC_2\.' "${WORK}/payload/bin/synoterm" 2>/dev/null; then
  echo "  FAIL binary references glibc symbols"
  fail=1
fi

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
