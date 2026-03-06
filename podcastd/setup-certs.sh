#!/usr/bin/env bash
# Generate self-signed TLS certs for deepread.fm
# Run once before first docker compose up

set -euo pipefail

DOMAIN="deepread.fm"
CERT_DIR="$(dirname "$0")/traefik/certs"
mkdir -p "$CERT_DIR"

openssl req -x509 -nodes -days 3650 \
    -newkey rsa:2048 \
    -keyout "$CERT_DIR/$DOMAIN.key" \
    -out "$CERT_DIR/$DOMAIN.crt" \
    -subj "/CN=$DOMAIN" \
    -addext "subjectAltName=DNS:$DOMAIN,DNS:*.$DOMAIN"

echo "Certificates generated in $CERT_DIR/"
echo ""
echo "On your Mac, trust the cert:"
echo "  scp $(hostname):$CERT_DIR/$DOMAIN.crt ~/Desktop/"
echo "  # Double-click to add to Keychain, then mark as 'Always Trust'"
echo ""
echo "Add to /etc/hosts on Mac:"
echo "  <server-ip>  podcastd.$DOMAIN"
