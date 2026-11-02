#!/bin/sh
# Diagnostic CGI, served by DSM's own web server from this package:
#
#   http://<nas>:5000/webman/3rdparty/synoterm/auth-probe.cgi
#
# It answers two questions that decide how synoterm authenticates on this DSM:
#   1. what does webman hand to a package CGI (REMOTE_USER? the SynoToken?),
#   2. does authenticate.cgi succeed in that context, and for which account.
#
# It prints no secret values (cookie/token are reported as present + length),
# and it changes nothing.
set -u

AUTH_CGI="/usr/syno/synoman/webman/modules/authenticate.cgi"

json_str() { # json_str <value>
  printf '"%s"' "$(printf '%s' "${1:-}" | tr -d '\r\n' | sed 's/\\/\\\\/g; s/"/\\"/g')"
}

flag() { # flag <value-length>
  if [ "${1:-0}" -gt 0 ] 2>/dev/null; then printf 'true'; else printf 'false'; fi
}

# 1. what webman provides
remote_user="${REMOTE_USER:-}"
cookie_len=${#HTTP_COOKIE}
token_env="${HTTP_X_SYNO_TOKEN:-}"
token_query=""
case "${QUERY_STRING:-}" in
  *synotoken=*) token_query="${QUERY_STRING##*synotoken=}"; token_query="${token_query%%&*}" ;;
  *SynoToken=*) token_query="${QUERY_STRING##*SynoToken=}"; token_query="${token_query%%&*}" ;;
esac

# 2. run authenticate.cgi exactly the way the doc says a package CGI should
auth_user=""
auth_exit=127
auth_output=""
if [ -x "${AUTH_CGI}" ]; then
  auth_output=$(
    HTTP_COOKIE="${HTTP_COOKIE:-}" \
    REMOTE_ADDR="${REMOTE_ADDR:-}" \
    SERVER_ADDR="${SERVER_ADDR:-}" \
    REQUEST_METHOD="${REQUEST_METHOD:-GET}" \
    QUERY_STRING="${QUERY_STRING:-}" \
    HTTP_X_SYNO_TOKEN="${token_env}" \
    "${AUTH_CGI}" 2>/dev/null
  )
  auth_exit=$?
  auth_user=$(printf '%s' "${auth_output}" | tr -d '\r' | awk 'NF { print; exit }')
fi

printf 'Content-Type: application/json\r\n'
printf 'Cache-Control: no-store\r\n'
printf '\r\n'
printf '{'
printf '"ok":true,'
printf '"user":%s,' "$(json_str "${auth_user}")"
printf '"remote_user":%s,' "$(json_str "${remote_user}")"
printf '"authenticate_exit":%s,' "${auth_exit}"
printf '"authenticate_empty":%s,' "$([ -z "${auth_user}" ] && echo true || echo false)"
printf '"request":{'
printf '"method":%s,' "$(json_str "${REQUEST_METHOD:-}")"
printf '"cookie_present":%s,' "$(flag "${cookie_len}")"
printf '"cookie_length":%s,' "${cookie_len:-0}"
printf '"syno_token_env_present":%s,' "$(flag "${#token_env}")"
printf '"syno_token_env_length":%s,' "${#token_env}"
printf '"syno_token_query_present":%s,' "$(flag "${#token_query}")"
printf '"remote_addr":%s' "$(json_str "${REMOTE_ADDR:-}")"
printf '},'
printf '"identity":%s,' "$(json_str "$(id -un 2>/dev/null)")"
printf '"script":%s' "$(json_str "$0")"
printf '}\n'
