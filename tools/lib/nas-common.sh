#!/usr/bin/env bash
# Shared plumbing for the NAS scripts (sourced, not executed).
#
# Expects the caller to have set: ROOT, NAS, SSH_USER, SSH_PORT, DSM_PORT,
# DSM_USER and the flags DRY_RUN, YES, VERBOSE, TRACE, LOG_FILE.
# Sets on demand: TARGET, SSH_OPTS, SCP_OPTS, CONTROL_PATH, REMOTE_DIR, ARCH,
# ZIG_TARGET, OS_MIN_VER, COOKIE_HEADER, DSM_TOKEN, DSM_SID, LOGGED_IN.

# ------------------------------------------------------------------ output --
bold() { printf '\033[1m%s\033[0m\n' "$*"; }
step() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
ok() { printf '  \033[32mok\033[0m   %s\n' "$*"; }
warn() { printf '  \033[33mwarn\033[0m %s\n' "$*"; }
fail() { printf '  \033[31mfail\033[0m %s\n' "$*"; }
note() { printf '       %s\n' "$*"; }
die() {
  printf '\n\033[31m%s\033[0m\n' "$*" >&2
  exit 1
}

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

trace() { # goes to stderr so command substitution stays clean
  [ "${VERBOSE}" -eq 1 ] || return 0
  printf '  \033[2m+ %s\033[0m\n' "$(printf '%s' "$1" | redact)" >&2
}

why() {
  [ "${VERBOSE}" -eq 1 ] || return 0
  printf '       \033[2m%s\033[0m\n' "$*" >&2
}

confirm() {
  [ "${YES}" -eq 1 ] && return 0
  printf '\n  \033[1m%s\033[0m [y/N] ' "$1"
  read -r answer || return 1
  case "${answer}" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# -------------------------------------------------------------------- init --
nas_init() { # nas_init <script-label>
  local label="$1"

  TARGET="${SSH_USER}@${NAS}"
  # One SSH connection for the whole run: DSM asks for the password once.
  CONTROL_PATH="${TMPDIR:-/tmp}/synoterm-ssh-%r@%h-%p"
  SSH_OPTS=(-p "${SSH_PORT}" -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new
            -o ControlMaster=auto -o ControlPath="${CONTROL_PATH}" -o ControlPersist=600)
  SCP_OPTS=(-P "${SSH_PORT}" -o ControlMaster=auto -o ControlPath="${CONTROL_PATH}" -o ControlPersist=600)

  # Never use /tmp for payloads: DSM's sshd may use PrivateTmp, so every
  # ssh/scp call would see a different /tmp.
  REMOTE_DIR=""

  mkdir -p "${ROOT}/build"

  # Defaults for values filled in by later steps (the scripts run with -u).
  : "${COOKIE_ARG:=}" "${COOKIE_HEADER:=}" "${DSM_TOKEN:=}" "${DSM_SID:=}" "${DSM_LOGGED_OUT:=0}" "${LOGGED_IN:=0}"
  : "${NAS_UNAME:=}" "${MODEL:=}" "${VERSION_LINE:=}" "${PROBED:=0}" "${COOKIE_ONLY_OK:=unknown}"

  if [ "${TRACE}" -eq 1 ]; then
    PS4='  \033[2m[trace] +${LINENO}: \033[0m'
    set -x
  fi

  if [ -n "${LOG_FILE}" ]; then
    mkdir -p "$(dirname "${LOG_FILE}")"
    exec > >(tee -a "${LOG_FILE}") 2>&1
    {
      printf '\n===== synoterm %s %s =====\n' "${label}" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
      printf 'args: %s\n' "$(printf '%s ' "$0" "${ORIGINAL_ARGS[@]:-}" | redact)"
      printf 'this machine: %s\n' "$(uname -sm 2>/dev/null)"
    } >>"${LOG_FILE}"
    note "transcript (secrets redacted): ${LOG_FILE}"
  fi

  trap nas_cleanup EXIT
}

nas_cleanup() {
  if [ "${LOGGED_IN:-0}" -eq 1 ] && [ "${DSM_LOGGED_OUT:-0}" -eq 0 ] &&
     [ "${DRY_RUN}" -eq 0 ] && [ -n "${DSM_SID:-}" ]; then
    printf '%s\n' "url = \"https://${NAS}:${DSM_PORT}/webapi/auth.cgi\"
data-urlencode = \"api=SYNO.API.Auth\"
data-urlencode = \"version=6\"
data-urlencode = \"method=logout\"
data-urlencode = \"session=Synoterm\"
data-urlencode = \"_sid=${DSM_SID}\"" | curl -sS -k --max-time 8 --config - >/dev/null 2>&1 || true
  fi
  if [ -n "${LOG_FILE}" ] && [ -f "${LOG_FILE}" ]; then
    local esc
    esc=$(printf '\033')
    sed -e "s/${esc}\[[0-9;]*m//g" -e 's/\([?&]t=\)[A-Za-z0-9._-]*/\1********/g' \
      "${LOG_FILE}" >"${LOG_FILE}.tmp" 2>/dev/null &&
      mv "${LOG_FILE}.tmp" "${LOG_FILE}" || rm -f "${LOG_FILE}.tmp"
  fi
  [ "${DRY_RUN}" -eq 1 ] && return 0
  [ -n "${REMOTE_DIR:-}" ] && on_nas "rm -rf '${REMOTE_DIR}'" >/dev/null 2>&1 || true
  ssh "${SSH_OPTS[@]}" -O exit "${TARGET}" >/dev/null 2>&1 || true
}

# ------------------------------------------------------------------- shell --
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

# A non-interactive `sh -c` over SSH gets a minimal PATH: DSM's own tools
# (synopkg, synonginx, ...) live in /usr/syno/bin and must be added explicitly.
DSM_PATH="/usr/syno/bin:/usr/syno/sbin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# GNU tar can pin entry mtimes; the NAS clock may be a second or two behind ours,
# and otherwise every streamed file prints "time stamp … is … s in the future".
TAR_MTIME=""
if tar --version 2>/dev/null | grep -q 'GNU tar'; then
  TAR_MTIME="--mtime=@0 --owner=0 --group=0"
fi

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
  trace "ssh -t ${TARGET} \"sudo sh -c 'export PATH=${DSM_PATH}; $(sq "$1")'\""
  ssh -t "${SSH_OPTS[@]}" "${TARGET}" "sudo sh -c 'export PATH=${DSM_PATH}; $(sq "$1")'"
  local status=$?
  [ "${status}" -eq 0 ] || printf '  \033[2m<- exit %s\033[0m\n' "${status}" >&2
  return "${status}"
}

