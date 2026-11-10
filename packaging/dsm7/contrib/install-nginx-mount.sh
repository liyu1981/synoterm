#!/bin/sh
# One-time, root-only: mount the synoterm WebSocket on DSM's own web server.
#
#   sudo /var/packages/synoterm/target/contrib/install-nginx-mount.sh
#
# Why a manual step: DSM 7 only lets Synology-signed packages use its package
# framework's *internal workers*, and the same-origin nginx mount is one of them
# (an unsigned package is refused with error 320, "non-synology-signed package
# should not use internal worker"). This does what that worker would have done,
# from your own root shell instead.
#
# What it does:
#   1. dumps the *effective* configuration once (`nginx -T`: nginx.conf plus
#      every included file) and asks only the server { } blocks that listen on
#      the DSM ports which `include …*.conf;` patterns they load;
#   2. installs the snippet into the matching directories, named after the
#      pattern (dsm.*.conf -> /etc/nginx/conf.d/dsm.synoterm.conf), so one file
#      covers both the :5000 HTTP and the :5001 HTTPS vhost. A copy nginx
#      rejects (duplicate location, wrong context) is removed again at once and
#      nginx's own error is printed;
#   3. reloads nginx and probes /synoterm/healthz on every vhost. A vhost that
#      serves DSM (`/webman/`) but not the mount is listed with the include
#      patterns *its* server block loads;
#   4. exits non-zero unless every DSM vhost answers, so "installed" can never be
#      mistaken for "working".
#
# It never rewrites DSM's nginx.conf.
#
# Undo: uninstall-nginx-mount.sh
set -eu

PKG_NAME="synoterm"

PKG_DIR="${SYNOTERM_PKG_DIR:-/var/packages/synoterm/target}"
SNIPPET="${PKG_DIR}/contrib/nginx/synoterm.conf"
NGINX_BIN="${SYNOTERM_NGINX:-nginx}"
NGINX_CONF="${SYNOTERM_NGINX_CONF:-/etc/nginx/nginx.conf}"
# Where DSM keeps the per-vhost `location` snippets of its own apps. The name
# must match the include pattern nginx uses there: `include conf.d/dsm.*.conf;`
# loads dsm.synoterm.conf and ignores a bare synoterm.conf.
INCLUDE_DIR="${SYNOTERM_INCLUDE_DIR:-/etc/nginx/conf.d}"
INCLUDE_FILE="${INCLUDE_DIR}/dsm.synoterm.conf"
BACKUP_DIR="${SYNOTERM_BACKUP_DIR:-/etc/nginx}"
# nginx resolves a relative `include` against its prefix — normally the
# directory holding nginx.conf (`include conf.d/dsm.*.conf;`).
NGINX_PREFIX="${SYNOTERM_NGINX_PREFIX:-$(dirname "${NGINX_CONF}")}"
# The vhosts the DSM desktop is opened on (used to pick the right include).
DSM_PORTS="${SYNOTERM_DSM_PORTS:-5000 5001}"
PORT="${SYNOTERM_PORT:-7381}"

# Fallbacks for a build whose config cannot be attributed to a port; used only
# when the effective config mentions the pattern and the directory exists.
KNOWN_INCLUDE_DIRS="/etc/nginx/conf.d
${NGINX_PREFIX}/conf.d
/usr/syno/share/nginx/conf.d
/usr/syno/etc/nginx/conf.d
/usr/local/etc/nginx/conf.d"
KNOWN_INCLUDE_PATTERNS="dsm.*.conf www.*.conf"

if [ "$(id -u)" != "0" ]; then
  echo "error: run this as root (sudo $0)" >&2
  exit 1
fi
if [ ! -r "${SNIPPET}" ]; then
  echo "error: ${SNIPPET} not found — is the synoterm package installed?" >&2
  exit 1
fi
if ! command -v "${NGINX_BIN}" >/dev/null 2>&1; then
  echo "error: ${NGINX_BIN} not found in PATH" >&2
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/synoterm-mount.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT INT TERM HUP

