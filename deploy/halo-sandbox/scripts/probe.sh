#!/bin/sh
# Runs INSIDE the agent container and tries every way out of the sandbox.
# Each check prints PASS or FAIL; the exit status is the number of failures.
#
# Environment:
#   PROBE_ALLOWED_HOST   an allowlisted host (positive check skipped if unset)
#   PROBE_ALLOWED_PATH   path to fetch on it (default /)
#   PROBE_BLOCKED_HOST   a host that must be refused (default example.com)
#   PROBE_EXTRA_BLOCKED  extra https URLs that must be refused (space-separated)
#   PROBE_FRONT_HOSTS    extra hosts to try in a Host-header swap (space-separated)
#   PROBE_EXPECT_HEADER  if set, PROBE_ALLOWED_HOST$PROBE_HEADER_PATH must echo it
#   PROBE_HEADER_PATH    path that echoes request headers (default /headers)
# pass/fail always succeed, so "test && pass || fail" is a safe if/else here;
# via_proxy output is split into its three fields on purpose.
# shellcheck disable=SC2015,SC2046
set -u

PROXY=http://gateway:3128
ALLOWED=${PROBE_ALLOWED_HOST:-}
APATH=${PROBE_ALLOWED_PATH:-/}
BLOCKED=${PROBE_BLOCKED_HOST:-example.com}
fails=0

pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
skip() { printf 'SKIP  %s\n' "$1"; }

# TCP connect test with a short timeout; succeeds only if the connect works.
can_connect() {
  python3 - "$1" "$2" <<'PY'
import socket, sys
try:
    socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=4).close()
except Exception:
    sys.exit(1)
PY
}

# Fetch through the gateway; prints "<curl exit> <http status> <squid error>".
via_proxy() {
  hdrs=$(mktemp)
  code=$(curl -sS -o /dev/null -D "$hdrs" -w '%{http_code}' --max-time 15 \
           --proxy "$PROXY" "$@" 2>/dev/null)
  rc=$?
  serr=$(tr -d '\r' < "$hdrs" | sed -n 's/^[Xx]-[Ss]quid-[Ee]rror: //p' | head -n 1)
  rm -f "$hdrs"
  printf '%s %s %s\n' "$rc" "${code:-000}" "${serr:--}"
}

# A request is "refused" if curl failed or the gateway answered with an error.
refused() {
  set -- $(via_proxy "$@")
  [ "$1" != 0 ] || [ "$3" != "-" ]
}

echo "== sandbox identity"
[ "$(id -u)" != 0 ] && pass "runs as non-root uid $(id -u)" || fail "running as root"
if grep -q '^CapEff:[[:space:]]*0*$' /proc/self/status; then
  pass "no Linux capabilities"
else
  fail "has capabilities: $(grep CapEff /proc/self/status)"
fi
if touch /usr/.probe 2>/dev/null; then rm -f /usr/.probe; fail "root filesystem is writable"; else pass "root filesystem is read-only"; fi
[ -e /var/run/docker.sock ] && fail "Docker socket is visible" || pass "no Docker socket"

echo "== local model"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://llm:8080/health)
[ "$code" = 200 ] && pass "llm answers on http://llm:8080" || fail "llm not reachable (HTTP $code)"

echo "== allowed web access (through the gateway)"
if [ -n "$ALLOWED" ]; then
  set -- $(via_proxy "https://$ALLOWED$APATH")
  if [ "$1" = 0 ] && [ "$3" = "-" ]; then
    pass "https://$ALLOWED$APATH reachable (HTTP $2)"
  else
    fail "https://$ALLOWED$APATH should be reachable (curl=$1 http=$2 gateway=$3)"
  fi
else
  skip "no allowlisted host given (PROBE_ALLOWED_HOST)"
fi

echo "== everything else must be refused"
refused "https://$BLOCKED/" && pass "non-allowlisted site https://$BLOCKED/" || fail "https://$BLOCKED/ was NOT refused"
refused "https://1.1.1.1/" && pass "raw IP address https://1.1.1.1/" || fail "raw IP https://1.1.1.1/ was NOT refused"
for url in ${PROBE_EXTRA_BLOCKED:-}; do
  refused "$url" && pass "refused $url" || fail "$url was NOT refused"