run_bundle() { # run_bundle "<remote command>" <local-file>[:name] ... (one ssh session)
  local remote_cmd="$1"
  shift
  local staging names=() spec src name
  staging="$(mktemp -d)" || return 1
  for spec in "$@"; do
    case "${spec}" in
      *:*) src="${spec%%:*}"; name="${spec#*:}" ;;
      *) src="${spec}"; name="$(basename "${spec}")" ;;
    esac
    cp "${src}" "${staging}/${name}" || {
      rm -rf "${staging}"
      return 1
    }
    # Fixed mtime: the NAS clock may differ from ours, and tar warns about
    # timestamps "in the future" for every file it streams.
    touch -t 197001010000.00 "${staging}/${name}" 2>/dev/null || true
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

copy_to_nas() { # <local-file> <remote-absolute-path>; streamed over the exec channel
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
  local status=$?
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
  (cd "${local_dir}" && tar -czf - ${TAR_MTIME} .) | ssh "${SSH_OPTS[@]}" "${TARGET}" \
    "mkdir -p '${remote_dir}' && tar -xzf - -C '${remote_dir}'"
  local status=$?
  [ "${status}" -eq 0 ] || printf '  \033[2m<- exit %s\033[0m\n' "${status}" >&2
  return "${status}"
}

# ------------------------------------------------------------------ detect --
nas_detect() {
  local un version_line model build_info
  un="$(read_nas 'uname -m' 2>/dev/null | tr -d '\r')" || die "cannot reach ${TARGET} over SSH"
  [ -n "${un}" ] || die "could not read the architecture from ${NAS}"
  model="$(read_nas 'cat /proc/sys/kernel/syno_hw_version 2>/dev/null' | tr -d '\r')"

  # One round-trip, and no bare "." (a failing special builtin aborts dash-like
  # shells, which is how /etc/VERSION used to come back empty off-DSM).
  version_line="$(read_nas 'if [ -r /etc/VERSION ]; then . /etc/VERSION; fi; echo "${productversion:-?}|${majorversion:-7}|${minorversion:-1}|${buildnumber:-}"' | tr -d '\r')"

  local productversion="" major="7" minor="1"
  IFS='|' read -r productversion major minor build <<<"${version_line}"
  [ -n "${productversion}" ] || productversion="unknown"
  [ -n "${major}" ] || major="7"
  [ -n "${minor}" ] || minor="1"
  local version_text
  if [ -n "${build}" ]; then
    version_text="${productversion} build ${build}"
  else
    version_text="unknown (no /etc/VERSION)"
  fi

  case "${ARCH_OVERRIDE:-${un}}" in
    x86_64|amd64) ARCH=x86_64; ZIG_TARGET="x86_64-linux-musl" ;;
    aarch64|armv8l|arm64) ARCH=armv8; ZIG_TARGET="aarch64-linux-musl" ;;
    armv7l|armv7) ARCH=armv7; ZIG_TARGET="arm-linux-musleabihf" ;;
    *) die "unsupported architecture '${un}'" ;;
  esac
  ok "nas:   ${NAS} (model ${model:-unknown})"
  ok "dsm:   ${version_text}"
  NAS_UNAME="${un}"
  VERSION_LINE="${version_text}"
  ok "arch:  ${un} -> spk arch '${ARCH}'"

  MODEL="${model:-}"
  DSM_MAJOR_MINOR="${major}.${minor}"
  DSM_BUILD="${build}"
  OS_MIN_VER="7.1-42661"
  case "${DSM_BUILD}" in
    ''|*[!0-9]*) warn "could not read the DSM build number; assuming os_min_ver=${OS_MIN_VER}" ;;
    *)
      if [ "${DSM_BUILD}" -lt 42661 ]; then
        OS_MIN_VER="${DSM_MAJOR_MINOR}-${DSM_BUILD}"
        warn "DSM build ${DSM_BUILD} is older than 42661 — building with os_min_ver=${OS_MIN_VER}"
      else
        ok "DSM build ${DSM_BUILD} satisfies os_min_ver=${OS_MIN_VER}"
      fi
      ;;
  esac
}

