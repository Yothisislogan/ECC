#!/usr/bin/env bash
# Check the running stack from the host and from inside the sandbox.
#
# Usage: scripts/verify.sh [ALLOWED_HOST [BLOCKED_HOST]]
#   ALLOWED_HOST  an allowlisted host to fetch (default: first allowlist entry)
#   BLOCKED_HOST  a host that must be refused  (default: example.com)
# ok/bad always succeed, so "test && ok || bad" is a safe if/else here.
# shellcheck disable=SC2015
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$here" || exit 1
problems=0
ok()  { printf 'PASS  %s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*"; problems=$((problems + 1)); }
note() { printf 'NOTE  %s\n' "$*"; }

echo "== host"
if command -v nft >/dev/null && sudo -n nft list table inet halo >/dev/null 2>&1; then
  ok "host firewall table inet halo is loaded"
elif command -v nft >/dev/null && nft list table inet halo >/dev/null 2>&1; then
  ok "host firewall table inet halo is loaded"
else
  bad "host firewall not loaded or not readable (sudo nft list table inet halo)"
fi
if command -v systemctl >/dev/null; then
  [[ "$(systemctl is-enabled halo-firewall.service 2>/dev/null)" == enabled ]] \
    && ok "halo-firewall.service enabled at boot" || bad "halo-firewall.service is not enabled"
fi
if command -v ss >/dev/null; then
  exposed=$(ss -H -lntu 2>/dev/null | awk '{print $5}' | grep -vE '^(127\.|\[::1\]|::1)' | sort -u | paste -sd' ' -)
  if [[ -n "$exposed" ]]; then
    note "host sockets listening beyond loopback: $exposed (make sure your inbound firewall drops them)"
  else
    ok "nothing on the host listens beyond loopback"
  fi
fi

echo "== stack"
for svc in llm gateway; do
  [[ -n "$(docker compose ps -q --status running "$svc" 2>/dev/null)" ]] \
    && ok "$svc is running" || bad "$svc is not running (docker compose up -d)"
done
published=$(docker compose ps --format '{{.Name}} {{.Ports}}' 2>/dev/null | grep -E -- '->' || true)
[[ -z "$published" ]] && ok "no container publishes a port" || bad "published ports found: $published"

# The CA's name constraints must match the allowlist.
want=$(sed -e 's/#.*//' -e 's/[[:space:]]//g' allowed-domains.txt | tr '[:upper:]' '[:lower:]' | grep -v '^$' | sed 's/^\.//' | sort -u)
[[ -z "$want" ]] && want="allowlist-is-empty.invalid"
if [[ "$(cat gateway/ca/constraints.txt 2>/dev/null)" == "$want" ]]; then
  ok "gateway CA matches allowed-domains.txt"
else
  bad "gateway CA is out of date: run scripts/make-ca.sh, then docker compose up -d --force-recreate gateway"
fi

allowed=${1:-$(sed -e 's/#.*//' -e 's/[[:space:]]//g' allowed-domains.txt | grep -v '^$' | head -n 1 | sed 's/^\.//')}
blocked=${2:-example.com}

echo "== from inside the sandbox"
docker compose run --rm -T \
  -v "$here/scripts/probe.sh:/probe.sh:ro" \
  -e PROBE_ALLOWED_HOST="$allowed" \
  -e PROBE_BLOCKED_HOST="$blocked" \
  agent sh /probe.sh
problems=$((problems + $?))

echo
echo "== last gateway decisions"
docker compose logs --no-log-prefix --tail 15 gateway 2>/dev/null | grep 'status=' || true

echo
if [[ $problems -eq 0 ]]; then echo "VERIFY PASSED"; else echo "VERIFY FAILED: $problems problem(s)"; fi
exit $(( problems > 0 ))
