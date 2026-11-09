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
#   1. drops a `location` file into every directory nginx already includes
#      *inside a server block* (so both the :5000 HTTP and the :5001 HTTPS
#      vhost get it), or, if there is no such directory, writes a stable file
#      and prints the include line to add by hand;
#   2. validates with `nginx -t` and removes the file again if nginx rejects it;
#   3. probes /synoterm/healthz on *every* vhost nginx serves and names the ones
#      that still answer 404 instead of declaring success blindly.
#
# It never rewrites DSM's nginx.conf.
#
# Undo: uninstall-nginx-mount.sh
set -eu

PKG_DIR="${SYNOTERM_PKG_DIR:-/var/packages/synoterm/target}"
SNIPPET="${PKG_DIR}/contrib/nginx/synoterm.conf"
NGINX_CONF="${SYNOTERM_NGINX_CONF:-/etc/nginx/nginx.conf}"
INCLUDE_DIR="/usr/local/etc/nginx/conf.d"
INCLUDE_FILE="${INCLUDE_DIR}/synoterm.conf"
BACKUP_DIR="/usr/local/etc/nginx"
PORT="${SYNOTERM_PORT:-7381}"

PKG_NAME="synoterm"

if [ "$(id -u)" != "0" ]; then
  echo "error: run this as root (sudo $0)" >&2
  exit 1
fi
if [ ! -r "${SNIPPET}" ]; then
  echo "error: ${SNIPPET} not found — is the synoterm package installed?" >&2
  exit 1
fi
if ! command -v nginx >/dev/null 2>&1; then
  echo "error: nginx not found in PATH" >&2
  exit 1
fi

reload_nginx() {
  if command -v synosystemctl >/dev/null 2>&1; then synosystemctl restart nginx && return 0; fi
  if command -v systemctl >/dev/null 2>&1; then systemctl restart nginx && return 0; fi
  nginx -s reload && return 0
  return 1
}

verify_nginx() {
  local log
  log="$(mktemp "${TMPDIR:-/tmp}/synoterm-nginx.XXXXXX")"
  if ! nginx -t 2>"${log}"; then
    echo "error: nginx rejected the configuration:" >&2
    sed 's/^/    /' "${log}" >&2
    rm -f "${log}"
    return 1
  fi
  rm -f "${log}"
  echo "    nginx -t: ok"
  return 0
}

# ---- 1. include patterns nginx uses inside a `server { }` block -------------
# A bare `location` block is only valid inside a server block, so those are the
# only places we can safely drop the snippet — and the file name must match the
# pattern DSM uses there (e.g. "www.*.conf").
server_include_specs() {
  [ -r "${NGINX_CONF}" ] || return 0
  awk '
    /^[[:space:]]*#/ { next }
    {
      line = $0
      # count braces to know whether we are inside http{} / server{}
      n = gsub(/\{/, "{", line)
      m = gsub(/\}/, "}", line)
      if ($0 ~ /^[[:space:]]*server[[:space:]]*\{/) { in_server = 1 }
      if (in_server && $0 ~ /^[[:space:]]*include[[:space:]]+[^;]*\*[^;]*;/) {
        inc = $0
        sub(/^[[:space:]]*include[[:space:]]+/, "", inc)
        sub(/;.*/, "", inc)
        print inc
      }
      depth += n - m
      if (in_server && depth <= 0) { in_server = 0 }
    }
  ' "${NGINX_CONF}" | sort -u
}

# ---- 2. install the snippet into every server-level include directory ------
# DSM's nginx has several `server { }` blocks (the :5000 HTTP one, the :5001
# HTTPS one, …). A location that is only included by one of them 404s on the
# others, so the snippet goes into every server-level include directory found —
# and section 4 proves each vhost actually answers.
INSTALLED=""
copy_snippet() { # copy_snippet <destination>
  install -m 644 "${SNIPPET}" "$1"
  echo "==> installed $1"
}

for spec in $(server_include_specs); do
  dir="${spec%/*}"
  base="${spec##*/}"
  case "${base}" in
    *"*"*) ;;
    *) continue ;;  # a fixed filename we must not hijack
  esac
  [ -d "${dir}" ] || continue
  dest="${dir}/${base%%\**}${PKG_NAME}${base#*\*}"
  case " ${INSTALLED} " in *" ${dest} "*) continue ;; esac
  copy_snippet "${dest}"
  INSTALLED="${INSTALLED} ${dest}"
done

rollback() {
  local file
  for file in ${INSTALLED}; do
    rm -f "${file}"
    echo "    removed ${file} again" >&2
  done
}