# --------------------------------------------------------------- work dir --
nas_ensure_workdir() {
  local home real candidates candidate
  home="$(read_nas 'printf %s "$HOME"')"
  [ -n "${home}" ] || die "could not read \$HOME on the NAS"
  why "Remote \$HOME: ${home}"

  real="$(read_nas 'readlink -f "$HOME" 2>/dev/null' || true)"
  if [ -n "${REMOTE_DIR_ARG}" ]; then
    candidates="${REMOTE_DIR_ARG}"
  else
    candidates="${home}/.synoterm-test"
    if [ -n "${real}" ] && [ "${real}" != "${home}" ]; then
      why "\$HOME is a symlink: ${home} -> ${real}"
      candidates="${candidates}
${real}/.synoterm-test"
    fi
    candidates="${candidates}
${home}"
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
}

# ------------------------------------------------------------- DSM session --
nas_dsm_login() {
  DSM_PASS=""
  DSM_OTP=""
  DSM_SID=""
  DSM_TOKEN=""
  COOKIE_HEADER=""
  LOGGED_IN=0

  if [ -n "${COOKIE_ARG}" ]; then
    COOKIE_HEADER="${COOKIE_ARG}"
    ok "using the supplied Cookie header"
    return 0
  fi

  printf '  DSM account [%s]: ' "${DSM_USER}"
  read -r input_user || true
  [ -n "${input_user:-}" ] && DSM_USER="${input_user}"
  printf '  DSM password for %s (not echoed): ' "${DSM_USER}"
  read -rs DSM_PASS || true
  printf '\n'
  printf '  2FA code, empty if unused: '
  read -r DSM_OTP || true

  local curl_config login_body
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
    return 0
  fi

  fail "DSM login failed"
  case "${login_body}" in
    *"Could not connect"*|*"Connection refused"*|*"timed out"*|*"curl: (7)"*|*"curl: (28)"*)
      note "cannot reach https://${NAS}:${DSM_PORT} — wrong port, or DSM HTTPS disabled" ;;
    *) note "response: $(printf '%s' "${login_body}" | tr -d '\n' | head -c 300)" ;;
  esac
  note "fallback: paste the Cookie header from the logged-in DSM tab"
  printf '  Cookie header (or empty to abort): '
  local pasted
  read -r pasted || true
  [ -n "${pasted:-}" ] || die "no DSM session available"
  case "${pasted}" in
    *=*) COOKIE_HEADER="${pasted}" ;;
    *) COOKIE_HEADER="id=${pasted}" ;;
  esac
}

