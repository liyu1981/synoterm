#!/usr/bin/env bash
# synoterm — interactive NAS test run.
#
# Runs on YOUR machine, drives the NAS over SSH, prints everything it does, and
# stops for confirmation before each step that changes something. Nothing is
# installed until step 5.
#
#   tools/nas-test.sh nas.local                 # ssh user "admin"
#   tools/nas-test.sh nas.local --user bob
#   tools/nas-test.sh nas.local --dry-run       # plan only, changes nothing
#
# Steps
#   1  detect DSM version + architecture        (read-only)
#   2  preflight checks on the NAS              (read-only)
#   3  log in to DSM, probe authenticate.cgi    (creates + deletes a session)
#   4  smoke test: binary from /tmp over a tunnel (no install, no nginx change)
#   5  install the .spk and verify end to end   (changes DSM; asks first)
#   6  optional uninstall
#
# Needs on this machine: ssh, scp, curl, node (for the WebSocket probe).
# zig + npm are only used if a binary/package has to be built.
set -uo pipefail

ORIGINAL_ARGS=("$@")

NAS=""
SSH_USER="admin"
SSH_PORT="22"
DSM_PORT="5001"
DSM_USER="admin"
DRY_RUN=0
YES=0
ASSUME_ARCH=""
SKIP_SMOKE=0
SKIP_INSTALL=0
SKIP_AUTH=0
UNINSTALL=0
COOKIE_ARG=""
FORCE_UI_STYLE=""
COOKIE_ONLY_OK="unknown"
PROBED=0
INSTALLED="no"
VERBOSE=1
TRACE=0
LOG_FILE=""

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Options:
  --user <name>       SSH user (default: admin)
  --ssh-port <port>   SSH port (default: 22)
  --dsm-port <port>   DSM HTTPS port (default: 5001)
  --dsm-user <name>   DSM account to test with (default: admin)
  --arch <arch>       x86_64 | armv8 | armv7 (default: detect)
  --skip-smoke        skip step 4
  --skip-install      stop after step 4
  --skip-auth         do not log in to DSM (read-only + smoke steps only)
  --uninstall         uninstall at the end (otherwise step 6 is skipped)
  --cookie '<header>' use a Cookie header instead of logging in
  --ui-style url|vue  force the package flavour instead of probing
  --yes               do not ask before the smoke test / install (never uninstalls)
  --quiet             do not print the commands being run
  --trace             also trace inside bash (set -x) and remote scripts (sh -x)
  --log <file>        append the whole transcript (secrets redacted) to <file>
  --dry-run           print remote commands instead of running them
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --user) SSH_USER="${2:?}"; shift 2 ;;
    --ssh-port) SSH_PORT="${2:?}"; shift 2 ;;
    --dsm-port) DSM_PORT="${2:?}"; shift 2 ;;
    --dsm-user) DSM_USER="${2:?}"; shift 2 ;;
    --arch) ASSUME_ARCH="${2:?}"; shift 2 ;;
    --skip-smoke) SKIP_SMOKE=1; shift ;;
    --skip-install) SKIP_INSTALL=1; shift ;;
    --skip-auth) SKIP_AUTH=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --quiet|-q) VERBOSE=0; shift ;;
    --trace) TRACE=1; VERBOSE=1; shift ;;
    --log) LOG_FILE="${2:?}"; shift 2 ;;
    --cookie) COOKIE_ARG="${2:?}"; shift 2 ;;
    --ui-style) FORCE_UI_STYLE="${2:?}"; shift 2 ;;
    --yes|-y) YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) NAS="$1"; shift ;;
  esac
