====================================================

Review these staged files independently before installation. The root-run
script never executes the user-writable Compose file. It parses it with
PyYAML, validates the exact Forgejo service/image/restart policy and one `/data`
bind, and separately checks the immutable Docker container ID, Compose labels,
image, and mount before stopping anything. It requires exact ext4 UUIDs and
read-write mountpoints, no nested mounts, at least 200 GiB free, a valid existing
repository/password, and Forgejo initially running. The script stops only that
verified ID, requires graceful exit code 0, bounds restic backup to one hour
plus 30 seconds, verifies the same container stayed stopped, and restarts the
original ID on exit/signals with bounded Docker and HTTP checks.

The installed restic v0.19.1 help confirms `backup --json`; the official
scripting documentation specifies JSON Lines and a final successful
`message_type=summary` containing `snapshot_id` (omitted if no snapshot was
created): https://restic.readthedocs.io/en/stable/075_scripting.html . The
script requires exactly one final summary with a full 64-hex ID. It writes the
accepted ID atomically to `/var/lib/forgejo-backup/last-successful-snapshot`
only after backup success, the stopped-container invariant, restarting the
original container, and HTTP 200. Any failure leaves the prior accepted ID
untouched. Restore instructions below use only that accepted ID, never a
floating `latest` selector.

Current verified Compose scope: no `env_file`, no named/external volumes, and
one writable host bind `/media/Steam Dock/forgejo` -> `/data`. Backup inputs are
exactly that complete data directory (including SQLite DB/WAL and protected SSH
files) plus `/home/cloudcassette/services/forgejo/compose.yaml`. No Docker
images, other containers, or other volumes/files are backed up. The script
fails closed if that scope changes. Compose/runtime restart policy is `always`.
The script accepts only Forgejo exit code 0 as graceful; confirm this during the
first controlled manual run. If this image returns another code, stop and
independently verify shutdown behavior before changing that guard.

Install after independent review
--------------------------------

```sh
STAGE=/home/cloudcassette/forgejo-backup-staging
sudo install -o root -g root -m 0755 /home/cloudcassette/.local/bin/restic /usr/local/bin/restic
sudo install -o root -g root -m 0750 "$STAGE/backup.sh" /usr/local/sbin/forgejo-restic-backup
sudo install -o root -g root -m 0644 "$STAGE/forgejo-restic-backup.service" /etc/systemd/system/forgejo-restic-backup.service
sudo install -o root -g root -m 0644 "$STAGE/forgejo-restic-backup.timer" /etc/systemd/system/forgejo-restic-backup.timer
```

Passphrase creation and off-host copy
-------------------------------------

Create the directory only if it does not already exist; stop and inspect any
existing path rather than altering it. Bash `noclobber` prevents overwriting an
existing password file:

```sh
sudo bash -c 'set -euo pipefail; umask 077; mkdir -m 0700 /etc/forgejo-backup'
sudo bash -c 'set -euo pipefail; umask 077; [[ ! -e /etc/forgejo-backup/password && ! -L /etc/forgejo-backup/password ]]; set -o noclobber; openssl rand -base64 48 > /etc/forgejo-backup/password; chown root:root /etc/forgejo-backup/password; chmod 600 /etc/forgejo-backup/password'
sudo stat -c '%u:%g %a' /etc/forgejo-backup/password  # require 0:0 600
```

In a private administrator terminal only, display it once using
`sudo cat /etc/forgejo-backup/password` and enter it directly into an off-host
password manager. Never send it to an agent/chat, paste it into logs/screenshots,
or leave it on the clipboard. Keep the off-host copy before relying on backups.

After repository initialization, verify the copied off-host password without
putting the secret in argv or environment. Run in a private interactive
terminal; type/paste the password at the silent prompt. A root-only temporary
file in `/run` is removed on exit:

