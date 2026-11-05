#!/bin/bash
# Snapshot the OpenBao raft cluster to the backup drive.
# OpenBao OSS has no automatic snapshot mechanism; this unit runs daily.
#
# Auth: the snapshot endpoint is privileged. A scoped periodic token is kept
# at /etc/openbao/snapshot.token (root-only, minted once with the bootstrap
# token; see README) and self-renewed on every run. Least privilege — it can
# only do the raft-snapshot read, nothing else.
#
# Snapshots are sealed/encrypted with the same seal key as the live node, so
# they are safe to store alongside other encrypted backups. Restore: bring up
# a fresh node with the same unseal key (or the original recoverable copy of
# it), then `bao operator raft snapshot restore <file>`.
set -euo pipefail
umask 077

readonly SNAP_DIR=/mnt/forgejo-backup/openbao-snapshots
readonly KEEP=7
readonly CNAME=openbao
readonly TOKEN_FILE=/etc/openbao/snapshot.token
readonly IN_CONTAINER=/openbao/data/snapshot.tmp.json

docker image inspect openbao/openbao:2.7.2 >/dev/null 2>&1 || { echo "openbao image missing; skipping"; exit 0; }

if [[ ! -r "$TOKEN_FILE" ]]; then
  echo "no snapshot token at $TOKEN_FILE; run the token bootstrap (services/openbao/README.md)"
  exit 1
fi
export BAO_TOKEN="$(cat "$TOKEN_FILE")"

# On-source snapshot (sealed), then pull it out to the backup mount.
# The in-container client must point at the LAN address + our CA (defaults to
# 127.0.0.1:8200 and fails the TLS check).
if ! docker exec -e BAO_ADDR=https://192.168.86.4:8200 -e BAO_CACERT=/openbao/tls/ca.pem \
     -e BAO_TOKEN="$BAO_TOKEN" \
     "$CNAME" bao operator raft snapshot save "$IN_CONTAINER" >/dev/null; then
  echo "raft snapshot save failed"
  exit 1
fi

mkdir -p "$SNAP_DIR"
snap="$SNAP_DIR/openbao-$(date -u +%Y%m%dT%H%M%SZ).snap"
docker cp "$CNAME:$IN_CONTAINER" "$snap"
docker exec "$CNAME" rm -f "$IN_CONTAINER"

# Trim to the newest $KEEP snapshots.
ls -1t "$SNAP_DIR"/openbao-*.snap | tail -n +$((KEEP + 1)) | xargs -r rm -f

# Keep the periodic snapshot token alive (it has a 24h period).
docker exec -e BAO_ADDR=https://192.168.86.4:8200 -e BAO_CACERT=/openbao/tls/ca.pem \
  -e BAO_TOKEN="$BAO_TOKEN" "$CNAME" bao token renew -self >/dev/null 2>&1 || true

echo "saved $snap ($(stat -c %s "$snap") bytes); keeping last $KEEP"