done
[ -n "${NAS}" ] || { usage >&2; exit 2; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${SSH_USER}@${NAS}"
SSH_OPTS=(-p "${SSH_PORT}" -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
REMOTE_DIR="/tmp/synoterm-test"

# ------------------------------------------------------------------ helpers --
bold() { printf '\033[1m%s\033[0m\n' "$*"; }
step() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
ok() { printf '  \033[32mok\033[0m   %s\n' "$*"; }
warn() { printf '  \033[33mwarn\033[0m %s\n' "$*"; }
fail() { printf '  \033[31mfail\033[0m %s\n' "$*"; }
note() { printf '       %s\n' "$*"; }
die() { printf '\n\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

redact() { # hide secrets in anything we print
  sed -E \
    -e 's/(id=)[A-Za-z0-9._%~-]{3,}/\1********/g' \
    -e 's/(passwd[=:])[^ &"]*/\1********/g' \
    -e 's/(_sid=)[^ &"]*/\1********/g' \
    -e 's/(--token[ =]+)[^ ]*/\1********/g' \
    -e 's/(otp_code[=:])[^ &"]*/\1********/g' \
    -e 's/(HTTP_X_SYNO_TOKEN=)[^ ]*/\1********/g' \
    -e 's/(Cookie: )[^"]*/\1********/g'
}

trace() { # trace <command-line>; goes to stderr so command substitution stays clean
  [ "${VERBOSE}" -eq 1 ] || return 0
  printf '  \033[2m+ %s\033[0m\n' "$(printf '%s' "$1" | redact)" >&2
}

why() { # explain the next command
  [ "${VERBOSE}" -eq 1 ] || return 0
  printf '       \033[2m%s\033[0m\n' "$*" >&2
}

confirm() {
  [ "${YES}" -eq 1 ] && return 0
  printf '\n  \033[1m%s\033[0m [y/N] ' "$1"
  read -r answer || return 1
  case "${answer}" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

elf_machine() { # ELF e_machine of a little-endian binary (62/183/40)
  [ -f "$1" ] || return 1
  od -An -tu2 -j18 -N2 "$1" 2>/dev/null | tr -d ' \n'
}

expected_machine() {
  case "$1" in
    x86_64) echo 62 ;;
    armv8) echo 183 ;;
    armv7) echo 40 ;;
  esac
}

sq() { # single-quote a string for a remote shell
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
}

read_nas() { # read-only remote command, executed even in --dry-run
  trace "ssh ${TARGET} \"$1\""
  ssh "${SSH_OPTS[@]}" "${TARGET}" "$1"
}

on_nas() {
  if [ "${DRY_RUN}" -eq 1 ]; then
    printf '  \033[2m[dry-run] ssh %s %s\033[0m\n' "${TARGET}" "$1"
    return 0
  fi
  trace "ssh ${TARGET} \"$1\""
  ssh "${SSH_OPTS[@]}" "${TARGET}" "$1"
}

on_nas_root() { # through sudo, with a TTY so the password prompt works
  if [ "${DRY_RUN}" -eq 1 ]; then
    printf '  \033[2m[dry-run] ssh -t %s "sudo: %s"\033[0m\n' "${TARGET}" "$1"
    return 0
  fi
  trace "ssh -t ${TARGET} \"sudo sh -c '$(sq "$1")'\""
  ssh -t "${SSH_OPTS[@]}" "${TARGET}" "sudo sh -c '$(sq "$1")'"
  status=$?
  [ "${status}" -eq 0 ] || printf '  \033[2m<- exit %s\033[0m\n' "${status}" >&2
  return "${status}"
}

copy_to_nas() {
  if [ "${DRY_RUN}" -eq 1 ]; then
    printf '  \033[2m[dry-run] scp %s -> %s:%s\033[0m\n' "$1" "${NAS}" "$2"
    return 0
  fi
  trace "scp -P ${SSH_PORT} ${1} ${TARGET}:${2}"
  scp -P "${SSH_PORT}" -q "$1" "${TARGET}:$2"
  status=$?
  [ "${status}" -eq 0 ] || printf '  \033[2m<- exit %s\033[0m\n' "${status}" >&2
  return "${status}"
}

cleanup() {
  if [ -n "${LOG_FILE}" ] && [ -f "${LOG_FILE}" ]; then
    esc=$(printf '\033')
    sed "s/${esc}\[[0-9;]*m//g" "${LOG_FILE}" > "${LOG_FILE}.tmp" 2>/dev/null \
      && mv "${LOG_FILE}.tmp" "${LOG_FILE}" || rm -f "${LOG_FILE}.tmp"
  fi
  [ "${DRY_RUN}" -eq 1 ] && return 0
  on_nas "rm -rf '${REMOTE_DIR}'" >/dev/null 2>&1 || true
}
trap cleanup EXIT

mkdir -p "${ROOT}/build"

if [ "${TRACE}" -eq 1 ]; then
  PS4='  \033[2m[trace] +${LINENO}: \033[0m'
  set -x
fi

if [ -n "${LOG_FILE}" ]; then
  mkdir -p "$(dirname "${LOG_FILE}")"
  exec > >(tee -a "${LOG_FILE}") 2>&1
  {
    printf '\n===== synoterm nas-test %s =====\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'args: %s\n' "$(printf '%s ' "$0" "${ORIGINAL_ARGS[@]}" | redact)"
    printf 'this machine: %s\n' "$(uname -sm 2>/dev/null)"
  } >>"${LOG_FILE}"
  note "transcript (secrets redacted): ${LOG_FILE}"
fi

# --------------------------------------------------------------- 1. detect --
step "1/6  detect DSM version and architecture"
why "Read-only SSH calls: uname, /etc/VERSION and the Synology model id."
why "The model id + arch decide which .spk to build; the build number decides"
why "whether os_min_ver has to be lowered for an older DSM 7.1 build."
UN="$(read_nas 'uname -m' 2>/dev/null | tr -d '\r')" || die "cannot reach ${TARGET} over SSH"
[ -n "${UN}" ] || die "could not read the architecture from ${NAS}"
VERSION_LINE="$(read_nas '. /etc/VERSION 2>/dev/null; echo "${productversion:-?} build ${buildnumber:-?}"' | tr -d '\r')"
[ -n "${VERSION_LINE}" ] || VERSION_LINE="unknown (no /etc/VERSION)"
MODEL="$(read_nas 'cat /proc/sys/kernel/syno_hw_version 2>/dev/null' | tr -d '\r')"
DSM_BUILD="$(read_nas '. /etc/VERSION 2>/dev/null; echo "${buildnumber:-0}"' | tr -d '\r')"
DSM_MAJOR="$(read_nas '. /etc/VERSION 2>/dev/null; echo "${majorversion:-7}.${minorversion:-1}"' | tr -d '\r')"

case "${ASSUME_ARCH:-${UN}}" in
  x86_64|amd64) ARCH=x86_64; ZIG_TARGET="x86_64-linux-musl" ;;
  aarch64|armv8l|arm64) ARCH=armv8; ZIG_TARGET="aarch64-linux-musl" ;;
  armv7l|armv7) ARCH=armv7; ZIG_TARGET="arm-linux-musleabihf" ;;
  *) die "unsupported architecture '${UN}'" ;;