```sh
sudo bash -c 'set -euo pipefail; umask 077; f=$(mktemp /run/forgejo-password-check.XXXXXX); trap '\''rm -f -- "$f"'\'' EXIT; IFS= read -r -s -p "Enter saved off-host passphrase: " p </dev/tty; printf "\\n" >/dev/tty; printf "%s" "$p" >"$f"; unset p; RESTIC_REPOSITORY=/mnt/forgejo-backup/forgejo-restic RESTIC_PASSWORD_FILE="$f" /usr/local/bin/restic cat config >/dev/null; printf "Copied password unlocked the repository.\\n"'
```

Initialize only the new repository
----------------------------------

First confirm `/mnt/forgejo-backup` is the exact expected UUID-mounted ext4
filesystem and `/mnt/forgejo-backup/forgejo-restic` does not exist. Stop if the
repository path already exists; never point `init` at existing archives:

```sh
sudo env RESTIC_REPOSITORY=/mnt/forgejo-backup/forgejo-restic RESTIC_PASSWORD_FILE=/etc/forgejo-backup/password /usr/local/bin/restic init
```

Manual backup and accepted snapshot ID
--------------------------------------

Do not use a blocking `systemctl start` for an hours-long one-shot service. In
Terminal A, start asynchronously and follow its journal:

```sh
sudo systemctl daemon-reload
sudo systemctl start --no-block forgejo-restic-backup.service
sudo journalctl -fu forgejo-restic-backup.service
```

After it finishes successfully, inspect the accepted ID without exposing any
password, validate its format, and confirm that exact full ID exists in this
repository (never select a restore by `latest`):

```sh
SNAPSHOT_ID=$(sudo cat /var/lib/forgejo-backup/last-successful-snapshot)
printf '%s\n' "$SNAPSHOT_ID" | grep -Eq '^[0-9a-f]{64}$'
sudo env RESTIC_REPOSITORY=/mnt/forgejo-backup/forgejo-restic RESTIC_PASSWORD_FILE=/etc/forgejo-backup/password /usr/local/bin/restic snapshots "$SNAPSHOT_ID"
sudo env RESTIC_REPOSITORY=/mnt/forgejo-backup/forgejo-restic RESTIC_PASSWORD_FILE=/etc/forgejo-backup/password /usr/local/bin/restic check --read-data
```

Complete restore test on the spacious backup filesystem
-------------------------------------------------------

Before creating a restore directory, verify the exact backup mountpoint, UUID,
filesystem and read-write option. Query the accepted snapshot's restore size and
available bytes; proceed only when free space is at least the reported restore
size plus 20% headroom. Do not restore to `/var/tmp` or into the repository:

```sh
read -r UUID FSTYPE OPTIONS < <(findmnt --noheadings --output UUID,FSTYPE,OPTIONS --mountpoint /mnt/forgejo-backup)
test "$UUID" = d5c4224f-c02a-4d03-8941-dae8ade4c9b6 && test "$FSTYPE" = ext4 && [[ ",$OPTIONS," == *,rw,* ]]
SNAPSHOT_ID=$(sudo cat /var/lib/forgejo-backup/last-successful-snapshot)
sudo env RESTIC_REPOSITORY=/mnt/forgejo-backup/forgejo-restic RESTIC_PASSWORD_FILE=/etc/forgejo-backup/password /usr/local/bin/restic stats --mode restore-size "$SNAPSHOT_ID"
df --block-size=1 --output=avail /mnt/forgejo-backup
```

Compare the stats-reported restore size with the available-byte count and require
the stated 20% margin. Only then create a unique, private directory on this
verified mount and restore the complete data directory plus Compose YAML using
the accepted full ID:

