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
for candidate in \
  /usr/syno/etc/nginx/conf.d/synoterm.conf \
  /etc/nginx/conf.d/synoterm.conf \
  /usr/local/etc/nginx/conf.d/synoterm.conf \
  /etc/nginx/sites-enabled/synoterm.conf
do
  if [ -f "${candidate}" ]; then
    echo "==> removing ${candidate}"
    rm -f "${candidate}"
    removed=1
  fi
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