esac
ok "nas:   ${NAS} (model ${MODEL:-unknown})"
ok "dsm:   ${VERSION_LINE}"
ok "arch:  ${UN} -> spk arch '${ARCH}'"

OS_MIN_VER="7.1-42661"
case "${DSM_BUILD}" in
  ''|*[!0-9]*) warn "could not read the DSM build number; assuming os_min_ver=${OS_MIN_VER}" ;;
  *)
    if [ "${DSM_BUILD}" -lt 42661 ]; then
      OS_MIN_VER="${DSM_MAJOR}-${DSM_BUILD}"
      warn "DSM build ${DSM_BUILD} is older than 42661 — building with os_min_ver=${OS_MIN_VER}"
    else
      ok "DSM build ${DSM_BUILD} satisfies os_min_ver=${OS_MIN_VER}"
    fi
    ;;
esac

# ------------------------------------------------------------ 2. preflight --
step "2/6  preflight (read-only)"
why "Copies two small scripts to ${REMOTE_DIR} and runs the preflight."
why "It only reads: /etc/VERSION, binaries, /etc/nginx, netstat, /var/packages."
on_nas "mkdir -p '${REMOTE_DIR}'" >/dev/null || die "cannot create ${REMOTE_DIR} on the NAS"
copy_to_nas "${ROOT}/tools/nas-preflight.sh" "${REMOTE_DIR}/nas-preflight.sh"
copy_to_nas "${ROOT}/tools/nas-auth-test.sh" "${REMOTE_DIR}/nas-auth-test.sh"
on_nas "chmod 700 '${REMOTE_DIR}/nas-preflight.sh' '${REMOTE_DIR}/nas-auth-test.sh'"
if [ "${DRY_RUN}" -eq 1 ]; then
  note "[dry-run] would run ${REMOTE_DIR}/nas-preflight.sh on the NAS"
