#!/usr/bin/env bash
# synoterm — uninstall the package from the NAS and verify the cleanup.
#
#   tools/nas-uninstall.sh nas.local [--user admin] [--yes]
#
# Removes the package, then checks that DSM removed the nginx mount, the
# package directory and the loopback listener. Revert the Package Center trust
# level manually if you changed it for the test.
set -uo pipefail

NAS=""
SSH_USER="admin"
SSH_PORT="22"
YES=0

usage() {
  sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Options:
  --user <name>      SSH user (default: admin)
  --ssh-port <port>  SSH port (default: 22)
  --yes              do not ask for confirmation
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --user) SSH_USER="$2"; shift 2 ;;
    --ssh-port) SSH_PORT="$2"; shift 2 ;;
    --yes|-y) YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) NAS="$1"; shift ;;
  esac
done
[ -n "${NAS}" ] || { usage >&2; exit 2; }

TARGET="${SSH_USER}@${NAS}"
SSH_OPTS=(-p "${SSH_PORT}" -o ConnectTimeout=10)

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok() { printf '  \033[32mok\033[0m   %s\n' "$*"; }
warn() { printf '  \033[33mwarn\033[0m %s\n' "$*"; }

if [ "${YES}" -eq 0 ]; then
  warn "This stops all open terminal sessions and removes /var/packages/synoterm."
  printf '  Uninstall synoterm from %s? [y/N] ' "${NAS}"
  read -r answer
  case "${answer}" in y|Y|yes|YES) ;; *) echo "  aborted"; exit 1 ;; esac
fi

bold "== uninstall"
if ssh -t "${SSH_OPTS[@]}" "${TARGET}" 'sudo synopkg uninstall synoterm'; then
  ok "synopkg uninstall returned success"
else
  warn "synopkg reported an error (already removed?)"
fi

bold "== verification"
ssh "${SSH_OPTS[@]}" "${TARGET}" '
  echo "  nginx references:"
  found=0
  for f in /etc/nginx/nginx.conf /etc/nginx/conf.d/*.conf /etc/nginx/sites-enabled/*; do
    [ -f "$f" ] || continue
    if grep -q synoterm "$f" 2>/dev/null; then
      echo "    $f"
      found=1
    fi
  done
  [ "$found" -eq 0 ] && echo "    none"
  echo "  package directory:"
  if [ -d /var/packages/synoterm ]; then
    echo "    still present (reboot or re-run synopkg uninstall)"
  else
    echo "    gone"
  fi
  echo "  loopback listener:"
  if netstat -ltn 2>/dev/null | grep -qw 7381; then
    echo "    still listening on 7381"
  else
    echo "    nothing on 7381"
  fi
'

bold "== reminder"
printf '  Restore Package Center → Settings → General → Trust Level if you changed it\n'
printf '  for the test (default: "Synology Inc. and trusted publishers").\n'
