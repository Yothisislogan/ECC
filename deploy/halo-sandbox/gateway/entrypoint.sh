#!/bin/sh
# Start-up for the egress gateway. Runs as an unprivileged user on a
# read-only root filesystem; everything it writes lives on the /run/squid tmpfs.
set -eu
set -f  # no globbing: list entries such as "*.example.com" must stay literal

SRC_ALLOW=/etc/squid/allowed-domains.txt
SRC_CF=/etc/squid/cf-access-domains.txt
RUNDIR=/run/squid

log() { printf '[gateway] %s\n' "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

# Meaningful entries of a list file: comments and whitespace removed, lowercased.
entries() {
  [ -r "$1" ] || return 0
  sed -e 's/#.*//' -e 's/[[:space:]]//g' "$1" | tr '[:upper:]' '[:lower:]' | grep -v '^$' || true
}

# Refuse entries that would quietly open far more than intended.
check_list() {
  file=$1
  for name in $(entries "$file"); do
    case "$name" in
      *[!a-z0-9.-]*) die "$file: '$name' must be a plain host name (no wildcards, ports, paths or URLs; use .example.com for subdomains)" ;;
      ..*|*..*|*.) die "$file: '$name' is not a valid host name" ;;
    esac
    bare=${name#.}
    case "$bare" in
      *.*) : ;;
      *) die "$file: '$name' would match a whole top-level domain" ;;
    esac
    if printf '%s' "$bare" | grep -Eq '^[0-9.]+$'; then
      die "$file: '$name' is an IP address; list host names only"
    fi
  done
}

# Squid rejects lists where one entry is already covered by another
# (example.com next to .example.com), so drop the covered ones.
normalize() {
  entries "$1" | sort -u | awk '
    { n[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) if (substr(n[i], 1, 1) == ".") w[substr(n[i], 2)] = 1
      for (i = 1; i <= NR; i++) {
        e = n[i]; wild = (substr(e, 1, 1) == ".")
        d = wild ? substr(e, 2) : e
        covered = (!wild && (d in w))
        while (!covered && index(d, ".") > 0) { d = substr(d, index(d, ".") + 1); if (d in w) covered = 1 }
        if (!covered) print e
      }
    }'
}

[ -r "$SRC_ALLOW" ] || die "allowlist $SRC_ALLOW is missing or unreadable"
[ -r /etc/squid/ca/gateway-ca.crt ] && [ -r /etc/squid/ca/gateway-ca.key ] \
  || die "gateway CA is not readable by uid $(id -u); run scripts/make-ca.sh as the user in HALO_UID"
check_list "$SRC_ALLOW"

mkdir -p "$RUNDIR"
umask 077
normalize "$SRC_ALLOW" > "$RUNDIR/allowed-domains.txt"
if [ ! -s "$RUNDIR/allowed-domains.txt" ]; then
  log "allowlist is empty: every request will be denied"
  # Squid needs at least one entry; this name can never resolve.
  echo 'allowlist-is-empty.invalid' > "$RUNDIR/allowed-domains.txt"
fi

# Cache of generated per-site certificates (recreated on every start).
rm -rf "$RUNDIR/ssl_db"
/usr/lib/squid/security_file_certgen -c -s "$RUNDIR/ssl_db" -M 16MB >/dev/null

# Optional: add a Cloudflare Access service token to requests for the domains
# in cf-access-domains.txt. The token lives only in this container.
: > "$RUNDIR/extra.conf"
cf_id=${CF_ACCESS_CLIENT_ID:-}
cf_secret=${CF_ACCESS_CLIENT_SECRET:-}
if [ -n "$cf_id" ] || [ -n "$cf_secret" ]; then
  [ -n "$cf_id" ] && [ -n "$cf_secret" ] \
    || die "set both CF_ACCESS_CLIENT_ID and CF_ACCESS_CLIENT_SECRET, or neither"
  for v in "$cf_id" "$cf_secret"; do
    case "$v" in
      *[!A-Za-z0-9._-]*) die "Cloudflare Access token values contain unexpected characters" ;;
    esac
  done
  check_list "$SRC_CF"
  normalize "$SRC_CF" > "$RUNDIR/cf-access-domains.txt"
  if [ -s "$RUNDIR/cf-access-domains.txt" ]; then
    {
      printf 'acl cf_access_sites dstdomain -n "%s"\n' "$RUNDIR/cf-access-domains.txt"
      printf 'request_header_add CF-Access-Client-Id "%s" cf_access_sites\n' "$cf_id"
      printf 'request_header_add CF-Access-Client-Secret "%s" cf_access_sites\n' "$cf_secret"
    } > "$RUNDIR/extra.conf"
    log "Cloudflare Access service token will be added for: $(tr '\n' ' ' < "$RUNDIR/cf-access-domains.txt")"
  else
    log "service token is set but cf-access-domains.txt is empty; not sending it anywhere"
  fi
fi

log "allowlist: $(tr '\n' ' ' < "$RUNDIR/allowed-domains.txt")"
if squid -k parse -f /etc/squid/squid.conf 2>&1 | grep -E 'FATAL|ERROR' >&2; then
  die "squid.conf failed to parse"
fi
log "$(squid -v | head -n 1) starting"
exec squid -N -f /etc/squid/squid.conf