reload_nginx() {
  if command -v synosystemctl >/dev/null 2>&1; then synosystemctl restart nginx && return 0; fi
  if command -v systemctl >/dev/null 2>&1; then systemctl restart nginx && return 0; fi
  "${NGINX_BIN}" -s reload && return 0
  return 1
}

nginx_error() { # the first emerg line nginx reports, one line
  "${NGINX_BIN}" -t 2>&1 | sed -n 's/^nginx: \[emerg\] //p' | head -n 1
}

nginx_ok() { "${NGINX_BIN}" -t >/dev/null 2>&1; }

# ---- 1. the effective configuration ----------------------------------------
# Parsing nginx.conf alone is not enough: DSM keeps its server blocks (and the
# include lines inside them) in files that are included, so the only reliable
# view is `nginx -T`. Dumped to a file once, so every later call — including
# the ones inside $( ) subshells — sees exactly the same text.
CONFIG_DUMP="${WORK}/effective.conf"
if ! "${NGINX_BIN}" -T >"${CONFIG_DUMP}" 2>/dev/null || [ ! -s "${CONFIG_DUMP}" ]; then
  cp "${NGINX_CONF}" "${CONFIG_DUMP}" 2>/dev/null || : >"${CONFIG_DUMP}"
fi

# Include patterns loaded by the server { } blocks that listen on <port>.
block_includes() { # block_includes <port>
  PORT="$1" awk '
    function emit() {
      if (want) for (i = 1; i <= npat; i++) print pat[i]
      npat = 0; want = 0
    }
    BEGIN { in_server = 0; depth = 0; npat = 0; want = 0; port = ENVIRON["PORT"] }
    /^[[:space:]]*#/ { next }
    {
      line = $0
      if (!in_server && line ~ /^[[:space:]]*server[[:space:]]*\{/) {
        in_server = 1; depth = 1; npat = 0; want = 0
        next
      }
      if (!in_server) next
      n = gsub(/\{/, "{", line)
      m = gsub(/\}/, "}", line)
      if (line ~ /^[[:space:]]*listen[[:space:]]/ && line ~ ("[^0-9]" port "[^0-9]")) want = 1
      if (line ~ /^[[:space:]]*include[[:space:]]+[^;]*\*[^;]*;/) {
        inc = line
        sub(/^[[:space:]]*include[[:space:]]+/, "", inc)
        sub(/;.*/, "", inc)
        gsub(/"/, "", inc)          # include "conf.d/dsm.*.conf";
        pat[++npat] = inc
      }
      depth += n - m
      if (depth <= 0) { emit(); in_server = 0 }
    }
    END { if (in_server) emit() }
  ' "${CONFIG_DUMP}" | awk '!seen[$0]++'
}

# Every vhost nginx serves: "<port> <scheme>".
server_listens() {
  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*listen[[:space:]]/ {
      line = $0
      sub(/^[[:space:]]*listen[[:space:]]+/, "", line)
      sub(/;.*/, "", line)
      port = ""; scheme = "http"
      n = split(line, a, /[[:space:]]+/)
      for (i = 1; i <= n; i++) {
        if (a[i] ~ /^[0-9]+$/) port = a[i]
        if (a[i] == "ssl") scheme = "https"
      }
      if (port != "") print port, scheme
    }
  ' "${CONFIG_DUMP}" | sort -u
}

# Include patterns of the top-level file (fallback when no server block could be
# attributed to a DSM port).
file_include_specs() {
  [ -r "${NGINX_CONF}" ] || return 0
  awk '
    /^[[:space:]]*#/ { next }
    {
      line = $0
      n = gsub(/\{/, "{", line)
      m = gsub(/\}/, "}", line)
      if ($0 ~ /^[[:space:]]*server[[:space:]]*\{/) in_server = 1
      if (in_server && $0 ~ /^[[:space:]]*include[[:space:]]+[^;]*\*[^;]*;/) {
        inc = $0
        sub(/^[[:space:]]*include[[:space:]]+/, "", inc)
        sub(/;.*/, "", inc)
        gsub(/"/, "", inc)
        print inc
      }
      depth += n - m
    }
  ' "${NGINX_CONF}" | sort -u
}

resolve_include_dir() { # resolve_include_dir <directory from an include line>
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    "") printf '%s\n' "${NGINX_PREFIX}" ;;
    *) printf '%s\n' "${NGINX_PREFIX}/$1" ;;
  esac
}

config_mentions() { grep -qF "$1" "${CONFIG_DUMP}"; }

# ---- 2. what each DSM vhost loads -----------------------------------------
echo "    DSM ports: ${DSM_PORTS}"
for port in ${DSM_PORTS}; do
  patterns="$(block_includes "${port}" | tr '\n' ' ')"
  printf '    :%-4s    includes: %s\n' "${port}" "${patterns:- (none)}"
done

# ---- 3. where a file of ours would actually be loaded ---------------------
# What the DSM vhosts load is authoritative: an include that sits at http level
# (or in a Web Station vhost) accepts a `location` file but never defines
# /synoterm/ for the DSM desktop. Only when nothing can be attributed to the DSM
# ports do the top-level file and the documented defaults get a say.
SPECS="${WORK}/specs"
: >"${SPECS}"
for port in ${DSM_PORTS}; do
  block_includes "${port}" >>"${SPECS}"
done
if [ ! -s "${SPECS}" ]; then
  file_include_specs >>"${SPECS}"
  for dir in ${KNOWN_INCLUDE_DIRS}; do
    [ -d "${dir}" ] || continue
    for pattern in ${KNOWN_INCLUDE_PATTERNS}; do
      config_mentions "${pattern}" && printf '%s/%s\n' "${dir}" "${pattern}" >>"${SPECS}"
    done
  done
fi

RESOLVED="${WORK}/resolved"
: >"${RESOLVED}"
while IFS= read -r spec; do
  [ -n "${spec}" ] || continue
  printf '%s/%s\n' "$(resolve_include_dir "${spec%/*}")" "${spec##*/}" >>"${RESOLVED}"
done <"${SPECS}"

CANDIDATES="${WORK}/candidates"
# Preference: /etc/nginx/conf.d first (where DSM keeps its per-app conf), then
# the share directory, then anything else; `dsm.*.conf` before other patterns.
awk -v etcconf="${INCLUDE_DIR}/" '
  {
    line = $0
    if (seen[line]++) next
    rank = 2
    if (index(line, etcconf) == 1) rank = 0
    else if (index(line, "/usr/syno/share/nginx/conf.d/") == 1) rank = 1
    if (line !~ /\/dsm\./) rank += 3
    printf "%d %s\n", rank, line
  }
' "${RESOLVED}" | sort -n | sed 's/^[0-9][0-9]* //' >"${CANDIDATES}"

if [ -s "${CANDIDATES}" ]; then
  echo "    candidates: $(tr '\n' ' ' <"${CANDIDATES}")"
else
  echo "    candidates: (none — no server block for ${DSM_PORTS} loads a *.conf pattern)"
fi

# A file in one of those directories that matches no include pattern is dead
# weight — the classic case being /etc/nginx/conf.d/synoterm.conf, which DSM
# never loads. Say so instead of letting it look installed.
warn_about_unused_copies() {
  for dir in ${KNOWN_INCLUDE_DIRS}; do
    [ -d "${dir}" ] || continue
    for stale in "${dir}"/*synoterm*.conf; do
      [ -f "${stale}" ] || continue
      case "${stale##*/}" in
        dsm.*|www.*) continue ;;  # matches a pattern nginx may include
      esac
      echo "warn: ${stale} is not matched by any include pattern nginx loads" >&2
      echo "      (it must be named dsm.*.conf / www.*.conf to be picked up) — delete it:" >&2
      echo "          rm ${stale}" >&2
    done
  done
}

