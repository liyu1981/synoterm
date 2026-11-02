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
# Needs on this machine: ssh, curl, node (for the WebSocket probe), tar.
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
REMOTE_DIR_ARG=""
SMOKE_PORT="7382"
SMOKE_BIND="0.0.0.0"
COOKIE_ONLY_OK="unknown"
PROBED=0
DSM_LOGGED_OUT=0
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
  --remote-dir <path> directory on the NAS for temporary files (default: $HOME/.synoterm-test)
  --smoke-port <port> port for the smoke-test server (default: 7382)
  --loopback          bind the smoke-test server to 127.0.0.1 instead of 0.0.0.0
                      (only useful if you test from an SSH tunnel yourself)
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
    --remote-dir) REMOTE_DIR_ARG="${2:?}"; shift 2 ;;
    --smoke-port) SMOKE_PORT="${2:?}"; shift 2 ;;
    --loopback) SMOKE_BIND="127.0.0.1"; shift ;;
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
# Reuse one SSH connection for the whole run: DSM asks for the password once
# instead of on every ssh/scp call.
CONTROL_PATH="${TMPDIR:-/tmp}/synoterm-ssh-%r@%h-%p"
SSH_OPTS=(-p "${SSH_PORT}" -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new
          -o ControlMaster=auto -o ControlPath="${CONTROL_PATH}" -o ControlPersist=600)
SCP_OPTS=(-P "${SSH_PORT}" -o ControlMaster=auto -o ControlPath="${CONTROL_PATH}" -o ControlPersist=600)

# NEVER use /tmp for the payload: DSM's sshd runs with PrivateTmp, so every
# ssh/scp call sees a different /tmp. The work dir goes in the login user's
# home directory instead (resolved in step 2).
REMOTE_DIR=""

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
    -e 's/(Cookie: )[^"]*/\1********/g' \
    -e 's/(--dev-token )[^ ]*/\1********/g' \
    -e 's/([?&]t=)[^ &"]*/\1********/g'
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

run_bundle() { # run_bundle "<remote command>" <local-file> [...] ; all in ONE ssh session
  # Streams the files as a tar over stdin and runs the command in the same
  # session, so nothing depends on files being visible to a *later* ssh/scp
  # session (DSM's sftp subsystem and PrivateTmp can differ).
  local remote_cmd="$1"; shift
  local staging
  staging="$(mktemp -d)" || return 1
  local names=()
  local spec src name
  for spec in "$@"; do
    case "${spec}" in
      *:*) src="${spec%%:*}"; name="${spec#*:}" ;;
      *)   src="${spec}"; name="$(basename "${spec}")" ;;
    esac
    cp "${src}" "${staging}/${name}" || { rm -rf "${staging}"; return 1; }
    names+=("${name}")
  done
  trace "tar -cf - ${names[*]} | ssh ${TARGET} 'cd \$(mktemp -d) && tar -xf - && ${remote_cmd}'"
  tar -cf - -C "${staging}" "${names[@]}" | ssh "${SSH_OPTS[@]}" "${TARGET}" \
    "d=\$(mktemp -d) && cd \"\$d\" && tar -xf - && chmod 700 . 2>/dev/null; ${remote_cmd}; rc=\$?; cd /; rm -rf \"\$d\"; exit \$rc"
  local status=$?
  rm -rf "${staging}"
  [ "${status}" -eq 0 ] || printf '  \033[2m<- exit %s\033[0m\n' "${status}" >&2
  return "${status}"
}

copy_to_nas() { # <local-file> <remote-absolute-path>
  # Uses the SSH exec channel (`cat > file`) instead of scp/sftp: DSM's sftp
  # subsystem can live in a different mount/session view than the login shell,
  # which is exactly the "scp: dest open: No such file or directory" failure
  # seen on real NASes. mkdir, write and rename all happen in one session.
  local local_file="$1" remote_path="$2" remote_dir
  remote_dir="$(dirname "${remote_path}")"
  if [ "${DRY_RUN}" -eq 1 ]; then
    printf '  \033[2m[dry-run] stream %s -> %s:%s\033[0m\n' "${local_file}" "${NAS}" "${remote_path}"
    return 0
  fi
  trace "ssh ${TARGET} \"cat > ${remote_path}\" < ${local_file}"
  ssh "${SSH_OPTS[@]}" "${TARGET}" \
    "mkdir -p '${remote_dir}' && cat > '${remote_path}.part' && mv -f '${remote_path}.part' '${remote_path}'" \
    <"${local_file}"
  status=$?
  [ "${status}" -eq 0 ] || printf '  \033[2m<- exit %s\033[0m\n' "${status}" >&2
  return "${status}"
}

