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
run "cat /var/packages/${PKG}/INFO 2>/dev/null | head -5"

say "service settings"
run "cat ${VAR}/etc/synoterm.conf 2>/dev/null | grep -v '^#' | grep -v '^$'"

say "auth mode (AUTH=ssh needs the SSH service; AUTH=dsm needs the setuid tool)"
AUTH=$(grep -E '^AUTH=' "${VAR}/etc/synoterm.conf" 2>/dev/null | head -1 | tr -d '"' | cut -d= -f2)
[ -n "${AUTH}" ] || AUTH=ssh   # start-stop-status default
echo "  AUTH=${AUTH}"
if [ "${AUTH}" = "ssh" ]; then
  run "command -v ssh && ssh -V 2>&1"
  run "netstat -ltn 2>/dev/null | grep '[:.]22 ' || ss -ltn 2>/dev/null | grep '[:.]22 ' || echo 'nothing listening on 22 (SSH service off?)'"
  run "ls -ld ${VAR}/home/.ssh; ls -l ${VAR}/home/.ssh 2>/dev/null"
else
  run "ls -l ${DEST}/bin/synoterm"
fi

say "listener"
run "netstat -ltnp 2>/dev/null | grep -w ${PORT} || echo 'nothing listening on ${PORT}'"
run "ss -ltnp 2>/dev/null | grep -w ${PORT} || true"

say "backend probe"
# Every endpoint lives under BASE_PATH (default /synoterm; "" = proxy root) —
# behind the mount and on the package's own port alike.
BASE=$(grep -E '^BASE_PATH=' "${VAR}/etc/synoterm.conf" 2>/dev/null | head -1 | tr -d '"' | cut -d= -f2)
[ -n "${BASE}" ] || BASE=/synoterm
echo "  BASE_PATH=${BASE}"
run "curl -sS --max-time 3 http://127.0.0.1:${PORT}${BASE}/healthz || echo '127.0.0.1:${PORT}${BASE}/healthz unreachable'"
LANIP=$(ip -4 -o addr show scope global 2>/dev/null | awk 'NR==1{split($4,a,"/"); print a[1]}')
if [ -n "${LANIP}" ]; then
  run "curl -sS --max-time 3 http://${LANIP}:${PORT}${BASE}/healthz || echo '${LANIP}:${PORT}${BASE}/healthz unreachable (firewall?)'"
fi

say "nginx mount"
run "ls -l /etc/nginx/conf.d/*synoterm* /usr/syno/share/nginx/conf.d/*synoterm* /usr/syno/etc/nginx/conf.d/*synoterm* /usr/local/etc/nginx/conf.d/*synoterm* 2>/dev/null || echo 'no snippet installed'"
run "grep -n 'synoterm\|conf.d/dsm\.\*' /etc/nginx/nginx.conf 2>/dev/null || echo 'no include line in nginx.conf'"
run "nginx -t 2>&1 | tail -2"

say "mount per vhost"
# A location included by only one server { } block 404s on the others; that is
# the difference between "the mount is installed" and "the mount works where
# the browser actually is".
DSM_LISTENS=$(awk '
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
' /etc/nginx/nginx.conf 2>/dev/null | sort -u)
[ -n "${DSM_LISTENS}" ] || DSM_LISTENS="5000 http
5001 https"
printf '%s\n' "${DSM_LISTENS}" | while read -r port scheme; do
  [ -n "${port}" ] || continue
  if [ "${scheme}" = "https" ]; then
    run "curl -sk -o /dev/null -w 'https 127.0.0.1:${port}/${PKG}/healthz -> %{http_code}\n' --max-time 3 https://127.0.0.1:${port}/${PKG}/healthz"
  else
    run "curl -s -o /dev/null -w 'http  127.0.0.1:${port}/${PKG}/healthz -> %{http_code}\n' --max-time 3 http://127.0.0.1:${port}/${PKG}/healthz"
  fi
done
if [ -n "${LANIP}" ]; then
  run "curl -s -o /dev/null -w 'mount http://${LANIP}:5000${BASE}/healthz -> %{http_code}\n' --max-time 3 http://${LANIP}:5000${BASE}/healthz"
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