nas_dsm_logout() {
  [ "${LOGGED_IN}" -eq 1 ] || return 0
  [ "${DRY_RUN}" -eq 1 ] && return 0
  trace "curl https://${NAS}:${DSM_PORT}/webapi/auth.cgi (method=logout)"
  printf '%s\n' "url = \"https://${NAS}:${DSM_PORT}/webapi/auth.cgi\"
data-urlencode = \"api=SYNO.API.Auth\"
data-urlencode = \"version=6\"
data-urlencode = \"method=logout\"
data-urlencode = \"session=Synoterm\"
data-urlencode = \"_sid=${DSM_SID}\"" | curl -sS -k --max-time 10 --config - >/dev/null 2>&1
  DSM_LOGGED_OUT=1
}

# ------------------------------------------------------------------ build --
nas_build_number() {
  local n
  # A dirty tree means "still iterating": DSM refuses to reinstall the same
  # version, so use a value that changes on every run instead.
  if [ -n "$(git -C "${ROOT}" status --porcelain 2>/dev/null)" ]; then
    date +%y%m%d%H%M
    return
  fi
  n="$(git -C "${ROOT}" rev-list --count HEAD 2>/dev/null || true)"
  case "${n}" in
    ''|*[!0-9]*) n="$(date +%y%m%d%H%M)" ;;
  esac
  echo "${n}"
}

nas_build_spk() { # nas_build_spk <ui-style> ; sets SPK_VERSION, SPK_FILE
  local ui_style="$1" build_number
  build_number="$(nas_build_number)"
  # Distinct feature numbers per flavour, so switching flavour is an upgrade.
  case "${ui_style}" in
    extjs) SPK_VERSION="0.1.0-${build_number}" ;;
    vue)   SPK_VERSION="0.1.1-${build_number}" ;;
    *)     SPK_VERSION="0.1.2-${build_number}" ;;
  esac
  SPK_FILE="${ROOT}/build/synoterm-${SPK_VERSION}-${ARCH}.spk"

  note "building ${SPK_VERSION} for ${ARCH} (os_min_ver=${OS_MIN_VER}, ui=${ui_style})…"
  trace "SYNOTERM_OS_MIN_VER=${OS_MIN_VER} SYNOTERM_UI_STYLE=${ui_style} tools/build-spk.sh ${ARCH} ${SPK_VERSION}"
  (cd "${ROOT}" && SYNOTERM_OS_MIN_VER="${OS_MIN_VER}" SYNOTERM_UI_STYLE="${ui_style}" \
    ./tools/build-spk.sh "${ARCH}" "${SPK_VERSION}" >/dev/null) || die "package build failed"
  ok "package: $(basename "${SPK_FILE}") ($(du -h "${SPK_FILE}" | cut -f1))"
  (cd "${ROOT}" && ./tools/verify-spk.sh "${SPK_FILE}" | tail -n 3 | sed 's/^/  /')
}

# ---------------------------------------------------------------- install --
nas_install_spk() { # nas_install_spk <spk-file>
  local spk_file="$1" remote_spk
  remote_spk="${REMOTE_DIR}/$(basename "${spk_file}")"

  copy_to_nas "${spk_file}" "${remote_spk}" || die "cannot copy the package to the NAS"
  if [ "${DRY_RUN}" -eq 0 ] && ! read_nas "test -s '${remote_spk}'" 2>/dev/null; then
    fail "the package file is not visible to a new ssh session on this NAS"
    note "install it by hand instead: DSM → Package Center → Manual Install"
    die "install skipped"
  fi
  ok "package uploaded and visible to the installer"

  local synopkg="/usr/syno/bin/synopkg"
  if ! read_nas "test -x '${synopkg}'" 2>/dev/null; then
    synopkg="$(read_nas 'command -v synopkg 2>/dev/null' | tr -d '\r')"
  fi
  if [ -z "${synopkg}" ]; then
    fail "this DSM has no 'synopkg' binary"
    note "install the built package manually: DSM → Package Center → Manual Install"
    note "  ${spk_file}"
    return 1
  fi
  ok "installer: ${synopkg}"

  local install_out install_status
  install_out="$(on_nas_root "${synopkg} install '${remote_spk}'" 2>&1)"
  install_status=$?
  printf '%s\n' "${install_out}" | sed 's/^/  /'
  if [ "${install_status}" -eq 0 ] && ! printf '%s' "${install_out}" | grep -q '"success":false'; then
    ok "package install command succeeded"
  else
    case "${install_out}" in
      *"non-synology-signed package should not use internal worker"*|*'"code":320'*)
        # DSM 7 blocks unsigned packages on the CLI ("internal worker") by
        # design; Package Center is the *external* worker and does allow them.
        fail "DSM refuses CLI installs of unsigned packages (error 320)"
        note "this is a DSM 7 platform restriction, not a problem with the .spk:"
        note "  synopkg is the 'internal worker' and only accepts Synology-signed packages"
        note ""
        note "install it once through the desktop UI instead:"
        note "  1. Package Center → Settings → General → Trust Level →"
        note "     \"Synology Inc. and trusted publishers\" → allow any publisher"
        note "  2. Package Center → Manual Install → choose"
        note "       $(basename "${spk_file}")   (in ${ROOT}/build)"
        note "  3. re-run:  tools/nas-install.sh ${NAS} --user ${SSH_USER} --verify-only"
        return 1
        ;;
      *)
        case "${install_status}" in
          127) fail "could not execute ${synopkg}" ;;
          *) warn "the installer reported an error — read its output above" ;;
        esac
        note "common causes: Package Center trust level still blocks unsigned"
        note "packages, or an older version is installed (uninstall first)"
        return 1
        ;;
    esac
  fi
  on_nas "rm -f '${remote_spk}'"
}