copy_tree_to_nas() { # <local-dir> <remote-dir>
  local local_dir="$1" remote_dir="$2"
  if [ "${DRY_RUN}" -eq 1 ]; then
    printf '  \033[2m[dry-run] stream %s/ -> %s:%s\033[0m\n' "${local_dir}" "${NAS}" "${remote_dir}"
    return 0
  fi
  trace "tar -czf - -C ${local_dir} . | ssh ${TARGET} \"tar -xzf - -C ${remote_dir}\""
  ( cd "${local_dir}" && tar -czf - . ) | ssh "${SSH_OPTS[@]}" "${TARGET}" \
    "mkdir -p '${remote_dir}' && tar -xzf - -C '${remote_dir}'"
  status=$?
  [ "${status}" -eq 0 ] || printf '  \033[2m<- exit %s\033[0m\n' "${status}" >&2
  return "${status}"
}

cleanup() {
  if [ "${LOGGED_IN:-0}" -eq 1 ] && [ "${DSM_LOGGED_OUT:-0}" -eq 0 ] && [ "${DRY_RUN}" -eq 0 ] && [ -n "${DSM_SID:-}" ]; then
    printf '%s\n' "url = \"https://${NAS}:${DSM_PORT}/webapi/auth.cgi\"
data-urlencode = \"api=SYNO.API.Auth\"
data-urlencode = \"version=6\"
data-urlencode = \"method=logout\"
data-urlencode = \"session=Synoterm\"
data-urlencode = \"_sid=${DSM_SID}\"" | curl -sS -k --max-time 8 --config - >/dev/null 2>&1 || true
  fi
  if [ -n "${LOG_FILE}" ] && [ -f "${LOG_FILE}" ]; then
    esc=$(printf '\033')
    # strip ANSI, then mask the dev secret that the on-screen URL shows
    sed -e "s/${esc}\[[0-9;]*m//g" -e 's/\([?&]t=\)[A-Za-z0-9._-]*/\1********/g' \
      "${LOG_FILE}" > "${LOG_FILE}.tmp" 2>/dev/null \
      && mv "${LOG_FILE}.tmp" "${LOG_FILE}" || rm -f "${LOG_FILE}.tmp"
  fi
  [ "${DRY_RUN}" -eq 1 ] && return 0
  [ -n "${REMOTE_DIR}" ] && on_nas "rm -rf '${REMOTE_DIR}'" >/dev/null 2>&1 || true
  ssh "${SSH_OPTS[@]}" -O exit "${TARGET}" >/dev/null 2>&1 || true
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
REMOTE_HOME="$(read_nas 'printf %s "$HOME"')"
if [ -z "${REMOTE_HOME}" ]; then
  die "could not read \$HOME on the NAS"
fi
why "Remote \$HOME: ${REMOTE_HOME}"
why "Work dir goes there (not /tmp: DSM's sshd may use PrivateTmp, and scp/sftp"
why "may see a different view than the login shell)."

REMOTE_HOME_REAL="$(read_nas 'readlink -f "$HOME" 2>/dev/null' || true)"
if [ -n "${REMOTE_DIR_ARG}" ]; then
  candidates="${REMOTE_DIR_ARG}"
else
  candidates="${REMOTE_HOME}/.synoterm-test"
  if [ -n "${REMOTE_HOME_REAL}" ] && [ "${REMOTE_HOME_REAL}" != "${REMOTE_HOME}" ]; then
    why "\$HOME is a symlink: ${REMOTE_HOME} -> ${REMOTE_HOME_REAL}"
    candidates="${candidates}
${REMOTE_HOME_REAL}/.synoterm-test"
  fi
  candidates="${candidates}
${REMOTE_HOME}
${REMOTE_HOME}/synoterm-test"
fi

REMOTE_DIR=""
for candidate in ${candidates}; do
  if on_nas "mkdir -p '${candidate}' 2>/dev/null && : > '${candidate}/.write-test' 2>/dev/null && rm -f '${candidate}/.write-test' 2>/dev/null"; then
    REMOTE_DIR="${candidate}"
    break
  fi
done

if [ -z "${REMOTE_DIR}" ]; then
  fail "no writable directory on the NAS"
  on_nas 'echo "  id:   $(id)"; echo "  HOME: ${HOME}"; ls -ld "${HOME}" 2>&1 | sed "s/^/  ls:   /"; df -h "${HOME}" 2>&1 | sed "s/^/  df:   /"'
  die "tried:
    ${candidates}
  Use --remote-dir <path> to pick one yourself (it must be writable by ${SSH_USER})."
fi
ok "work dir: ${REMOTE_DIR}"

# The preflight is streamed and executed inside a single ssh session, so it
# cannot be affected by per-session /tmp or sftp-view differences.
if [ "${DRY_RUN}" -eq 1 ]; then
  note "[dry-run] would stream nas-preflight.sh and run it on the NAS"
else
  run_bundle "sh ./nas-preflight.sh" "${ROOT}/tools/nas-preflight.sh" 2>&1 | sed 's/^/  /'
  PREFLIGHT_STATUS=${PIPESTATUS[0]}
  [ "${PREFLIGHT_STATUS}" -eq 0 ] || warn "preflight reported problems (see FAIL lines above)"
fi

# Cross-session visibility check: this is the thing that broke 'scp' on DSM.
if [ "${DRY_RUN}" -eq 0 ]; then
  copy_to_nas "${ROOT}/tools/nas-auth-test.sh" "${REMOTE_DIR}/nas-auth-test.sh" \
    || die "cannot write to ${REMOTE_DIR} — check that ${REMOTE_HOME} is writable by ${SSH_USER}"
  if read_nas "test -s '${REMOTE_DIR}/nas-auth-test.sh'" 2>/dev/null; then
    ok "files written to ${REMOTE_DIR} are visible to later ssh sessions"
  else
    warn "a file written now is NOT visible to a later ssh session"
    note "the probe below still works (single session); the smoke test may not"
    printf '\n'
    note "diagnostics:"
    on_nas 'echo "  id:      $(id)"; echo "  HOME:    ${HOME}"; echo "  pwd:     $(pwd)"; ls -ld "${HOME}" 2>&1 | sed "s/^/  home:    /"; ls -ld "${HOME}/.synoterm-test" 2>&1 | sed "s/^/  workdir: /"; mount 2>/dev/null | grep -Ei "homes|/tmp" | sed "s/^/  mount:   /"' | sed 's/^/  /'
    printf '\n'
    note "workaround: pass --remote-dir with a path on a normal volume, e.g."
    note "  --remote-dir /volume1/homes/${SSH_USER}/.synoterm-test"
  fi
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
  # The script and the cookie are streamed as one tar and executed in the same
  # ssh session, so the cookie never touches the NAS filesystem for long and no
  # cross-session visibility is required.
  printf '\n'
  printf '%s\n%s\n' "${COOKIE_HEADER}" "${DSM_TOKEN}" > "${ROOT}/build/.cookie.$$"
  chmod 600 "${ROOT}/build/.cookie.$$"

  if [ "${DRY_RUN}" -eq 1 ]; then
    note "[dry-run] would stream nas-auth-test.sh + the session cookie and run the probe"
    probe_out=""
  else
    if [ "${TRACE}" -eq 1 ]; then probe_script="sh -x"; else probe_script="sh"; fi
    probe_out="$(run_bundle "${probe_script} ./nas-auth-test.sh --file ./cookie" \
      "${ROOT}/tools/nas-auth-test.sh" \
      "${ROOT}/build/.cookie.$$:cookie" 2>&1)"
    printf '%s\n' "${probe_out}" | sed 's/^/  /'
  fi
  rm -f "${ROOT}/build/.cookie.$$"

  if printf '%s' "${probe_out}" | grep -Eq 'cookie only[[:space:]]*->[[:space:]]*[^<[:space:]]'; then
    COOKIE_ONLY_OK="yes"
  elif printf '%s' "${probe_out}" | grep -q 'cookie only'; then
    COOKIE_ONLY_OK="no"
  else
    COOKIE_ONLY_OK="unknown"
  fi
  PROBED=1
  case "${COOKIE_ONLY_OK}" in
    yes) ok "cookie-only authentication works on this DSM" ;;
    no)  warn "cookie-only authentication did NOT return an account" ;;
    *)   warn "could not interpret the probe output above" ;;
  esac

  dsm_groups="$(read_nas "id -Gn '${DSM_USER}' 2>/dev/null" || true)"
  if [ -n "${dsm_groups}" ]; then
    why "DSM groups for ${DSM_USER}: ${dsm_groups}"
    case " ${dsm_groups} " in
      *" administrators "*) ok "${DSM_USER} is in administrators (required by the package)" ;;
      *) warn "${DSM_USER} is NOT in administrators — the terminal would answer 403"
         note "test anyway, or set REQUIRE_GROUP in \$SYNOPKG_PKGVAR/etc/synoterm.conf" ;;
    esac
  fi

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
  step "4/6  smoke test: the binary on the NAS (no install, no nginx change)"
  why "Runs the real binary on the NAS as your SSH user, listening on"
  why "${SMOKE_BIND}:${SMOKE_PORT}, so you can open the terminal from any machine."
  why "No SSH tunnel needed. Nothing is installed and DSM's nginx is untouched."

  if [ "${DRY_RUN}" -eq 1 ] || confirm "Copy the binary + UI to ${REMOTE_DIR} and run it as ${SSH_USER} on port 7382?"; then
    # Always build a *static musl* binary for the NAS in its own prefix.
    # Comparing only the ELF machine is not enough: a native `zig build` is
    # glibc-linked and dies on DSM with "GLIBC_2.xx not found".
    smoke_prefix="${ROOT}/build/smoke-${ARCH}"
    smoke_bin="${smoke_prefix}/bin/synoterm"
    note "building a static ${ZIG_TARGET} binary for the NAS…"
    trace "zig build -Doptimize=ReleaseSmall -Dtarget=${ZIG_TARGET} -p build/smoke-${ARCH}"
    ( cd "${ROOT}" && zig build -Doptimize=ReleaseSmall -Dtarget="${ZIG_TARGET}" -p "build/smoke-${ARCH}" ) \
      || die "zig build failed"
    if LC_ALL=C grep -qa 'GLIBC_2\.' "${smoke_bin}" 2>/dev/null; then
      die "${smoke_bin} still references glibc — expected a static musl build"
    fi
    ok "static binary: $(du -h "${smoke_bin}" | cut -f1)"

    if [ ! -f "${ROOT}/frontend/dist/index.html" ]; then
      note "building the frontend…"
      trace "cd ${ROOT}/frontend && npm run build"
      (cd "${ROOT}/frontend" && { [ -d node_modules ] || npm install --no-audit --no-fund >/dev/null; } && npm run build >/dev/null) || die "frontend build failed"
    fi

    smoke_ok=1
    copy_to_nas "${smoke_bin}" "${REMOTE_DIR}/synoterm" || smoke_ok=0
    copy_tree_to_nas "${ROOT}/frontend/dist" "${REMOTE_DIR}/web" || smoke_ok=0
    on_nas "chmod 755 '${REMOTE_DIR}/synoterm' 2>/dev/null"
    if [ "${smoke_ok}" -eq 0 ]; then
      fail "could not place the files on the NAS"
      note "try --remote-dir <path on a normal volume>, e.g. --remote-dir /volume1/homes/${SSH_USER}/.synoterm-test"
    elif ! read_nas "test -x '${REMOTE_DIR}/synoterm' && test -f '${REMOTE_DIR}/web/index.html'" 2>/dev/null; then
      fail "files written now are not visible to a new ssh session — smoke test skipped"
      note "this NAS has a per-session filesystem view; try --remote-dir <path>"
      smoke_ok=0
    fi

    if [ "${smoke_ok}" -eq 1 ]; then
      DEV_TOKEN="$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
      [ -n "${DEV_TOKEN}" ] || DEV_TOKEN="dev$(date +%s)$$"
      why "Dev server: no DSM auth, so a random shared secret is required."
      why "It runs in the foreground of a dedicated SSH connection that this"
      why "script keeps open: DSM kills background jobs when the login session"
      why "ends, which is why a 'nohup … &' server dies instantly."

      SMOKE_LOG="${ROOT}/build/.smoke-server.log"
      : >"${SMOKE_LOG}"
      trace "ssh ${TARGET} \"exec ./synoterm --listen ${SMOKE_PORT} --bind ${SMOKE_BIND} …\" &"
      ssh "${SSH_OPTS[@]}" "${TARGET}" \
        "cd '${REMOTE_DIR}' && HOME='${REMOTE_DIR}' exec ./synoterm \
           --listen ${SMOKE_PORT} --bind ${SMOKE_BIND} --auth dev \
           --dev-token '${DEV_TOKEN}' --web-root '${REMOTE_DIR}/web'" \
        </dev/null >"${SMOKE_LOG}" 2>&1 &
      SERVER_SSH_PID=$!

      SMOKE_URL="http://${NAS}:${SMOKE_PORT}/?t=${DEV_TOKEN}"
      SMOKE_WS="ws://${NAS}:${SMOKE_PORT}/ws"

      # Wait for the listener, from this machine (that also proves the LAN path).
      listening=0
      attempt=0
      while [ "${attempt}" -lt 40 ]; do
        if (exec 3<>"/dev/tcp/${NAS}/${SMOKE_PORT}") 2>/dev/null; then listening=1; break; fi
        kill -0 "${SERVER_SSH_PID}" 2>/dev/null || break
        attempt=$((attempt + 1))
        sleep 0.25
      done

      printf '\n'
      if [ "${listening}" -eq 1 ]; then
        ok "dev server reachable from this machine on port ${SMOKE_PORT}"
        if [ "${SMOKE_BIND}" = "0.0.0.0" ]; then
          bold "  Open this from any machine on your LAN:"
        else
          bold "  Open this (loopback only — tunnel it yourself):"
        fi
        bold "      ${SMOKE_URL}"
        printf '\n'
        warn "this dev server runs a shell as ${SSH_USER} and has no DSM login;"
        note "it is reachable from your network until this step stops it, and the"
        note "secret above is the only thing in front of it."
        printf '\n  Automated probe from this machine:\n'
        trace "node tools/ws-test.mjs ${SMOKE_WS} --dev-token <secret>"
        (cd "${ROOT}" && node tools/ws-test.mjs "${SMOKE_WS}" --dev-token "${DEV_TOKEN}" \
          --expect SYNOTERM_WS_OK --timeout 15) \
          || warn "probe failed — see the log below"
      else
        fail "the dev server did not start or is not reachable on port ${SMOKE_PORT}"
        printf '\n  server output:\n'
        sed 's/^/    /' "${SMOKE_LOG}" | tail -n 15
        printf '\n  diagnostics on the NAS:\n'
        on_nas "echo '  listeners:'; (ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep -w ${SMOKE_PORT} | sed 's/^/    /' || echo '    (nothing on ${SMOKE_PORT})'; echo '  local curl:'; (curl -sS -o /dev/null -w '    HTTP %{http_code}\\n' --max-time 3 'http://127.0.0.1:${SMOKE_PORT}/' 2>&1 || true) | sed 's/^/    /'" 2>&1 | sed 's/^/  /'
        note "if the listener exists but the LAN cannot reach it, DSM's firewall"
        note "(Control Panel → Security → Firewall) is blocking port ${SMOKE_PORT}."
      fi

      printf '\n  Press Enter when you are done with the browser terminal… '
      read -r _ || true
      kill "${SERVER_SSH_PID}" 2>/dev/null || true
      wait "${SERVER_SSH_PID}" 2>/dev/null || true
      on_nas "pkill -f '${REMOTE_DIR}/synoterm' 2>/dev/null; echo '  dev server stopped'"
      if [ -f "${SMOKE_LOG}" ]; then
        cp "${SMOKE_LOG}" "${ROOT}/build/smoke-server.log" 2>/dev/null || true
      fi
    fi
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
    REMOTE_SPK="${REMOTE_DIR}/$(basename "${SPK_FILE}")"
    copy_to_nas "${SPK_FILE}" "${REMOTE_SPK}" || die "cannot copy the package to the NAS"
    if on_nas_root "synopkg install '${REMOTE_SPK}'"; then
      ok "install command succeeded"
    else
      warn "synopkg reported an error — read the output above"
      note "common causes: trust level still blocks unsigned packages, or arch mismatch"
    fi
    on_nas "rm -f '${REMOTE_SPK}'"

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
      DSM_LOGGED_OUT=1
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
