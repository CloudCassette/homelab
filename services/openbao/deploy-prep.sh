#!/bin/bash
# One-time root deploy prep for OpenBao on cassette-lab.
# Safe to re-run: creates dirs, generates TLS CA/cert + auto-unseal key only
# if absent, fixes ownership for the container's uid:gid (default 100:1000 —
# verify with: docker run --rm openbao/openbao:2.7.2 id openbao).
#
# Prints the unseal key as base64 once, so it can be inserted into the
# off-host pass store. Root-only by design: /etc/openbao/**, key file 0640.
set -euo pipefail

CIUID="${OPENBAO_UID:-100}"
CIGID="${OPENBAO_GID:-1000}"

# --- data (container must write) -----------------------------------------
install -d -m 0750 "/media/Steam Dock/openbao/data"
chown -R "$CIUID:$CIGID" "/media/Steam Dock/openbao/data"

# --- TLS (container must read cert+key via group $CIGID) -------------------
install -d -m 0750 -g "$CIGID" /etc/openbao/tls
if [[ ! -f /etc/openbao/tls/fullchain.pem ]]; then
  openssl req -x509 -newkey rsa:4096 -nodes -days 3650 \
    -keyout /etc/openbao/tls/ca.key -out /etc/openbao/tls/ca.pem \
    -subj "/CN=cassette-lab OpenBao CA" 2>/dev/null
  openssl req -newkey rsa:2048 -nodes \
    -keyout /etc/openbao/tls/privkey.pem -out /etc/openbao/tls/csr.pem \
    -subj "/CN=openbao.lan" 2>/dev/null
  printf 'subjectAltName=IP:192.168.86.4,DNS:openbao.lan\n' > /etc/openbao/tls/ext.cnf
  openssl x509 -req -days 3650 \
    -in /etc/openbao/tls/csr.pem \
    -CA /etc/openbao/tls/ca.pem -CAkey /etc/openbao/tls/ca.key -CAcreateserial \
    -extfile /etc/openbao/tls/ext.cnf \
    -out /etc/openbao/tls/fullchain.pem 2>/dev/null
  rm -f /etc/openbao/tls/csr.pem /etc/openbao/tls/ext.cnf
fi
chown "root:$CIGID" /etc/openbao/tls/* && chmod 0640 /etc/openbao/tls/*

# --- auto-unseal key (root/container only; a copy goes to pass) ------------
install -d -m 0750 -g "$CIGID" /etc/openbao/secrets
if [[ ! -s /etc/openbao/secrets/unseal.key ]]; then
  openssl rand -out /etc/openbao/secrets/unseal.key 32
fi
chown "$CIUID:root" /etc/openbao/secrets/unseal.key && chmod 0640 /etc/openbao/secrets/unseal.key

# --- CA staged where the laptop can collect it ------------------------------
install -d -m 0775 /home/cloudcassette/services/openbao
install -m 0644 -o cloudcassette -g cloudcassette /etc/openbao/tls/ca.pem \
  /home/cloudcassette/services/openbao/ca.pem

echo
echo "=== unseal key (base64) — OFF-HOST COPY, insert into pass now ==="
echo '    pass insert homelab/openbao/unseal.key'
echo "=== value ==="
openssl base64 -A -in /etc/openbao/secrets/unseal.key
echo "=== done. Next: docker compose up -d ; verify with the runbook. ==="