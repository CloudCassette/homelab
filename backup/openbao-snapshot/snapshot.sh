#!/bin/bash
# Snapshot the OpenBao raft cluster to the backup drive.
# OpenBao OSS has no automatic snapshot mechanism; this unit runs daily.
#
# Snapshots are sealed/encrypted with the same seal key as the live node, so
# they are safe to store alongside other encrypted backups. Restore: bring up
# a fresh node with the same unseal key (or the original recoverable copy of
# it), then `bao operator raft snapshot restore <file>`.
#
# The root OpenBao has been initialized (`bao operator init`) by then.
set -euo pipefail
umask 077

readonly SNAP_DIR=/mnt/forgejo-backup/openbao-snapshots
readonly KEEP=7
readonly CNAME=openbao
readonly IN_CONTAINER=/openbao/data/snapshot.tmp.json

docker image inspect openbao/openbao:2.7.2 >/dev/null 2>&1 || { echo "openbao image missing; skipping"; exit 0; }

# On-source snapshot (sealed), then pull it out to the backup mount.
if ! docker exec "$CNAME" bao operator raft snapshot save "$IN_CONTAINER" >/dev/null; then
  echo "raft snapshot save failed"
  exit 1
fi

mkdir -p "$SNAP_DIR"
snap="$SNAP_DIR/openbao-$(date -u +%Y%m%dT%H%M%SZ).snap"
docker cp "$CNAME:$IN_CONTAINER" "$snap"
docker exec "$CNAME" rm -f "$IN_CONTAINER"

# Trim to the newest $KEEP snapshots.
ls -1t "$SNAP_DIR"/openbao-*.snap | tail -n +$((KEEP + 1)) | xargs -r rm -f
echo "saved $snap ($(stat -c %s "$snap") bytes); keeping last $KEEP"