# ---- 4. install -----------------------------------------------------------
INSTALLED=""

warn_about_unused_copies
NEEDS_INCLUDE=0
while IFS= read -r spec; do
  [ -n "${spec}" ] || continue
  dir="${spec%/*}"
  base="${spec##*/}"
  [ -d "${dir}" ] || continue
  case "${base}" in
    *"*"*) dest="${dir}/${base%%\**}${PKG_NAME}${base#*\*}" ;;
    *"${PKG_NAME}"*) dest="${dir}/${base}" ;;  # a fixed name that is ours
    *) continue ;;                              # a fixed name we must not hijack
  esac
  case " ${INSTALLED} " in *" ${dest} "*) continue ;; esac
  if ! cp "${SNIPPET}" "${dest}"; then
    echo "    cannot write ${dest}" >&2
    continue
  fi
  chmod 644 "${dest}" 2>/dev/null || true
  if nginx_ok; then
    echo "==> installed ${dest}"
    INSTALLED="${INSTALLED} ${dest}"
  else
    reason="$(nginx_error)"
    rm -f "${dest}"
    echo "    tried ${dest} — removed: ${reason:-nginx rejected it}" >&2
  fi
done <"${CANDIDATES}"

if [ -z "${INSTALLED}" ]; then
  # ---- 4b. nothing to hook into: ship the file, print the edit --------------
  mkdir -p "${INCLUDE_DIR}"
  cp "${SNIPPET}" "${INCLUDE_FILE}"
  chmod 644 "${INCLUDE_FILE}" 2>/dev/null || true
  echo "==> installed ${INCLUDE_FILE}"
  INSTALLED="${INCLUDE_FILE}"
  NEEDS_INCLUDE=1
  if ! nginx_ok; then
    reason="$(nginx_error)"
    rm -f "${INCLUDE_FILE}"
    echo "error: nginx rejected the configuration: ${reason}" >&2
    echo "the snippet was removed again; DSM's configuration is unchanged." >&2
    exit 1
  fi
