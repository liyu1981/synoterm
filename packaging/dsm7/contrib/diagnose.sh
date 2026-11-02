#!/bin/sh
# One-shot diagnostic for synoterm. Run it on the NAS as root (or with sudo):
#
#   sudo /var/packages/synoterm/target/contrib/diagnose.sh
#
# It changes nothing. Paste the whole output when reporting a problem.
set -u

PKG=synoterm
DEST="/var/packages/${PKG}/target"
VAR="/var/packages/${PKG}/var"
PORT=7381

say() { printf '\n== %s\n' "$*"; }
run() { printf '  $ %s\n' "$*"; sh -c "$*" 2>&1 | sed 's/^/    /'; }

say "identity"
run 'id'
run '. /etc/VERSION 2>/dev/null && echo "DSM ${productversion:-?} build ${buildnumber:-?}"'

say "package"
run "ls -ld /var/packages/${PKG} 2>/dev/null || echo 'package directory missing'"
run "synopkg status ${PKG} 2>&1 || /usr/syno/bin/synopkg status ${PKG} 2>&1"
run "ls -l ${DEST}/bin/synoterm 2>&1"
run "cat ${DEST}/INFO 2>/dev/null | head -5"

say "service settings"
run "cat ${VAR}/etc/synoterm.conf 2>/dev/null | grep -v '^#' | grep -v '^$'"

say "listener"
run "netstat -ltnp 2>/dev/null | grep -w ${PORT} || echo 'nothing listening on ${PORT}'"
run "ss -ltnp 2>/dev/null | grep -w ${PORT} || true"

say "backend probe"
run "curl -sS --max-time 3 http://127.0.0.1:${PORT}/healthz || echo '127.0.0.1:${PORT} unreachable'"
LANIP=$(ip -4 -o addr show scope global 2>/dev/null | awk 'NR==1{split($4,a,"/"); print a[1]}')
if [ -n "${LANIP}" ]; then
  run "curl -sS --max-time 3 http://${LANIP}:${PORT}/healthz || echo '${LANIP}:${PORT} unreachable (firewall?)'"
fi

say "nginx mount"
run "ls -l /usr/local/etc/nginx/conf.d/*synoterm* /usr/syno/etc/nginx/conf.d/*synoterm* /etc/nginx/conf.d/*synoterm* 2>/dev/null || echo 'no snippet installed'"
run "grep -n synoterm /etc/nginx/nginx.conf 2>/dev/null || echo 'no include line in nginx.conf'"
run "nginx -t 2>&1 | tail -2"
if [ -n "${LANIP}" ]; then
  run "curl -s -o /dev/null -w 'mount http://${LANIP}:5000/${PKG}/healthz -> %{http_code}\n' --max-time 3 http://${LANIP}:5000/${PKG}/healthz"
fi

say "UI files"
run "ls -l ${DEST}/ui/config ${DEST}/ui/web/index.html 2>&1"
run "cat ${DEST}/ui/web/config.js 2>/dev/null"
run "ls -ld /usr/syno/synoman/webman/3rdparty/${PKG} 2>&1"

say "log (last 30 lines)"
run "tail -n 30 ${VAR}/runtime/synoterm.log 2>/dev/null || echo 'no log yet'"

say "package manager log (last 15, filtered)"
run "grep -i '${PKG}' /var/log/synopkg.log 2>/dev/null | tail -n 15 || echo 'nothing in /var/log/synopkg.log'"

say "done"
