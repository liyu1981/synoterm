#!/usr/bin/env bash
# synoterm — install on a Synology DSM 7.1+ NAS.
#
# Interactive: asks for your DSM account (used to verify the result) and your
# sudo password (DSM asks for it during the install). Everything it runs is
# printed, secrets are redacted, and it stops before changing anything.
#
#   tools/nas-install.sh 192.168.0.18
#   tools/nas-install.sh 192.168.0.18 --user yli
#   tools/nas-install.sh 192.168.0.18 --dry-run        # plan only
#   tools/nas-install.sh 192.168.0.18 --uninstall      # remove it again
#
# Steps
#   1  detect DSM version and architecture     (read-only)
#   2  preflight checks on the NAS             (read-only)
#   3  log in to DSM to verify the result      (session is logged out at the end)
#   4  build the .spk for the detected arch
#   5  install it (sudo)                       (changes DSM)
#   6  verify: status, setuid, nginx, /healthz, end-to-end terminal
#
set -uo pipefail

ORIGINAL_ARGS=("$@")

NAS=""
SSH_USER="admin"
SSH_PORT="22"
DSM_PORT="5001"
DSM_USER="admin"
DRY_RUN=0
YES=0
VERBOSE=1
TRACE=0
LOG_FILE=""
ARCH_OVERRIDE=""
REMOTE_DIR_ARG=""
COOKIE_ARG=""
UI_STYLE="url"
DO_UNINSTALL=0

usage() {
  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Options:
  --user <name>       SSH user (default: admin)
  --ssh-port <port>   SSH port (default: 22)
  --dsm-port <port>   DSM HTTPS port (default: 5001)
  --dsm-user <name>   DSM account for the verification login (default: admin)
  --arch <arch>       x86_64 | armv8 | armv7 (default: detect)
  --ui-style url|vue  desktop registration flavour (default: url, 7.1-safe)
  --cookie '<header>' use an existing Cookie header instead of logging in
  --remote-dir <path> directory on the NAS for the upload (default: $HOME/.synoterm-test)
  --uninstall         uninstall instead of installing
  --yes               do not ask for confirmation (still prints everything)
  --dry-run           print the plan, change nothing
  --quiet             do not print the commands being run
  --trace             also trace inside bash (set -x)
  --log <file>        append a shareable transcript (secrets redacted)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --user) SSH_USER="${2:?}"; shift 2 ;;
    --ssh-port) SSH_PORT="${2:?}"; shift 2 ;;
    --dsm-port) DSM_PORT="${2:?}"; shift 2 ;;
    --dsm-user) DSM_USER="${2:?}"; shift 2 ;;
    --arch) ARCH_OVERRIDE="${2:?}"; shift 2 ;;
    --ui-style) UI_STYLE="${2:?}"; shift 2 ;;
    --cookie) COOKIE_ARG="${2:?}"; shift 2 ;;
    --remote-dir) REMOTE_DIR_ARG="${2:?}"; shift 2 ;;
    --uninstall) DO_UNINSTALL=1; shift ;;
    --yes|-y) YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --quiet|-q) VERBOSE=0; shift ;;
    --trace) TRACE=1; VERBOSE=1; shift ;;
    --log) LOG_FILE="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) NAS="$1"; shift ;;
  esac
done
[ -n "${NAS}" ] || { usage >&2; exit 2; }
case "${UI_STYLE}" in url|vue) ;; *) echo "--ui-style must be url or vue" >&2; exit 2 ;; esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/nas-common.sh
. "${ROOT}/tools/lib/nas-common.sh"
nas_init "nas-install"

# ------------------------------------------------------------------ uninstall --
if [ "${DO_UNINSTALL}" -eq 1 ]; then
  step "uninstall"
  "${ROOT}/tools/nas-uninstall.sh" "${NAS}" --user "${SSH_USER}" --ssh-port "${SSH_PORT}" \
    $([ "${YES}" -eq 1 ] && echo --yes)
  exit $?
fi

# --------------------------------------------------------------- 1. detect --
step "1/6  detect DSM version and architecture"
why "Read-only SSH calls: uname, /etc/VERSION, the Synology model id."
why "The build number decides whether os_min_ver has to be lowered for your DSM."
nas_detect

