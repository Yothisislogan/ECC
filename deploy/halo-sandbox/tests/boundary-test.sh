#!/usr/bin/env bash
# Hermetic boundary test for the halo sandbox.
#
# Builds the real gateway and agent images, swaps the GPU model server for a
# stub, adds a fake internet (allowed.test, evil.test, ...) and then tries every
# way out of the sandbox with scripts/probe.sh. Run as root to also load and
# prove the host firewall (host/halo-firewall.nft), with a before/after view.
#
# No GPU, model or real internet needed. Stop the real stack first: the test
# uses the same bridge names so the firewall rules are exercised as shipped.
#
# Usage: sudo tests/boundary-test.sh
# Env:   HALO_BUILD_CA            CA file for TLS-inspecting networks (build only)
#        HALO_TEST_KEEP=1         leave the stack running for inspection
#        HALO_TEST_EXT_OPEN=IP    external IP that answers on TCP 443 (firewall test)
#        HALO_TEST_EXT_PORT80=IP  external IP that answers on TCP 80  (firewall test)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$here"
proj=halo-test
work="$(mktemp -d)"
test_uid=${HALO_TEST_UID:-1000}
host_port=11434   # stands in for a host service such as Ollama or sshd
fw_loaded_by_us=0
listener_pid=""
failures=0

dc() { docker compose -p "$proj" --env-file "$work/env" -f compose.yaml -f tests/compose.test.yaml "$@"; }
say() { printf '\n### %s\n' "$*"; }
check() {  # check <description> <expected: open|closed> <actual: open|closed>
  if [[ "$2" == "$3" ]]; then printf 'PASS  %s (%s)\n' "$1" "$3"
  else printf 'FAIL  %s (expected %s, got %s)\n' "$1" "$2" "$3"; failures=$((failures + 1)); fi
}
probe() {  # probe <network> <ip> <port> -> open|closed
  if docker run --rm --network "$1" --entrypoint python3 halo-agent:local -c \
    "import socket,sys; socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=4).close()" \
    "$2" "$3" >/dev/null 2>&1; then echo open; else echo closed; fi
}
gateway_ip() { docker network inspect "$1" -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}'; }

cleanup() {
  set +e
  [[ -n "$listener_pid" ]] && kill "$listener_pid" 2>/dev/null
  if [[ "${HALO_TEST_KEEP:-0}" != 1 ]]; then
    dc --profile agent down -v --remove-orphans >/dev/null 2>&1
    docker network rm halo-test-tunnel >/dev/null 2>&1
    [[ $fw_loaded_by_us -eq 1 ]] && nft delete table inet halo 2>/dev/null
    rm -f "$here/.build-ca.test.pem"
    rm -rf "$work"
  else
    echo "Left running (project $proj); test files in $work"
  fi
}
trap cleanup EXIT

say "preflight"
docker info >/dev/null 2>&1 || { echo "Docker is not running"; exit 2; }
for br in halo-sandbox halo-egress halo-llmedge halo-tunnel; do
  if [[ -e "/sys/class/net/$br" ]]; then
    echo "bridge $br already exists: stop the real stack first (docker compose down)"; exit 2
  fi
done
# Compose reads build secrets only from inside the project directory.
if [[ -n "${HALO_BUILD_CA:-}" ]]; then cp "$HALO_BUILD_CA" .build-ca.test.pem; else : > .build-ca.test.pem; fi
as_root=0
if [[ $(id -u) -eq 0 ]] && command -v nft >/dev/null; then
  as_root=1
  # Same order as on the real host: firewall first, then containers.
  if nft list table inet halo >/dev/null 2>&1; then
    echo "table inet halo already loaded; testing it as-is"
  else
    nft -f host/halo-firewall.nft
    fw_loaded_by_us=1
    echo "loaded host/halo-firewall.nft"
  fi
  # A service on the host that the sandbox must not reach.
  python3 -m http.server "$host_port" --bind 0.0.0.0 >/dev/null 2>&1 &
  listener_pid=$!
else
  echo "not root (or no nft): the host firewall will not be tested"
fi
echo "ok"