```sh
RESTORE_DIR=$(sudo mktemp -d /mnt/forgejo-backup/forgejo-restore-test.XXXXXX)
sudo chmod 0700 "$RESTORE_DIR"
sudo env RESTIC_REPOSITORY=/mnt/forgejo-backup/forgejo-restic RESTIC_PASSWORD_FILE=/etc/forgejo-backup/password /usr/local/bin/restic restore "$SNAPSHOT_ID" --target "$RESTORE_DIR" --include '/media/Steam Dock/forgejo' --include '/home/cloudcassette/services/forgejo/compose.yaml'
sudo test -f "$RESTORE_DIR/media/Steam Dock/forgejo/gitea/gitea.db"
sudo test -f "$RESTORE_DIR/home/cloudcassette/services/forgejo/compose.yaml"
sudo sqlite3 "$RESTORE_DIR/media/Steam Dock/forgejo/gitea/gitea.db" 'PRAGMA integrity_check;'
```

Require SQLite to print exactly `ok`. Inspect SSH-key names and permissions,
not file contents:

```sh
sudo stat -c '%u:%g %a %n' "$RESTORE_DIR/media/Steam Dock/forgejo/ssh"
sudo find "$RESTORE_DIR/media/Steam Dock/forgejo/ssh" -maxdepth 1 -type f -printf '%f\n'
sudo find "$RESTORE_DIR/media/Steam Dock/forgejo/ssh" -maxdepth 1 -type f -name 'ssh_host_*_key' -exec stat -c '%u:%g %a %n' {} +
sudo env RESTIC_REPOSITORY=/mnt/forgejo-backup/forgejo-restic RESTIC_PASSWORD_FILE=/etc/forgejo-backup/password /usr/local/bin/restic ls "$SNAPSHOT_ID" '/media/Steam Dock/forgejo/ssh'
```

Expect the SSH directory to be `0:0 700` and private host-key files to be
`0:0 600`. After inspection, remove only the exact new restore directory made
by `mktemp`; do not touch the repository or other archives. Do not execute the
restored Compose file as root. File restoration and SQLite integrity do not
prove full application recovery; test recovery in an isolated environment
(separate ports, no live mounts/data) before claiming the application is
recoverable.

Two-terminal cancellation tests
-------------------------------

Use separate terminals and `--no-block`; never issue an ordinary synchronous
start and then stop from the same terminal. Keep the previously accepted ID for
comparison: interrupted or failed runs must leave it unchanged.

**Cancellation while Docker stop is in progress:** In Terminal A:

```sh
sudo systemctl start --no-block forgejo-restic-backup.service
sudo journalctl -fu forgejo-restic-backup.service
```

As soon as the journal shows `Stopping Forgejo with a 50-second grace period`,
use Terminal B to cancel while the Docker stop may still be outstanding:

```sh
sudo systemctl stop forgejo-restic-backup.service
```

The stop may take up to the reconciliation window (75 seconds). Confirm the
unit reports failure for this deliberate cancellation, the same container ID
is running, HTTP root is 200, and the accepted snapshot ID is unchanged. If the
script cannot determine whether stop settled, it fails closed and reports
uncertain state instead of claiming recovery.

**Cancellation while restic is running:** Repeat from Terminal A, but wait for
`starting bounded restic backup with JSON Lines summary capture` before using
Terminal B's `sudo systemctl stop forgejo-restic-backup.service`. Confirm the
container is running/HTTP 200 and the accepted ID did not change.

After both interruption tests, do a controlled reboot test and confirm Forgejo
returns running/HTTP 200 and the timer remains enabled:

```sh
sudo reboot
# After reconnect:
sudo docker inspect --format '{{.State.Running}}' forgejo
curl --fail --silent --output /dev/null --write-out '%{http_code}\n' http://192.168.86.4:3000/
systemctl list-timers forgejo-restic-backup.timer
```

Only after manual backup, `restic check --read-data`, full separate restore,
SQLite/SSH validation, and interruption/reboot tests, enable the local-time
05:30 daily timer (outside existing 02:00 and 03:00 user cron windows):

```sh
sudo systemctl enable --now forgejo-restic-backup.timer
systemctl list-timers forgejo-restic-backup.timer
```

No failure alert is configured; add and test one separately. No automatic
pruning/retention is configured. Do not add retention before restore is
verified.