NEEDS_INCLUDE=0
if [ -z "${INSTALLED}" ]; then
  # ---- 2b. no server-level include dir: ship the file, print the edit -------
  mkdir -p "${INCLUDE_DIR}"
  copy_snippet "${INCLUDE_FILE}"
  INSTALLED="${INCLUDE_FILE}"
  NEEDS_INCLUDE=1
fi

if ! verify_nginx; then
  rollback
  echo "DSM's configuration is unchanged." >&2
  exit 1
fi

if [ "${NEEDS_INCLUDE}" -eq 1 ]; then
  cat <<EOF

nginx has no server-level include directory on this DSM build, so one line has
to be added to ${NGINX_CONF} by hand (sudo, once) — inside *every* server { }
block that serves the DSM desktop, i.e. the :5000 HTTP one and the :5001 HTTPS
one (they are separate blocks, and a location included by only one of them
404s on the other):

       include ${INCLUDE_FILE};

  1. back it up:
       cp ${NGINX_CONF} ${BACKUP_DIR}/nginx.conf.bak.\$(date +%s)

  2. add the include line inside those server blocks
     (nano/vim: search for "listen 5000" and "listen 5001")

  3. validate and reload:
       nginx -t && synosystemctl restart nginx

If nginx -t fails, restore the backup and restart nginx — DSM's UI is safe.

EOF
  echo "The snippet itself is ready at: ${INCLUDE_FILE}"
  echo "(nothing else was changed)"
  exit 0
fi

if reload_nginx; then echo "    nginx reloaded"; else
  echo "warn: reload it yourself: synosystemctl restart nginx" >&2
fi

# ---- 3. every vhost nginx serves, from its own configuration ---------------
server_listens() { # prints "<port> <scheme>" for each listen directive
  [ -r "${NGINX_CONF}" ] || return 0
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
  ' "${NGINX_CONF}" | sort -u
}

fetch_code() { # fetch_code <scheme> <port> <path>
  if [ "${1}" = "https" ]; then
    curl -sk -o /dev/null -w '%{http_code}' --max-time 3 "https://127.0.0.1:${2}${3}" 2>/dev/null || true
  else
    curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${2}${3}" 2>/dev/null || true
  fi
}

# ---- 4. verify the backend and the mount on every vhost -------------------
sleep 1
if ! command -v curl >/dev/null 2>&1; then
  echo "warn: curl not found, cannot verify the mount" >&2
  exit 0
fi

backend="$(fetch_code http "${PORT}" "/${PKG_NAME}/healthz")"
echo "    backend http://127.0.0.1:${PORT}/${PKG_NAME}/healthz -> ${backend:-?}"

listens="$(server_listens)"
[ -n "${listens}" ] || listens="5000 http
5001 https"

good=""
bad=""
echo "    mount   per vhost:"
while read -r port scheme; do
  [ -n "${port}" ] || continue
  code="$(fetch_code "${scheme}" "${port}" "/${PKG_NAME}/healthz")"
  # Only vhosts that serve DSM itself (webman) must also serve the mount;
  # other listeners on this nginx are not our business.
  dsm="$(fetch_code "${scheme}" "${port}" "/webman/")"
  note=""
  case "${dsm}" in
    000|404) note=" (not a DSM vhost)" ;;
  esac
  printf '            %-5s %s://127.0.0.1:%s/%s/healthz -> %s%s\n' \
    "${scheme}" "${scheme}" "${port}" "${PKG_NAME}" "${code:-?}" "${note}"
  case "${code}" in
    200) good="${good} ${scheme}:${port}" ;;
    *)
      case "${dsm}" in
        000|404) ;;  # a vhost that does not serve DSM: ignore
        *) bad="${bad} ${scheme}:${port}" ;;
      esac
      ;;
  esac
done <<EOF
${listens}
EOF

snippet_file="$(printf '%s' "${INSTALLED}" | awk '{print $1}')"

if [ -z "${good}" ]; then
  cat <<EOF >&2

error: no nginx vhost serves /${PKG_NAME}/. The snippet is installed, but the
vhost that serves the DSM desktop does not include it. Add this line inside
that server { } block in ${NGINX_CONF}, before the closing brace:

       include ${snippet_file};

Then reload and re-run this script:
       nginx -t && synosystemctl restart nginx
       ${PKG_DIR}/contrib/diagnose.sh

EOF
  exit 1
fi

if [ -n "${bad}" ]; then
  cat <<EOF >&2

warn: DSM answers on these vhosts but /${PKG_NAME}/ is still 404 there:${bad}
      Those server { } blocks have no include of the snippet, so a browser that
      opened DSM on that port falls back to the package's own port. Add this
      line inside each of them and reload:

          include ${snippet_file};

          nginx -t && synosystemctl restart nginx

EOF
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