done
if [ -n "$ALLOWED" ]; then
  refused "http://$ALLOWED/" && pass "plain http:// to an allowed host" || fail "plain http://$ALLOWED/ was NOT refused"
  refused "https://$ALLOWED:8443/" && pass "non-443 port on an allowed host" || fail "https://$ALLOWED:8443/ was NOT refused"
  # Domain fronting: tunnel to an allowed host, then ask it for another site.
  for front in $BLOCKED ${PROBE_FRONT_HOSTS:-}; do
    refused -H "Host: $front" "https://$ALLOWED/" \
      && pass "Host-header swap (fronting) to $front" || fail "Host-header swap to $front was NOT refused"
  done
  # A normal client asking for $BLOCKED through an allowed tunnel must reject the certificate.
  if echo | openssl s_client -proxy gateway:3128 -connect "$ALLOWED:443" -servername "$BLOCKED" \
       -verify_hostname "$BLOCKED" -verify_return_error >/dev/null 2>&1; then
    fail "TLS for $BLOCKED through an allowed tunnel was accepted"
  else
    pass "SNI swap: certificate for $BLOCKED never offered"
  fi
  # A hostile client that ignores certificate errors and swaps SNI and Host.
  reply=$(printf 'GET / HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n' "$BLOCKED" \
    | timeout 15 openssl s_client -quiet -proxy gateway:3128 -connect "$ALLOWED:443" \
        -servername "$BLOCKED" 2>/dev/null | tr -d '\r' | head -n 20)
  if printf '%s\n' "$reply" | grep -qi '^x-squid-error'; then
    pass "SNI+Host swap with certificate checks off is refused by the gateway"
  else
    fail "SNI+Host swap with certificate checks off was NOT refused: $(printf '%s' "$reply" | head -n 1)"
  fi
fi

echo "== no way around the gateway"
target=${ALLOWED:-$BLOCKED}
if getent hosts "$target" >/dev/null 2>&1 || getent hosts example.com >/dev/null 2>&1; then
  fail "sandbox can resolve external DNS names"
else
  pass "no external DNS from the sandbox"
fi
if curl -s -o /dev/null --max-time 8 --noproxy '*' "https://$target/"; then
  fail "direct HTTPS without the gateway worked"
else
  pass "direct HTTPS without the gateway"
fi
for ip in 1.1.1.1 8.8.8.8; do
  can_connect "$ip" 443 && fail "direct TCP to $ip:443 worked" || pass "direct TCP to $ip:443"
done
can_connect 1.1.1.1 53 && fail "direct TCP to 1.1.1.1:53 worked" || pass "direct TCP to 1.1.1.1:53 (DNS)"
# The first address of our own subnet is where the host would sit.
myip=$(python3 -c 'import socket; print(socket.gethostbyname(socket.gethostname()))' 2>/dev/null)
if [ -n "$myip" ]; then
  hostip=$(echo "$myip" | awk -F. '{print $1"."$2"."$3".1"}')
  if can_connect "$hostip" 22 || can_connect "$hostip" 11434; then
    fail "host services reachable at $hostip"
  else
    pass "host services at $hostip (ssh, ollama) unreachable"
  fi
fi

if [ -n "${PROBE_EXPECT_HEADER:-}" ] && [ -n "$ALLOWED" ]; then
  echo "== Cloudflare Access token injection"
  body=$(curl -sS --max-time 10 --proxy "$PROXY" -H 'CF-Access-Client-Secret: from-the-sandbox' \
           "https://$ALLOWED${PROBE_HEADER_PATH:-/headers}" 2>/dev/null)
  case "$body" in
    *"$PROBE_EXPECT_HEADER"*) pass "gateway added the service token" ;;
    *) fail "service token not added (got: $body)" ;;
  esac
  case "$body" in
    *from-the-sandbox*) fail "sandbox-supplied CF-Access header was passed through" ;;
    *) pass "sandbox-supplied CF-Access header stripped" ;;
  esac
fi

echo
if [ "$fails" -eq 0 ]; then echo "All checks passed."; else echo "$fails check(s) FAILED."; fi
exit "$fails"