fi

echo "    nginx -t: ok"

if [ "${NEEDS_INCLUDE}" -eq 1 ]; then
  cat <<EOF

The DSM vhosts load none of the include patterns this script can write into, so
one line has to be added to ${NGINX_CONF} by hand (sudo, once) — inside *every*
server { } block that serves the DSM desktop, i.e. the :5000 HTTP one and the
:5001 HTTPS one (they are separate blocks, and a location included by only one
of them 404s on the other):

       include ${INCLUDE_FILE};

  What the DSM vhosts load today:
$(for p in ${DSM_PORTS}; do
  printf '       :%s -> %s\n' "${p}" "$(block_includes "${p}" | tr '\n' ' ' | sed 's/ *$//')"
done)

  1. back it up:
       cp ${NGINX_CONF} ${BACKUP_DIR}/nginx.conf.bak.\$(date +%s)

  2. add the include line inside those server blocks
     (nano/vim: search for "listen 5000" and "listen 5001")

  3. validate and reload:
       nginx -t && synosystemctl restart nginx

If nginx -t fails, restore the backup and restart nginx — DSM's UI is safe.

EOF
  echo "The snippet itself is ready at: ${INCLUDE_FILE}"
  echo "(nginx was not reloaded and its configuration is unchanged)"
  exit 0
fi

if reload_nginx; then echo "    nginx reloaded"; else
  echo "warn: reload it yourself: synosystemctl restart nginx" >&2
fi

# ---- 5. verify every vhost ------------------------------------------------
fetch_code() { # fetch_code <scheme> <port> <path>
  if [ "${1}" = "https" ]; then
    curl -sk -o /dev/null -w '%{http_code}' --max-time 3 "https://127.0.0.1:${2}${3}" 2>/dev/null || true
  else
    curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${2}${3}" 2>/dev/null || true
  fi
}

sleep 1
if ! command -v curl >/dev/null 2>&1; then
  echo "warn: curl not found, cannot verify the mount" >&2
  exit 0