else
  ssh "${SSH_OPTS[@]}" "${TARGET}" "sh '${REMOTE_DIR}/nas-preflight.sh'" 2>&1 | sed 's/^/  /'
fi

# ------------------------------------------------- 3. DSM login + auth probe --
step "3/6  DSM session + authenticate.cgi probe"
why "Goal: find out whether DSM will tell the backend who you are."
why "1) POST /webapi/auth.cgi with your account/password (+2FA) to get a session"
why "   cookie, exactly like the DSM login page does. The password goes through a"
why "   pipe, never argv, and the session is logged out at the end."
why "2) On the NAS, run authenticate.cgi twice: with the cookie alone, and with"
why "   the cookie + SynoToken. Its output is your DSM account name."
why "That answer decides the package flavour: .url (7.1) or vue (7.2)."

DSM_PASS=""
DSM_OTP=""
DSM_SID=""
DSM_TOKEN=""
COOKIE_HEADER=""
LOGGED_IN=0
UI_STYLE="url"

if [ "${SKIP_AUTH}" -eq 1 ]; then
  note "skipped (--skip-auth): no DSM session, so the auth probe and step 5c are skipped"
elif [ "${DRY_RUN}" -eq 1 ]; then
  note "[dry-run] would prompt for the DSM password and probe authenticate.cgi"
else
  # --- obtain a session cookie -------------------------------------------------
  if [ -n "${COOKIE_ARG}" ]; then
    COOKIE_HEADER="${COOKIE_ARG}"
    ok "using the supplied Cookie header"
  else
    printf '  DSM account [%s]: ' "${DSM_USER}"
    read -r input_user || true
    [ -n "${input_user:-}" ] && DSM_USER="${input_user}"
    printf '  DSM password for %s (not echoed): ' "${DSM_USER}"
    read -rs DSM_PASS || true
    printf '\n'
    printf '  2FA code, empty if unused: '
    read -r DSM_OTP || true

    curl_config="url = \"https://${NAS}:${DSM_PORT}/webapi/auth.cgi\"