nas_verify_install() { # nas_verify_install [end-to-end-ws-probe]
  local probe="${1:-yes}"

  if [ "${DRY_RUN}" -eq 1 ]; then
    note "[dry-run] would check synopkg status, setuid mode, nginx mount, listener and /healthz"
    return 0
  fi
  if ! read_nas 'test -d /var/packages/synoterm' 2>/dev/null; then
    warn "package directory /var/packages/synoterm is missing — the install did not complete"
    note "usual cause: Package Center trust level still blocks unsigned packages"
    return 1
  fi

  on_nas "echo '  synopkg status:'; synopkg status synoterm 2>&1 | sed 's/^/    /'"
  on_nas "echo '  setuid tool:'; ls -l /var/packages/synoterm/target/bin/synoterm 2>&1 | sed 's/^/    /'"
  on_nas "echo '  nginx mount files:'; grep -rl synoterm /etc/nginx/ 2>/dev/null | sed 's/^/    /' || echo '    (none found)'"
  on_nas "echo '  loopback listener:'; netstat -ltn 2>/dev/null | grep -w 7381 | sed 's/^/    /' || echo '    (nothing on 7381)'"
  on_nas "echo '  server log:'; tail -n 5 /var/packages/synoterm/var/runtime/synoterm.log 2>&1 | sed 's/^/    /'"
  warn "the setuid line must start with -rwsr-x--- root package"

  # Default package: no DSM worker, the terminal listens on its own port.
  local health
  health="$(curl -sS --max-time 8 "http://${NAS}:7381/healthz" 2>&1 || true)"
  case "${health}" in
    *'"ok":true'*) ok "installed server answers http://${NAS}:7381/healthz: $(printf '%s' "${health}" | tr -d '\n')" ;;
    "")
      warn "the installed server does not answer on port 7381"
      note "check the log above; a firewall rule may be blocking the port:"
      note "  Control Panel → Security → Firewall → allow TCP 7381 from your LAN"
      ;;
    *)
      # Fall back to the proxied path in case this build uses the nginx mount.
      local proxied
      proxied="$(curl -sS -k --max-time 8 "https://${NAS}:${DSM_PORT}/synoterm/healthz" 2>&1 || true)"
      case "${proxied}" in
        *'"ok":true'*) ok "installed server answers /synoterm/healthz: $(printf '%s' "${proxied}" | tr -d '\n')" ;;
        *) warn "could not verify the installed build: $(printf '%s' "${health}" | head -c 200)" ;;
      esac
      ;;
  esac

  on_nas "echo '  package info:'; cat /var/packages/synoterm/INFO 2>/dev/null | head -n 4 | sed 's/^/    /' || true"

  if [ "${probe}" = "yes" ] && [ -n "${COOKIE_HEADER:-}" ]; then
    # Same request the browser makes: DSM-served page on :5000 → terminal on
    # :7381 of the same host, carrying the (host-scoped) DSM cookie + token.
    trace "node tools/ws-test.mjs ws://${NAS}:7381/ws --cookie id=******** --token … --origin http://${NAS}:${DSM_PORT}"
    (cd "${ROOT}" && node tools/ws-test.mjs "ws://${NAS}:7381/ws" \
      --cookie "${COOKIE_HEADER}" ${DSM_TOKEN:+--token "${DSM_TOKEN}"} \
      --origin "http://${NAS}:${DSM_PORT}" \
      --expect SYNOTERM_DSM_OK --timeout 15) ||
      warn "end-to-end probe failed — the HTTP status hint above says why"
  fi
}