fi

backend="$(fetch_code http "${PORT}" "/${PKG_NAME}/healthz")"
echo "    backend   http://127.0.0.1:${PORT}/${PKG_NAME}/healthz -> ${backend:-?}"

listens="$(server_listens)"
[ -n "${listens}" ] || listens="$(for p in ${DSM_PORTS}; do printf '%s http\n' "${p}"; done)"

good=""
bad=""
dsm_seen=0
echo "    mount     per vhost:"
while read -r port scheme; do
  [ -n "${port}" ] || continue
  code="$(fetch_code "${scheme}" "${port}" "/${PKG_NAME}/healthz")"
  # Only vhosts that serve DSM itself (webman) must also serve the mount;
  # other listeners on this nginx (Web Station, portal aliases) are not.
  dsm="$(fetch_code "${scheme}" "${port}" "/webman/")"
  note=""
  case "${dsm}" in
    000|404) note=" (not a DSM vhost)" ;;
    *) dsm_seen=1 ;;
  esac
  printf '              %-5s %s://127.0.0.1:%s/%s/healthz -> %s%s\n' \
    "${scheme}" "${scheme}" "${port}" "${PKG_NAME}" "${code:-?}" "${note}"
  case "${code}" in
    200) good="${good} ${scheme}:${port}" ;;
    *)
      case "${dsm}" in
        000|404) ;;
        *) bad="${bad} ${scheme}:${port}" ;;
      esac
      ;;
  esac
done <<EOF
${listens}
EOF

if [ -z "${good}" ]; then
  cat <<EOF >&2

error: no nginx vhost serves /${PKG_NAME}/, so the mount is not in use anywhere.
       The snippet is installed at: ${INSTALLED}
       Remove it with ${PKG_DIR}/contrib/uninstall-nginx-mount.sh
EOF
  exit 1
fi

if [ "${dsm_seen}" -eq 0 ]; then
  echo "warn: no vhost answered /webman/, so the DSM desktop vhost could not be" >&2
  echo "      identified; the mount is only confirmed on:${good}" >&2
fi

if [ -n "${bad}" ]; then
  cat <<EOF >&2

warn: DSM answers on these vhosts but /${PKG_NAME}/ is still 404 there:${bad}
EOF
  reported=""
  for entry in ${bad}; do
    port="${entry##*:}"
    case " ${reported} " in *" ${port} "*) continue ;; esac
    reported="${reported} ${port}"
    patterns="$(block_includes "${port}" | tr '\n' ' ' | sed 's/ *$//')"
    if [ -n "${patterns}" ]; then
      printf '      :%s loads: %s\n' "${port}" "${patterns}"
      printf '      Install the snippet where one of them points, or add inside that\n'
      printf '      server { } block:   include %s;\n' "${INSTALLED%% *}"
    else
      printf '      :%s loads no *.conf pattern at all — add inside its server { } block:\n' "${port}"
      printf '          include %s;\n' "${INSTALLED%% *}"
      printf '          nginx -t && synosystemctl restart nginx\n'
    fi
  done
  printf '\n'
  exit 1
fi

case "${backend}" in
  200) ;;
  *)
    echo "warn: the backend does not answer under /${PKG_NAME}/ — is the service running," >&2
    echo "      and is it the current build?  synopkg status synoterm" >&2
    ;;
esac

conf_file="${PKG_DIR}/../var/etc/synoterm.conf"
if [ -r "${conf_file}" ] && grep -q '^BIND=.*auto' "${conf_file}"; then
  echo
  echo "    note: BIND=\"auto\" — restart the service so it stops listening on 0.0.0.0"
  echo "          now that the mount exists:  synopkg restart synoterm"
fi

echo
echo "done. Open DSM → main menu → Terminal."
echo "Log:        /var/packages/synoterm/var/runtime/synoterm.log"
echo "Undo:       ${PKG_DIR}/contrib/uninstall-nginx-mount.sh"