# ------------------------------------------------------------ 2. preflight --
step "2/6  preflight (read-only)"
why "Runs a small script on the NAS; it only reads /etc/VERSION, binaries,"
why "/etc/nginx, netstat and /var/packages."
if [ "${DRY_RUN}" -eq 1 ]; then
  note "[dry-run] would stream nas-preflight.sh and run it on the NAS"
else
  run_bundle "sh ./nas-preflight.sh" "${ROOT}/tools/nas-preflight.sh" 2>&1 | sed 's/^/  /'
  status=${PIPESTATUS[0]}
  [ "${status}" -eq 0 ] || warn "preflight reported problems (see FAIL lines above)"
fi
nas_ensure_workdir

# --------------------------------------------------------------- 3. login --
step "3/6  DSM session (for the end-to-end check)"
why "Logs in to https://${NAS}:${DSM_PORT} the same way the browser does and"
why "logs the session out at the end. Your password goes through a pipe, never"
why "argv, and is never written anywhere."
why "DSM 7.1 needs both the session cookie and the SynoToken to identify the"
why "user, so the install is verified with exactly what the browser would send."
if [ "${DRY_RUN}" -eq 1 ]; then
  note "[dry-run] would prompt for the DSM password"
elif [ "${YES}" -eq 1 ] && [ -z "${COOKIE_ARG}" ]; then
  warn "--yes without --cookie: skipping the DSM login, so the end-to-end check is skipped"
else
  nas_dsm_login
  if [ -n "${DSM_SID:-}" ]; then
    groups="$(read_nas "id -Gn '${DSM_USER}' 2>/dev/null" || true)"
    [ -n "${groups}" ] && why "DSM groups for ${DSM_USER}: ${groups}"
    case " ${groups} " in
      *" administrators "*) ok "${DSM_USER} is in administrators (required by default)" ;;
      *) warn "${DSM_USER} is not in administrators — the terminal would answer 403"
         note "either add the account to administrators, or edit REQUIRE_GROUP in"
         note "\$SYNOPKG_PKGVAR/etc/synoterm.conf after installing" ;;
    esac
  fi
fi

# --------------------------------------------------------------- 4. build --
step "4/6  build the package"
why "A static musl binary for ${ARCH} plus the xterm.js bundle, in one .spk."
nas_build_spk "${UI_STYLE}"

# ------------------------------------------------------------- 5. install --
step "5/6  install (this changes DSM)"
why "Uploads the .spk and runs 'synopkg install' as root (sudo password needed)."
why "DSM unpacks the payload, applies the setuid tool privilege (4750), enables"
why "the nginx mount /synoterm/ and starts the service."
if confirm "Install $(basename "${SPK_FILE}") on ${NAS}?"; then
  nas_install_spk "${SPK_FILE}"
  step "5b/6  verify the installation"
  nas_verify_install yes
  nas_dsm_logout
  printf '\n'
  bold "Open DSM → main menu → Terminal."
  note "First load may ask nothing at all: the terminal runs as your DSM account."
  note "Inside the terminal check: id; pwd; stty size"
else
  note "skipped. The package was built at:"
  note "  ${SPK_FILE}"
  note "Install it later with the same command, or via Package Center → Manual Install."
fi

# --------------------------------------------------------------- 6. done ---
step "6/6  summary"
ok "nas:      ${NAS} (${MODEL:-unknown model}, ${ARCH})"
ok "package:  $(basename "${SPK_FILE}") (ui ${UI_STYLE}, os_min_ver ${OS_MIN_VER})"
if read_nas 'test -d /var/packages/synoterm' 2>/dev/null; then
  ok "installed: yes"
  note "logs:     /var/packages/synoterm/var/runtime/synoterm.log"
  note "settings: /var/packages/synoterm/var/etc/synoterm.conf (REQUIRE_GROUP, MAX_SESSIONS)"
  note "remove:   tools/nas-install.sh ${NAS} --uninstall"
else
  note "installed: no"
fi
[ -n "${LOG_FILE}" ] && note "transcript: ${LOG_FILE}"
step "done"
