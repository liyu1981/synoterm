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
# Reading secrets from stdin instead of argv (used by tools/nas-test.sh):
#   sh /tmp/nas-auth-test.sh --stdin      # line 1: cookie, line 2: token
#   sh /tmp/nas-auth-test.sh --file PATH  # same format, file mode 0600
#
# How to get the cookie: log in to DSM in the browser -> DevTools ->
# Application/Storage -> Cookies -> https://<nas>:5001 -> copy `id`
# (and, if present, `SynoToken`).
set -u

MODE="argv"
case "${1:-}" in
  --stdin) MODE="stdin"; shift ;;
  --file) MODE="file"; SECRET_FILE="${2:?--file needs a path}"; shift 2 ;;
esac

COOKIE="${1:-${SYNOTERM_COOKIE:-}}"
TOKEN="${2:-${SYNOTERM_SYNOTOKEN:-}}"

case "${MODE}" in
  stdin)
    IFS= read -r COOKIE || true
    IFS= read -r TOKEN || true
    ;;
  file)
    if [ ! -r "${SECRET_FILE}" ]; then
      echo "cannot read ${SECRET_FILE}" >&2
      exit 2
    fi
    COOKIE=$(sed -n '1p' "${SECRET_FILE}")
    TOKEN=$(sed -n '2p' "${SECRET_FILE}")
    ;;
esac
# Override only for local testing of the harness (e.g. a stub that echoes a name).
CGI="${SYNOTERM_AUTHENTICATE_CGI:-/usr/syno/synoman/webman/modules/authenticate.cgi}"
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
if [ -n "${TOKEN}" ]; then
  run "cookie + token" "${TOKEN}"
else
  printf '  %-22s -> (no token supplied; skipping)\n' "cookie + token"
fi
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
