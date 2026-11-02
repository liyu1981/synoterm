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
# Safety: it never rewrites DSM's nginx.conf silently. It either drops a
# `location` file into a directory nginx already includes *inside a server
# block*, or it prints the two-line edit for you to apply. Every change is
# validated with `nginx -t` and rolled back if nginx rejects it.
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
MARK_BEGIN="# >>> synoterm: managed block, do not edit >>>"
MARK_END="# <<< synoterm <<<"

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
  if ! nginx -t 2>/tmp/synoterm-nginx-test.log; then
    echo "error: nginx rejected the configuration:" >&2
    sed 's/^/    /' /tmp/synoterm-nginx-test.log >&2
    return 1
  fi
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

TARGET_DIR=""
TARGET_NAME=""
for spec in $(server_include_specs); do
  dir="${spec%/*}"
  base="${spec##*/}"
  case "${base}" in
    *"*"*) candidate="${base%%\**}${PKG_NAME}${base#*\*}" ;;
    *) continue ;;  # a fixed filename we must not hijack
  esac
  [ -d "${dir}" ] || continue
  TARGET_DIR="${dir}"
  TARGET_NAME="${candidate}"
  break
done

copy_snippet() { # copy_snippet <destination>
  install -m 644 "${SNIPPET}" "$1"
  echo "==> installed $1"
}

if [ -n "${TARGET_DIR}" ]; then
  # ---- 2a. the easy case: nginx already includes a server-level directory ----
  DEST="${TARGET_DIR}/${TARGET_NAME}"
  copy_snippet "${DEST}"
  if ! verify_nginx; then
    rm -f "${DEST}"
    echo "the snippet was removed again; DSM's configuration is unchanged." >&2
    exit 1
  fi
  if reload_nginx; then echo "    nginx reloaded"; else
    echo "warn: reload it yourself: synosystemctl restart nginx" >&2
    exit 1
  fi
else
  # ---- 2b. otherwise: write a stable include file and print the edit ---------
  mkdir -p "${INCLUDE_DIR}"
  copy_snippet "${INCLUDE_FILE}"
  cat <<EOF

nginx has no server-level include directory on this DSM build, so one line has
to be added to ${NGINX_CONF} by hand (sudo, once):

  1. back it up:
       cp ${NGINX_CONF} ${BACKUP_DIR}/nginx.conf.bak.\$(date +%s)

  2. inside every server { } block that listens on 5000 or 5001, add:

       include ${INCLUDE_FILE};

     (e.g. right after the "listen" line; nano/vim: search for "listen 5000")

  3. validate and reload:

       nginx -t && synosystemctl restart nginx

If nginx -t fails, restore the backup and restart nginx — DSM's UI is safe.

EOF
  if verify_nginx; then :; fi
  echo "The snippet itself is ready at: ${INCLUDE_FILE}"
  echo "(nothing else was changed)"
  exit 0
fi

# ---- 3. verify the backend and the mount -----------------------------------
sleep 1
if command -v curl >/dev/null 2>&1; then
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/healthz" || true)"
  echo "    backend http://127.0.0.1:${PORT}/healthz -> ${code}"
  code2="$(curl -sk -o /dev/null -w '%{http_code}' "https://127.0.0.1:5001/${PKG_NAME}/healthz" || true)"
  echo "    mount   https://127.0.0.1:5001/${PKG_NAME}/healthz -> ${code2}"
fi

echo
echo "done. Open DSM → main menu → Terminal."
echo "Log:        /var/packages/synoterm/var/runtime/synoterm.log"
echo "Undo:       ${PKG_DIR}/contrib/uninstall-nginx-mount.sh"