connect-timeout = 4
max-time = 10
data-urlencode = \"api=SYNO.API.Auth\"
data-urlencode = \"version=6\"
data-urlencode = \"method=login\"
data-urlencode = \"account=${DSM_USER}\"
data-urlencode = \"passwd=${DSM_PASS}\"
data-urlencode = \"session=Synoterm\"
data-urlencode = \"format=cookie\"
data-urlencode = \"enable_syno_token=yes\"
${DSM_OTP:+data-urlencode = \"otp_code=${DSM_OTP}\"}"
    trace "curl -sS -k --config - <<< $(printf '%s' "${curl_config}" | tr '\n' ';' | sed 's/; */ ; /g')"
    login_body="$(printf '%s\n' "${curl_config}" | curl -sS -k --config - 2>&1)"
    DSM_PASS=""

    DSM_SID="$(printf '%s' "${login_body}" | sed -n 's/.*"sid"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    DSM_TOKEN="$(printf '%s' "${login_body}" | sed -n 's/.*"synotoken"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"

    if [ -n "${DSM_SID}" ]; then
      LOGGED_IN=1
      COOKIE_HEADER="id=${DSM_SID}"
      ok "logged in as ${DSM_USER} (sid ${DSM_SID:0:6}…)"
      if [ -n "${DSM_TOKEN}" ]; then
        ok "got a SynoToken (${#DSM_TOKEN} chars)"
      else
        warn "the login response carried no SynoToken"
      fi
    else
      fail "DSM login failed"
      case "${login_body}" in
        *"Could not connect"*|*"Connection refused"*|*"timed out"*|*"curl: (7)"*|*"curl: (28)"*)
          note "cannot reach https://${NAS}:${DSM_PORT} — wrong port, or DSM HTTPS disabled" ;;
        *)
          note "response: $(printf '%s' "${login_body}" | tr -d '\n' | head -c 300)" ;;
      esac
      note "fallback: paste the Cookie header from the logged-in DSM tab"
      printf '  Cookie header (or empty to abort): '
      read -r pasted || true
      [ -n "${pasted:-}" ] || die "no DSM session available, cannot test authentication"
      case "${pasted}" in
        *=*) COOKIE_HEADER="${pasted}" ;;
        *) COOKIE_HEADER="id=${pasted}" ;;
      esac
    fi
  fi

  # --- probe authenticate.cgi on the NAS --------------------------------------
  # Secrets travel over the SSH channel only: a 0600 file, then removed.
  printf '%s\n%s\n' "${COOKIE_HEADER}" "${DSM_TOKEN}" > "${ROOT}/build/.cookie.$$"
  chmod 600 "${ROOT}/build/.cookie.$$"
  copy_to_nas "${ROOT}/build/.cookie.$$" "${REMOTE_DIR}/cookie"
  rm -f "${ROOT}/build/.cookie.$$"
  on_nas "chmod 600 '${REMOTE_DIR}/cookie'"

  printf '\n'
  if [ "${TRACE}" -eq 1 ]; then
    trace "ssh ${TARGET} sh -x ${REMOTE_DIR}/nas-auth-test.sh --file ${REMOTE_DIR}/cookie"
    probe_out="$(ssh "${SSH_OPTS[@]}" "${TARGET}" "sh -x '${REMOTE_DIR}/nas-auth-test.sh' --file '${REMOTE_DIR}/cookie'" 2>&1)"
  else
    trace "ssh ${TARGET} sh ${REMOTE_DIR}/nas-auth-test.sh --file ${REMOTE_DIR}/cookie"
    probe_out="$(ssh "${SSH_OPTS[@]}" "${TARGET}" "sh '${REMOTE_DIR}/nas-auth-test.sh' --file '${REMOTE_DIR}/cookie'" 2>&1)"
  fi
  printf '%s\n' "${probe_out}" | sed 's/^/  /'

  if printf '%s' "${probe_out}" | grep -Eq 'cookie only[[:space:]]*->[[:space:]]*[^<[:space:]]'; then
    COOKIE_ONLY_OK="yes"
  elif printf '%s' "${probe_out}" | grep -q 'cookie only'; then
    COOKIE_ONLY_OK="no"
  else
    COOKIE_ONLY_OK="unknown"
PROBED=0
  fi
  PROBED=1
  case "${COOKIE_ONLY_OK}" in
    yes) ok "cookie-only authentication works on this DSM" ;;
    no)  warn "cookie-only authentication did NOT return an account" ;;
    *)   warn "could not interpret the probe output above" ;;
  esac

  on_nas "rm -f '${REMOTE_DIR}/cookie'"

  if [ -n "${FORCE_UI_STYLE}" ]; then
    UI_STYLE="${FORCE_UI_STYLE}"
    note "ui style forced with --ui-style ${UI_STYLE}"
  elif [ "${COOKIE_ONLY_OK}" = "yes" ]; then
    UI_STYLE="url"
  elif [ "${COOKIE_ONLY_OK}" = "no" ]; then
    UI_STYLE="vue"
  elif [ "${YES}" -eq 0 ]; then
    printf '\n  Could not decide automatically. Use the 7.2 vue build instead of .url? [y/N] '
    read -r use_vue || true
    case "${use_vue:-n}" in y|Y) UI_STYLE="vue" ;; *) UI_STYLE="url" ;; esac
  else
    UI_STYLE="url"
  fi


  if [ "${UI_STYLE}" = "vue" ]; then
    warn "selected the vue build (DSM 7.2 desktop framework)"
  else
    ok "selected the default .url build"
  fi
fi

UI_STYLE="${UI_STYLE:-url}"
if [ -n "${FORCE_UI_STYLE}" ]; then
  UI_STYLE="${FORCE_UI_STYLE}"
  note "ui style forced with --ui-style ${UI_STYLE}"
fi
SPK_VERSION="0.1.0-0001"
[ "${UI_STYLE}" = "vue" ] && SPK_VERSION="0.1.0-0002"

# ------------------------------------------------------------- 4. smoke test --
if [ "${SKIP_SMOKE}" -eq 1 ]; then
  step "4/6  smoke test — skipped"
