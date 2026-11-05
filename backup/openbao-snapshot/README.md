# OpenBao raft snapshot (root-run, daily 06:15)

Sealed `bao operator raft snapshot` of the OpenBao raft cluster to
`/mnt/forgejo-backup/openbao-snapshots` (the 4 TB backup drive), keeping the
7 newest. Snapshots are encrypted with the node's seal, safe alongside the
restic archives. Not (yet) fed into a restic repo — move to one when the
secrets-migration sprint wires OpenBao's own secrets into the backup job.

Install (as root on cassette-lab):

```sh
sudo install -o root -g root -m 0750 snapshot.sh /usr/local/sbin/openbao-snapshot
sudo install -o root -g root -m 0644 openbao-snapshot.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl start openbao-snapshot.service && journalctl -fu openbao-snapshot.service
sudo systemctl enable --now openbao-snapshot.timer
```

Verify: `ls -l /mnt/forgejo-backup/openbao-snapshots` after a run.

Restore: copy the chosen `.snap` into the node's data dir, then
`bao operator raft snapshot restore <file>` on an unsealed fresh node that has
the same unseal key.