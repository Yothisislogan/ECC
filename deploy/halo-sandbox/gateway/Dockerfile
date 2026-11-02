# Egress gateway: Squid built with OpenSSL (needed for ssl-bump).
# Base image is pinned by digest. Rebuilding pulls Ubuntu's current
# security-patched squid-openssl package.
FROM ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      squid-openssl ca-certificates \
 && rm -rf /var/lib/apt/lists/* /etc/squid/squid.conf /etc/squid/conf.d

COPY squid.conf /etc/squid/squid.conf
COPY entrypoint.sh /usr/local/bin/gateway-entrypoint
RUN chmod 0644 /etc/squid/squid.conf && chmod 0755 /usr/local/bin/gateway-entrypoint

# Overridden at run time by compose (user: HALO_UID). Never runs as root.
USER proxy
EXPOSE 3128
ENTRYPOINT ["/usr/local/bin/gateway-entrypoint"]