else
  step "4/6  smoke test: the binary from /tmp (no install, no nginx change)"
why "Runs the real binary on the NAS as your SSH user, on 127.0.0.1:7382."
why "An SSH tunnel forwards that loopback port to this machine so you can open"
why "http://127.0.0.1:7382/ in a browser and use the terminal."
why "Nothing is installed and DSM's nginx is not touched; you can Ctrl-C any time."
  if [ "${DRY_RUN}" -eq 1 ] || confirm "Copy the binary + UI to ${REMOTE_DIR} and run it as ${SSH_USER} on port 7382?"; then
    want_machine="$(expected_machine "${ARCH}")"
    have_machine="$(elf_machine "${ROOT}/zig-out/bin/synoterm" || true)"
    if [ ! -x "${ROOT}/zig-out/bin/synoterm" ] || [ ! -f "${ROOT}/frontend/dist/index.html" ] \
       || [ "${have_machine}" != "${want_machine}" ]; then
      note "building backend for ${ZIG_TARGET} (found ELF machine '${have_machine:-none}', want ${want_machine}) and the frontend…"
      trace "cd ${ROOT} && zig build -Doptimize=ReleaseSmall -Dtarget=${ZIG_TARGET}"
      (cd "${ROOT}" && zig build -Doptimize=ReleaseSmall -Dtarget="${ZIG_TARGET}" >/dev/null) || die "zig build failed"
      trace "cd ${ROOT}/frontend && npm run build"
      (cd "${ROOT}/frontend" && { [ -d node_modules ] || npm install --no-audit --no-fund >/dev/null; } && npm run build >/dev/null) || die "frontend build failed"
    fi

    copy_to_nas "${ROOT}/zig-out/bin/synoterm" "${REMOTE_DIR}/synoterm"
    on_nas "chmod 755 '${REMOTE_DIR}/synoterm'"
    if [ "${DRY_RUN}" -eq 0 ]; then
      on_nas "rm -rf '${REMOTE_DIR}/web' && mkdir -p '${REMOTE_DIR}/web'"
      scp -P "${SSH_PORT}" -q -r "${ROOT}/frontend/dist/." "${TARGET}:${REMOTE_DIR}/web/"
    fi

    on_nas "HOME=/tmp nohup '${REMOTE_DIR}/synoterm' --listen 7382 --auth dev --web-root '${REMOTE_DIR}/web' >'${REMOTE_DIR}/server.log' 2>&1 & echo \$! > '${REMOTE_DIR}/server.pid'; sleep 1; tail -n 3 '${REMOTE_DIR}/server.log'"

    if [ "${DRY_RUN}" -eq 0 ]; then
      note "tunnelling 127.0.0.1:7382 from the NAS to this machine…"
      trace "ssh -N -L 7382:127.0.0.1:7382 ${TARGET} &"
      ssh -N "${SSH_OPTS[@]}" -o ExitOnForwardFailure=yes -L "7382:127.0.0.1:7382" "${TARGET}" &
      TUNNEL_PID=$!
      attempt=0
      while [ "${attempt}" -lt 30 ]; do
        if (exec 3<>/dev/tcp/127.0.0.1/7382) 2>/dev/null; then break; fi
        attempt=$((attempt + 1))
        sleep 0.3
      done

      printf '\n'
      bold "  Open this in your browser (a real terminal on the NAS):"
      bold "      http://127.0.0.1:7382/"
      printf '\n  Automated probe:\n'
      trace "node tools/ws-test.mjs ws://127.0.0.1:7382/ws --expect SYNOTERM_WS_OK"
      (cd "${ROOT}" && node tools/ws-test.mjs ws://127.0.0.1:7382/ws --expect SYNOTERM_WS_OK) \
        || warn "probe failed — see ${REMOTE_DIR}/server.log on the NAS"

      printf '\n  Press Enter when you are done with the browser terminal… '
      read -r _ || true
      kill "${TUNNEL_PID}" 2>/dev/null || true
    fi

    on_nas "if [ -f '${REMOTE_DIR}/server.pid' ]; then kill \$(cat '${REMOTE_DIR}/server.pid') 2>/dev/null; fi; rm -f '${REMOTE_DIR}/server.pid'; echo '  server stopped'"
  fi
fi

# --------------------------------------------------------------- 5. install --
if [ "${SKIP_INSTALL}" -eq 1 ]; then
  step "5/6  install — skipped (--skip-install)"
else
  step "5/6  install the package (this changes DSM)"
why "Uploads the .spk and runs 'synopkg install' as root (sudo password needed)."
why "DSM then: unpacks the payload, applies the setuid tool privilege (4750),"
why "enables the nginx mount, and starts the service."
  note "Package Center reloads nginx and applies the setuid tool privilege;"
  note "your sudo password will be asked over the SSH session."

  SPK_FILE="${ROOT}/build/synoterm-${SPK_VERSION}-${ARCH}.spk"
  if [ ! -f "${SPK_FILE}" ]; then
    note "building ${SPK_VERSION} for ${ARCH} (os_min_ver=${OS_MIN_VER}, ui=${UI_STYLE})…"
    trace "SYNOTERM_OS_MIN_VER=${OS_MIN_VER} SYNOTERM_UI_STYLE=${UI_STYLE} tools/build-spk.sh ${ARCH} ${SPK_VERSION}"
    (cd "${ROOT}" && SYNOTERM_OS_MIN_VER="${OS_MIN_VER}" SYNOTERM_UI_STYLE="${UI_STYLE}" \
      ./tools/build-spk.sh "${ARCH}" "${SPK_VERSION}" >/dev/null) || die "package build failed"
  fi
  ok "package: $(basename "${SPK_FILE}") ($(du -h "${SPK_FILE}" | cut -f1))"
  (cd "${ROOT}" && ./tools/verify-spk.sh "${SPK_FILE}" | tail -n 3 | sed 's/^/  /')

  if [ "${DRY_RUN}" -eq 1 ] || confirm "Upload and install it now?"; then
    copy_to_nas "${SPK_FILE}" "/tmp/$(basename "${SPK_FILE}")"
    if on_nas_root "synopkg install '/tmp/$(basename "${SPK_FILE}")'"; then
      ok "install command succeeded"
    else
      warn "synopkg reported an error — read the output above"
      note "common causes: trust level still blocks unsigned packages, or arch mismatch"
    fi
    on_nas "rm -f '/tmp/$(basename "${SPK_FILE}")'"

    step "5b/6  verify the installed package"
    if [ "${DRY_RUN}" -eq 1 ]; then
      note "[dry-run] would check synopkg status, setuid mode, nginx mount and the log"
    elif read_nas 'test -d /var/packages/synoterm' 2>/dev/null; then
      on_nas "echo '  synopkg status:'; synopkg status synoterm 2>&1 | sed 's/^/    /'"
      on_nas "echo '  setuid tool:'; ls -l /var/packages/synoterm/target/bin/synoterm 2>&1 | sed 's/^/    /'"
      on_nas "echo '  nginx mount files:'; grep -rl synoterm /etc/nginx/ 2>/dev/null | sed 's/^/    /' || echo '    (none found)'"
      on_nas "echo '  loopback listener:'; netstat -ltn 2>/dev/null | grep -w 7381 | sed 's/^/    /' || echo '    (nothing on 7381)'"
      on_nas "echo '  server log:'; tail -n 5 /var/packages/synoterm/var/runtime/synoterm.log 2>&1 | sed 's/^/    /'"
      INSTALLED="yes"
      warn "check that the setuid line starts with -rwsr-x--- root package"
    else
      warn "package directory /var/packages/synoterm is missing — the install did not complete"
      note "usual cause: Package Center trust level still blocks unsigned packages"
      note "Package Center → Settings → General → Trust Level → allow any publisher, then retry"
    fi

    step "5c/6  end-to-end through DSM (nginx + TLS + authenticate.cgi + PTY)"
why "Connects to wss://${NAS}:${DSM_PORT}/synoterm/ws with your session cookie."
why "Success means: nginx proxied the upgrade, authenticate.cgi recognised the"
why "session, the PTY was spawned for your account, and the shell answered."
    if [ "${DRY_RUN}" -eq 0 ] && [ -n "${COOKIE_HEADER}" ]; then
      trace "node tools/ws-test.mjs wss://${NAS}:${DSM_PORT}/synoterm/ws --cookie id=******** ${DSM_TOKEN:+--token ********} --insecure"
      (cd "${ROOT}" && node tools/ws-test.mjs "wss://${NAS}:${DSM_PORT}/synoterm/ws" \
        --cookie "${COOKIE_HEADER}" ${DSM_TOKEN:+--token "${DSM_TOKEN}"} \
        --insecure --expect SYNOTERM_DSM_OK --timeout 15) \
        || warn "end-to-end probe failed — the HTTP status hint above says why"
    else
      note "skipped (no DSM session in this run, or --dry-run)"
    fi

    if [ "${LOGGED_IN}" -eq 1 ] && [ "${DRY_RUN}" -eq 0 ]; then
      trace "curl https://${NAS}:${DSM_PORT}/webapi/auth.cgi (method=logout)"
      printf '%s\n' "url = \"https://${NAS}:${DSM_PORT}/webapi/auth.cgi\"
data-urlencode = \"api=SYNO.API.Auth\"
data-urlencode = \"version=6\"
data-urlencode = \"method=logout\"
data-urlencode = \"session=Synoterm\"
data-urlencode = \"_sid=${DSM_SID}\"" | curl -sS -k --max-time 10 --config - >/dev/null 2>&1
      ok "logged the test session out"
    fi

    if [ "${DRY_RUN}" -eq 0 ] && [ "${INSTALLED}" = "yes" ]; then
      printf '\n'
      bold "Now open DSM → main menu → Terminal."
      note "Expect a DSM window with the terminal, running as the account you use."
      note "Inside it: id; pwd; stty size   (should match the real DSM user)"
    fi
  fi
fi

# ------------------------------------------------------------- 6. uninstall --
step "6/6  rollback (optional)"
do_uninstall=0
if [ "${UNINSTALL}" -eq 1 ]; then
  do_uninstall=1
elif [ "${SKIP_INSTALL}" -eq 0 ] && [ "${YES}" -eq 0 ] && confirm "Uninstall synoterm now?"; then
  do_uninstall=1
fi

if [ "${do_uninstall}" -eq 1 ] && [ "${DRY_RUN}" -eq 0 ]; then
  "${ROOT}/tools/nas-uninstall.sh" "${NAS}" --user "${SSH_USER}" --ssh-port "${SSH_PORT}" --yes
elif [ "${DRY_RUN}" -eq 1 ]; then
  note "[dry-run] would offer to uninstall"
elif [ "${SKIP_INSTALL}" -eq 1 ]; then
  note "nothing was installed"
else
  note "kept installed (pass --uninstall to remove it). Roll back later with:"
  note "  tools/nas-uninstall.sh ${NAS} --user ${SSH_USER}"
fi

step "summary"
ok "nas:        ${NAS} (${MODEL:-unknown model}, ${UN})"
ok "dsm:        ${VERSION_LINE}"
ok "package:    synoterm ${SPK_VERSION} for ${ARCH} (ui style ${UI_STYLE}, os_min_ver ${OS_MIN_VER})"
case "${COOKIE_ONLY_OK}" in
  yes) ok "dsm auth:   cookie-only works — the .url registration is enough" ;;
  no)  warn "dsm auth:   a SynoToken was required (vue build selected; 7.2-only)" ;;
  *)   if [ "${PROBED}" -eq 1 ]; then
         warn "dsm auth:   inconclusive — see the probe output above"
       else
         note "dsm auth:   not probed in this run"
       fi ;;
esac
if [ "${INSTALLED}" = "yes" ]; then
  ok "installed:  yes — open DSM → main menu → Terminal"
else
  note "installed:  no"
fi
[ -n "${LOG_FILE}" ] && note "transcript: ${LOG_FILE}"

if [ "${COOKIE_ONLY_OK}" = "no" ] && [ "${UI_STYLE}" = "vue" ]; then
  printf '\n'
  warn "A token was required, but the vue wrapper needs DSM 7.2."
  note "If this DSM is 7.1, the ExtJS wrapper (docs/dsm-integration.md §5.3) is"
  note "needed instead — send the transcript above and it can be added."
fi

step "done"