say "test certificates and allowlist"
mkdir -p "$work/certs" "$work/workspace" "$work/models"
mkca() {  # mkca <name> <CN>
  openssl req -x509 -new -newkey rsa:2048 -nodes -sha256 -days 2 -subj "/CN=$2" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign" \
    -keyout "$work/certs/$1.key" -out "$work/certs/$1.crt" 2>/dev/null
}
mkleaf() {  # mkleaf <host> <ca-name> [extra SAN entries]
  openssl req -new -newkey rsa:2048 -nodes -subj "/CN=$1" -addext "subjectAltName=DNS:$1${3:+,$3}" \
    -keyout "$work/certs/$1.key" -out "$work/certs/$1.csr" 2>/dev/null
  openssl x509 -req -in "$work/certs/$1.csr" -CA "$work/certs/$2.crt" -CAkey "$work/certs/$2.key" \
    -CAcreateserial -days 2 -sha256 -copy_extensions copy -out "$work/certs/$1.crt" 2>/dev/null
}
mkca test-public-ca "Fake public CA (test)"
mkca rogue-ca "Rogue CA the gateway does not trust (test)"
# allowed.test's certificate also covers shared-cert.test, like the shared
# multi-site certificates CDNs use. Fronting to that name must still be refused.
mkleaf allowed.test test-public-ca "DNS:shared-cert.test"
for h in evil.test rebind.test; do mkleaf "$h" test-public-ca; done
mkleaf untrusted.test rogue-ca

printf '# test allowlist\nallowed.test\nuntrusted.test\nrebind.test\n' > "$work/allowed.txt"
printf 'allowed.test\n' > "$work/cf.txt"
scripts/make-ca.sh "$work/allowed.txt" "$work/ca" >/dev/null
chown -R "$test_uid:$test_uid" "$work" 2>/dev/null || true
chmod 755 "$work"

cat > "$work/env" <<EOF
HALO_UID=$test_uid
HALO_GID=$test_uid
HALO_RENDER_GID=990
HALO_VIDEO_GID=991
LLM_API_KEY=test-key
HALO_ALLOWLIST=$work/allowed.txt
HALO_CF_ACCESS_DOMAINS=$work/cf.txt
HALO_CA_DIR=$work/ca
HALO_WORKSPACE=$work/workspace
HALO_MODELS_DIR=$work/models
HALO_TEST_DIR=$work
CF_ACCESS_CLIENT_ID=test-id.access
CF_ACCESS_CLIENT_SECRET=0123456789abcdef
HALO_BUILD_CA=./.build-ca.test.pem
EOF
# Compose prefers shell variables over --env-file, so pin ours over anything inherited.
set -a
# shellcheck disable=SC1091
. "$work/env"
set +a
echo "ok"

say "build images"
dc --profile agent build gateway agent >/dev/null
echo "ok"

say "start stack (stub llm, gateway, fake internet)"
dc up -d --wait llm gateway site-public site-private fake-anthropic >/dev/null
dc logs gateway 2>&1 | grep '\[gateway\]' || true

say "probe from inside the sandbox"
set +e
dc --profile agent run --rm -T \
  -v "$here/scripts/probe.sh:/probe.sh:ro" \
  -e PROBE_ALLOWED_HOST=allowed.test \
  -e PROBE_BLOCKED_HOST=evil.test \
  -e PROBE_EXTRA_BLOCKED="https://untrusted.test/ https://rebind.test/ https://shared-cert.test/" \
  -e PROBE_FRONT_HOSTS="shared-cert.test" \
  -e PROBE_EXPECT_HEADER="cfid=test-id.access" \
  agent sh /probe.sh
probe_rc=$?
set -e
failures=$((failures + probe_rc))

say "gateway log (what the sandbox tried)"
dc logs gateway 2>&1 | grep -E 'status=' | sed 's/^[^|]*| //' | tail -n 20

