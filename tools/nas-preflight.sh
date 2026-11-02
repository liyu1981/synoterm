#!/bin/sh
# Read-only preflight for the M1 checklist. Changes nothing.
#
# Copy to the NAS and run there:
#   scp tools/nas-preflight.sh admin@nas:/tmp/ && ssh admin@nas 'sudo sh /tmp/nas-preflight.sh'
#
# Prints: DSM version/arch, the binaries synoterm depends on, whether
# authenticate.cgi is usable, whether the loopback port is free, and whether a
# synoterm package already exists.
set -u

PORT="${SYNOTERM_PORT:-7381}"
rc=0

say() { printf '%s\n' "$*"; }
ok() { printf '  ok    %s\n' "$*"; }
warn() { printf '  WARN  %s\n' "$*"; }
bad() { printf '  FAIL  %s\n' "$*"; rc=1; }

say "== identity"
if [ -r /etc/VERSION ]; then
  # majorversion="7" minorversion="1" buildnumber="42661" ...
  . /etc/VERSION 2>/dev/null || true
  say "  DSM ${majorversion:-?}.${minorversion:-?}-${buildnumber:-?} (productversion=${productversion:-?})"
else
  warn "/etc/VERSION not readable"
fi
say "  arch:   $(uname -m)"
model=$(cat /proc/sys/kernel/syno_hw_version 2>/dev/null || true)
[ -n "${model}" ] && say "  model:  ${model}"
say "  kernel: $(uname -r)"
say "  euid:   $(id -u) ($(id -un 2>/dev/null || echo '?'))"
[ "$(id -u)" = "0" ] || warn "run as root (sudo) for the authoritative checks below"

say "== minimum version gate"
# The SPK declares os_min_ver; a NAS older than that refuses manual install.
if [ -r /etc/VERSION ]; then
  . /etc/VERSION 2>/dev/null || true
  build="${buildnumber:-0}"
  if [ "${build:-0}" -lt 42661 ] 2>/dev/null; then
    warn "DSM build ${build} is older than 42661 — rebuild with SYNOTERM_OS_MIN_VER=${majorversion}.${minorversion}-${build}"
  else
    ok "build ${build} satisfies os_min_ver=7.1-42661"
  fi
fi

say "== account"
say "  user:   $(id -un)"
say "  uid:    $(id -u)"
groups_list="$(id -Gn 2>/dev/null || true)"
say "  groups: ${groups_list}"
case " ${groups_list} " in
  *" administrators "*) ok "member of administrators (required by default)" ;;
  *) warn "not in administrators — the terminal will be refused (403) unless --require-group is changed" ;;
esac
if command -v sudo >/dev/null 2>&1; then
  ok "sudo available: $(command -v sudo)"
else
  warn "sudo not found — package install/uninstall cannot run unattended"
fi

say "== required binaries"
for path in /usr/syno/synoman/webman/modules/authenticate.cgi \
            /usr/bin/id /bin/sh /bin/bash /usr/bin/nohup /usr/bin/tar; do
  if [ -x "${path}" ]; then
    ok "${path}"
  elif [ -e "${path}" ]; then
    warn "${path} exists but is not executable"
  else
    warn "${path} missing"
  fi
done

say "== authenticate.cgi"
cgi=/usr/syno/synoman/webman/modules/authenticate.cgi
if [ -x "${cgi}" ]; then
  say "  perms: $(ls -l "${cgi}" | awk '{print $1, $3, $4}')"
  # A no-session invocation must print nothing and exit non-zero or zero.
  out=$(env -i REQUEST_METHOD=GET GATEWAY_INTERFACE=CGI/1.1 PATH=/usr/syno/bin:/usr/bin:/bin \
        HTTP_COOKIE= REMOTE_ADDR=127.0.0.1 HTTP_HOST=localhost "${cgi}" 2>&1)
  status=$?
  if [ -z "${out}" ]; then
    ok "returns empty output without a session (exit ${status}) — as expected"
  else
    warn "returned '${out}' without a session (exit ${status}) — inspect before trusting"
  fi
else
  bad "authenticate.cgi not executable; DSM auth will not work"
fi

say "== /tmp visibility"
probe="/tmp/.synoterm-preflight-$$"
if touch "${probe}" 2>/dev/null; then
  say "  /tmp writable in this session"
  rm -f "${probe}" 2>/dev/null || true
  warn "if files created here are invisible to the next ssh/scp, the NAS uses PrivateTmp"
else
  warn "/tmp is not writable by $(id -un)"
fi

say "== loopback port ${PORT}"
if command -v netstat >/dev/null 2>&1; then
  if netstat -ltn 2>/dev/null | grep -q "[:.]${PORT} "; then
    warn "port ${PORT} already in use — pick another in packaging/dsm7/conf/resource and start-stop-status"
  else
    ok "port ${PORT} free"
  fi
else
  warn "netstat unavailable; check manually"
fi

say "== package state"
if [ -d "/var/packages/synoterm" ]; then
  warn "/var/packages/synoterm already exists (a previous install?)"
else
  ok "no existing synoterm package"
fi
if [ -x /usr/syno/bin/synopkg ]; then
  ok "/usr/syno/bin/synopkg available"
else
  warn "/usr/syno/bin/synopkg missing (manual install only)"
fi

say "== nginx"
if [ -x /usr/syno/bin/synonginx ]; then
  ok "synonginx helper available"
else
  warn "no synonginx helper; DSM will still reload nginx on install"
fi

say ""
if [ "${rc}" -eq 0 ]; then
  say "preflight: no blocking problems found"
else
  say "preflight: blocking problems found (see FAIL above)"
fi
say ""
say "Next: answer the cookie-only auth question with tools/nas-auth-test.sh"
exit "${rc}"
