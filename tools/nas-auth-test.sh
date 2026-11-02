#!/bin/sh
# Answers the one question that decides the DSM 7.1 UI style:
#   "does authenticate.cgi accept the session cookie alone?"
#
# Run it ON the NAS (sudo not required, but it must be able to execute
# authenticate.cgi), passing the Cookie header copied from your browser.
#
#   ssh admin@nas 'sudo sh -s' < tools/nas-auth-test.sh
#   # or
#   sudo sh /tmp/nas-auth-test.sh 'id=abc123; stay_login=0'
#   sudo sh /tmp/nas-auth-test.sh 'id=abc123' 'MySynoToken'
#
# How to get the cookie: log in to DSM in the browser -> DevTools ->
# Application/Storage -> Cookies -> https://<nas>:5001 -> copy `id`
# (and, if present, `SynoToken`).
set -u

COOKIE="${1:-${SYNOTERM_COOKIE:-}}"
TOKEN="${2:-${SYNOTERM_SYNOTOKEN:-}}"
CGI=/usr/syno/synoman/webman/modules/authenticate.cgi
HOST="${SYNOTERM_HOST:-$(hostname)}"

if [ -z "${COOKIE}" ]; then
  cat >&2 <<'USAGE'
usage: nas-auth-test.sh '<cookie header>' ['<SynoToken>']

  <cookie header>  e.g. 'id=abc123; stay_login=0'
  <SynoToken>      optional; the token DSM puts in its own URLs
USAGE
  exit 2
fi

if [ ! -x "${CGI}" ]; then
  echo "authenticate.cgi is not executable at ${CGI}" >&2
  exit 1
fi

run() {
  label="$1"; tok="$2"
  out=$(env -i \
      REQUEST_METHOD=GET \
      GATEWAY_INTERFACE=CGI/1.1 \
      SERVER_SOFTWARE=synoterm-probe \
      PATH=/usr/syno/bin:/usr/bin:/bin \
      HTTP_COOKIE="${COOKIE}" \
      HTTP_HOST="${HOST}:5001" \
      REMOTE_ADDR=127.0.0.1 \
      HTTP_USER_AGENT=synoterm-probe \
      HTTP_X_SYNO_TOKEN="${tok}" \
      "${CGI}" 2>&1)
  status=$?
  if [ -n "${out}" ]; then
    printf '  %-22s -> %s (exit %s)\n' "${label}" "${out}" "${status}"
  else
    printf '  %-22s -> <empty> (exit %s)\n' "${label}" "${status}"
  fi
}

echo "probing ${CGI}"
echo "  host header: ${HOST}:5001"
echo
run "cookie only" ""
run "cookie + token" "${TOKEN}"
echo
cat <<'EOF'
interpretation
  "cookie only" prints your account name
      -> the default `.url` UI style works on this DSM; no token plumbing needed.
  only "cookie + token" works
      -> build with SYNOTERM_UI_STYLE=vue (DSM 7.2), or add the ExtJS wrapper
         for 7.1 (docs/dsm-integration.md §5.3).
  both empty
      -> the cookie was copied wrong, the session expired, or
         authenticate.cgi needs more of the original request. Re-copy the
         cookie while the DSM desktop tab is open, and try again.
EOF