say "Claude Code inside the sandbox talks only to the model"
before=$(dc logs --no-log-prefix gateway 2>&1 | grep -c 'status=' || true)
set +e
reply=$(dc --profile agent run --rm -T \
  -e ANTHROPIC_BASE_URL=http://fake-anthropic:8080 \
  -e NO_PROXY=llm,fake-anthropic,localhost,127.0.0.1 -e no_proxy=llm,fake-anthropic,localhost,127.0.0.1 \
  agent timeout 120 claude -p 'Say hi' 2>&1)
set -e
if grep -q 'Hello from the sandboxed stub model.' <<< "$reply"; then
  printf 'PASS  claude -p answered through the local model endpoint\n'
else
  printf 'FAIL  claude -p did not answer: %s\n' "$(tail -n 3 <<< "$reply")"; failures=$((failures + 1))
fi
calls=$(dc logs --no-log-prefix fake-anthropic 2>&1 | grep -c '"POST /v1/messages' || true)
printf 'INFO  model endpoint received %s request(s)\n' "$calls"
extra=$(dc logs --no-log-prefix gateway 2>&1 | grep 'status=' | tail -n +"$((before + 1))")
if [[ -z "$extra" ]]; then
  printf 'PASS  no other outbound attempts (telemetry, updates, lookups)\n'
else
  printf 'FAIL  Claude Code tried to reach:\n%s\n' "$extra"; failures=$((failures + 1))
fi

# ---------------------------------------------------------------------------
if [[ $as_root -eq 0 ]]; then
  say "host firewall: SKIPPED (run as root with nft installed to test it)"
else
  say "host firewall (host/halo-firewall.nft)"
  ext443=${HALO_TEST_EXT_OPEN:-$(getent ahostsv4 registry.npmjs.org | awk 'NR==1{print $1}')}
  ext80=${HALO_TEST_EXT_PORT80:-$(getent ahostsv4 archive.ubuntu.com | awk 'NR==1{print $1}')}
  docker network create -o com.docker.network.bridge.name=halo-tunnel halo-test-tunnel >/dev/null
  egress_net="${proj}_egress"
  sandbox_net="${proj}_sandbox"
  egress_host=$(gateway_ip "$egress_net")
  sandbox_host=$(gateway_ip "$sandbox_net")

  if [[ -n "$ext443" ]]; then
    check "gateway network -> $ext443:443 (HTTPS allowed)" open "$(probe "$egress_net" "$ext443" 443)"
    check "tunnel network -> $ext443:443 (only 7844 allowed)" closed "$(probe halo-test-tunnel "$ext443" 443)"
  fi
  if [[ -n "$ext80" ]]; then
    check "gateway network -> $ext80:80 (other ports dropped)" closed "$(probe "$egress_net" "$ext80" 80)"
  fi
  check "gateway network -> host service $egress_host:$host_port" closed "$(probe "$egress_net" "$egress_host" "$host_port")"
  if [[ -n "$sandbox_host" ]]; then
    check "sandbox network -> host service $sandbox_host:$host_port" closed "$(probe "$sandbox_net" "$sandbox_host" "$host_port")"
  fi

  if [[ $fw_loaded_by_us -eq 1 ]]; then
    echo "for comparison, the same paths WITHOUT the firewall (Docker defaults):"
    nft delete table inet halo
    printf '  gateway network -> %s:80   %s\n' "${ext80:-?}" "$(probe "$egress_net" "${ext80:-192.0.2.1}" 80)"
    printf '  tunnel network  -> %s:443  %s\n' "${ext443:-?}" "$(probe halo-test-tunnel "${ext443:-192.0.2.1}" 443)"
    printf '  gateway network -> host %s:%s  %s\n' "$egress_host" "$host_port" "$(probe "$egress_net" "$egress_host" "$host_port")"
    if [[ -n "$sandbox_host" ]]; then
      printf '  sandbox network -> host %s:%s  %s\n' "$sandbox_host" "$host_port" "$(probe "$sandbox_net" "$sandbox_host" "$host_port")"
    fi
    nft -f host/halo-firewall.nft
  fi
fi

say "result"
if [[ $failures -eq 0 ]]; then echo "BOUNDARY TEST PASSED"; else echo "BOUNDARY TEST FAILED: $failures failure(s)"; fi
exit $(( failures > 0 ))
