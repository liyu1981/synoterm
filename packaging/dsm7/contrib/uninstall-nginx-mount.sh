#!/bin/sh
# Removes the manual nginx mount added by install-nginx-mount.sh.
#
#   sudo /var/packages/synoterm/target/contrib/uninstall-nginx-mount.sh
set -eu

if [ "$(id -u)" != "0" ]; then
  echo "error: run this as root (sudo $0)" >&2
  exit 1
fi

removed=0
# The installer names the file after the include pattern DSM uses there (e.g.
# www.*.conf → www.synoterm.conf), so match the pattern, not one fixed name.
for dir in \
  /etc/nginx/conf.d \
  /usr/syno/share/nginx/conf.d \
  /usr/syno/etc/nginx/conf.d \
  /usr/local/etc/nginx/conf.d \
  /etc/nginx/sites-enabled
do
  [ -d "${dir}" ] || continue
  for candidate in "${dir}"/*synoterm*.conf; do
    [ -f "${candidate}" ] || continue
    echo "==> removing ${candidate}"
    rm -f "${candidate}"
    removed=1
  done
done

[ "${removed}" -eq 1 ] || echo "nothing to remove (no synoterm.conf found)"

if command -v nginx >/dev/null 2>&1 && command -v nginx >/dev/null 2>&1; then
  nginx -t >/dev/null 2>&1 || echo "warn: nginx -t still reports a problem" >&2
fi

if command -v synosystemctl >/dev/null 2>&1; then
  synosystemctl restart nginx && echo "    nginx restarted"
elif command -v systemctl >/dev/null 2>&1; then
  systemctl restart nginx && echo "    nginx restarted"
elif command -v nginx >/dev/null 2>&1; then
  nginx -s reload && echo "    nginx reloaded"
else
  echo "warn: reload nginx yourself: synosystemctl restart nginx" >&2
fi

echo "done."
