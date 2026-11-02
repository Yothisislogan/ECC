#!/usr/bin/env bash
# Create (or refresh) the egress gateway's private CA.
#
# The sandbox trusts ONLY this CA. The gateway uses it to terminate TLS so it
# can enforce the allowlist on both the SNI and the Host header.
#
# The CA carries X.509 name constraints built from allowed-domains.txt, so even
# if its key leaked it could only vouch for your own domains (OpenSSL, Node,
# Go and browsers all enforce this). Re-run after editing the allowlist, then
# restart the gateway and agent.
#
# Usage: scripts/make-ca.sh [--force] [ALLOWLIST] [OUT_DIR]
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
force=0
if [[ "${1:-}" == "--force" ]]; then force=1; shift; fi
allowlist="${1:-$here/allowed-domains.txt}"
outdir="${2:-$here/gateway/ca}"

command -v openssl >/dev/null || { echo "openssl is required" >&2; exit 1; }
[[ -r "$allowlist" ]] || { echo "allowlist not found: $allowlist" >&2; exit 1; }

# Same normalisation as the gateway: drop comments/whitespace, lowercase,
# strip the leading dot (a DNS name constraint already covers subdomains).
names="$(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$allowlist" | tr '[:upper:]' '[:lower:]' \
  | grep -v '^$' | sed 's/^\.//' | sort -u || true)"
if [[ -z "$names" ]]; then
  names="allowlist-is-empty.invalid"
fi
while read -r n; do
  if [[ ! "$n" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
    echo "refusing allowlist entry '$n': not a plain host name" >&2
    exit 1
  fi
done <<< "$names"

mkdir -p "$outdir"
if [[ -f "$outdir/gateway-ca.crt" && -f "$outdir/constraints.txt" && $force -eq 0 ]] \
   && [[ "$(cat "$outdir/constraints.txt")" == "$names" ]]; then
  echo "CA in $outdir already matches the allowlist (use --force to replace it)."
  exit 0
fi

permitted="$(sed 's/^/permitted;DNS:/' <<< "$names" | paste -sd, -)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/ca.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = Halo sandbox egress gateway CA
O = halo-sandbox (local only)
[v3_ca]
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
nameConstraints = critical, ${permitted}, excluded;IP:0.0.0.0/0.0.0.0, excluded;IP:0:0:0:0:0:0:0:0/0:0:0:0:0:0:0:0
EOF

umask 077
openssl req -x509 -new -newkey rsa:3072 -nodes -sha256 -days 730 \
  -config "$tmp/ca.cnf" -extensions v3_ca \
  -keyout "$tmp/gateway-ca.key" -out "$tmp/gateway-ca.crt" 2>/dev/null
chmod 600 "$tmp/gateway-ca.key"
chmod 644 "$tmp/gateway-ca.crt"
mv -f "$tmp/gateway-ca.key" "$outdir/gateway-ca.key"
mv -f "$tmp/gateway-ca.crt" "$outdir/gateway-ca.crt"
printf '%s\n' "$names" > "$outdir/constraints.txt"
chmod 644 "$outdir/constraints.txt"

echo "Wrote $outdir/gateway-ca.crt (public) and gateway-ca.key (private, mode 600)."
echo "Name constraints: $(paste -sd' ' <<< "$names")"
openssl x509 -in "$outdir/gateway-ca.crt" -noout -fingerprint -sha256 -enddate
echo "Restart to apply: docker compose up -d --force-recreate gateway"
