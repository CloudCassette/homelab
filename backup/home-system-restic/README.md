[Timer]
OnCalendar=*-*-* 08:00:00
Persistent=true
AccuracySec=1min
Unit=home-system-restic-backup.service

[Install]
WantedBy=timers.target
Home + system Restic backup staging (not installed or run)
==========================================================

Review independently before installation. The root-only script validates that
`/` is the expected ext4 root UUID and, for EACH source (`/home/cloudcassette`
and `/etc`), `findmnt -T` reports its containing target is exactly `/` with the
same UUID, ext4, and read-write. It also rejects nested mounts below either
source and below the repository. Destination is checked as an exact UUID-mounted
ext4 read-write mountpoint, with at least 200 GiB free. The script verifies the
root-owned Restic binary, password, existing repository config, and supported
Compose-free backup scope before running.

The script shares `/run/lock/forgejo-restic-backup.lock` with Forgejo backup and
waits at most 30 minutes for it; failure to acquire the lock is reported as a
failed service run, never silently skipped. Restic itself is bounded to 3 hours
plus a 60-second kill grace; the service limit is 4 hours. Only
`/home/cloudcassette` and `/etc` are backed up with `--one-file-system`. The only
exclusions are the exact home `.cache` and `.local/share/Trash` paths; there is
no broad temporary-file exclusion. No source files are written by the script.

The live home tree is not quiesced or snapshotted. Files changing during a run
may be captured at different times; application-consistent recovery is not
promised. `/etc/home-system-backup/password` is within `/etc` and is therefore
stored inside the encrypted repository. Preserve the independent off-host
passphrase copy. There is no automatic prune/retention or failure alert. Keep
existing dated backups and the paused 02:00 cron entry unchanged until a
replacement plan is independently reviewed.

Install after independent review
--------------------------------

Restic is already present at `/usr/local/bin/restic`; verify it and do not
replace it. Install only the staged script and units as root:

```bash
STAGE=/home/cloudcassette/home-system-backup-staging
sudo test "$(stat -c '%u:%g:%a' /usr/local/bin/restic)" = 0:0:755
/usr/local/bin/restic version  # require restic 0.19.1
sudo install -o root -g root -m 0750 "$STAGE/backup.sh" /usr/local/sbin/home-system-restic-backup
sudo install -o root -g root -m 0644 "$STAGE/home-system-restic-backup.service" /etc/systemd/system/home-system-restic-backup.service
sudo install -o root -g root -m 0644 "$STAGE/home-system-restic-backup.timer" /etc/systemd/system/home-system-restic-backup.timer
```

Passphrase creation and off-host copy
-------------------------------------

Create the password directory and file in one guarded privileged transaction.
If the directory or password already exists (including a symlink), the command
fails before changing either; it never overwrites credentials. The generated
secret is not printed:

```bash
sudo bash -c 'set -euo pipefail; umask 077; d=/etc/home-system-backup; p="$d/password"; [[ ! -e "$d" && ! -L "$d" ]]; mkdir -m 0700 "$d"; [[ "$(stat -c "%u:%g:%a" "$d")" == 0:0:700 ]]; [[ ! -e "$p" && ! -L "$p" ]]; set -o noclobber; openssl rand -base64 48 > "$p"; chown root:root "$p"; chmod 600 "$p"; [[ "$(stat -c "%u:%g:%a" "$p")" == 0:0:600 ]]'
```

In a private administrator terminal, view the generated password once using
`sudo cat /etc/home-system-backup/password` and enter it directly into an
off-host password manager. Never paste it into chat, screenshots, or logs, and
do not leave it on the clipboard. Keep the independent off-host copy before
relying on the repository.

Fail-closed initialization of only the new repository
------------------------------------------------------

Copy and run this whole Bash block as one unit. It performs every guard before
`restic init`; any failed check exits before initialization. It refuses an
existing target and explicitly verifies the separate Forgejo repository remains
present, but does not read, initialize, or modify that repository:

```bash
set -euo pipefail
fail() { printf 'STOP: %s\n' "$*" >&2; exit 1; }
REPO=/mnt/forgejo-backup/home-system-restic
PASS=/etc/home-system-backup/password
INFO=$(findmnt --noheadings --output TARGET,UUID,FSTYPE,OPTIONS --mountpoint /mnt/forgejo-backup) || fail 'backup mountpoint missing'
read -r TARGET UUID FSTYPE OPTIONS <<<"$INFO"
[[ "$TARGET" == /mnt/forgejo-backup && "$UUID" == d5c4224f-c02a-4d03-8941-dae8ade4c9b6 && "$FSTYPE" == ext4 && ",$OPTIONS," == *,rw,* ]] || fail 'wrong backup mount'
[[ -d /mnt/forgejo-backup/forgejo-restic && ! -L /mnt/forgejo-backup/forgejo-restic ]] || fail 'existing Forgejo repository missing or unsafe'
[[ ! -e "$REPO" && ! -L "$REPO" ]] || fail 'new home-system repository path already exists; do not overwrite'
[[ "$(stat -c '%u:%g:%a' /usr/local/bin/restic)" == 0:0:755 ]] || fail 'Restic binary must be root:root mode 755'
[[ "$(/usr/local/bin/restic version)" == 'restic 0.19.1'* ]] || fail 'unexpected Restic version'
sudo test -d /etc/home-system-backup || fail 'password directory missing'
sudo test ! -L /etc/home-system-backup || fail 'password directory is a symlink'
[[ "$(sudo stat -c '%u:%g:%a' /etc/home-system-backup)" == 0:0:700 ]] || fail 'password directory must be root:root mode 700'
sudo test -f "$PASS" || fail 'password file missing'
sudo test ! -L "$PASS" || fail 'password file is a symlink'
[[ "$(sudo stat -c '%u:%g:%a' "$PASS")" == 0:0:600 ]] || fail 'password file must be root:root mode 600'
sudo test -d /mnt/forgejo-backup/forgejo-restic || fail 'existing Forgejo repository is missing'
sudo test ! -L /mnt/forgejo-backup/forgejo-restic || fail 'existing Forgejo repository path is a symlink'
sudo env RESTIC_REPOSITORY="$REPO" RESTIC_PASSWORD_FILE="$PASS" /usr/local/bin/restic init
```

After initialization, validate the saved off-host copy without putting the
secret in argv or environment. Run this in a private interactive terminal and
type/paste the passphrase at the silent prompt; the root-only temporary file in
`/run` is removed on exit:

```bash
sudo bash -c 'set -euo pipefail; umask 077; f=$(mktemp /run/home-system-password-check.XXXXXX); trap '\''rm -f -- "$f"'\'' EXIT; IFS= read -r -s -p "Enter saved off-host passphrase: " p </dev/tty; printf "\\n" >/dev/tty; printf "%s" "$p" >"$f"; unset p; RESTIC_REPOSITORY=/mnt/forgejo-backup/home-system-restic RESTIC_PASSWORD_FILE="$f" /usr/local/bin/restic cat config >/dev/null; printf "Copied password unlocked the repository.\\n"'
```

Manual backup and repository verification
-----------------------------------------

Install/reload the service and start the manual backup asynchronously; do not
enable the timer until the restore test succeeds:

```bash
sudo systemctl daemon-reload
sudo systemctl start --no-block home-system-restic-backup.service
sudo journalctl -fu home-system-restic-backup.service
```

The script records an accepted full snapshot ID only after a successful Restic
JSON Lines summary (`message_type=summary`, full `snapshot_id`; see the official
scripting documentation at
https://restic.readthedocs.io/en/stable/075_scripting.html). Check and validate
the ID before issuing any later Restic command; the guard exits on an empty or
malformed ID:

```bash
set -euo pipefail
ID_DIR=/var/lib/home-system-backup
ID_FILE=$ID_DIR/last-successful-snapshot
[[ -d "$ID_DIR" && ! -L "$ID_DIR" && "$(sudo stat -c '%u:%g:%a' "$ID_DIR")" == 0:0:700 ]]
[[ "$(sudo stat -c '%u:%g:%a' "$ID_FILE")" == 0:0:600 ]]
SNAPSHOT_ID=$(sudo cat "$ID_FILE")
[[ "$SNAPSHOT_ID" =~ ^[0-9a-f]{64}$ ]] || { printf 'Invalid accepted snapshot ID; stop.\n' >&2; exit 1; }
sudo env RESTIC_REPOSITORY=/mnt/forgejo-backup/home-system-restic RESTIC_PASSWORD_FILE=/etc/home-system-backup/password /usr/local/bin/restic snapshots "$SNAPSHOT_ID"
sudo env RESTIC_REPOSITORY=/mnt/forgejo-backup/home-system-restic RESTIC_PASSWORD_FILE=/etc/home-system-backup/password /usr/local/bin/restic check --read-data
```

Full separate restore test on the backup filesystem
---------------------------------------------------

Run this as one guarded Bash block. It validates the exact destination mount,
accepted full snapshot ID and repository password before creating a restore
path. It queries `restic stats --mode restore-size`, parses `Total Size`, checks
free bytes with at least 20% headroom, and aborts on any missing/unparseable
size or failed guard. The unique restore path is created only after all checks:

```bash
set -euo pipefail
fail() { printf 'STOP: %s\n' "$*" >&2; exit 1; }
REPO=/mnt/forgejo-backup/home-system-restic
PASS=/etc/home-system-backup/password
ID_DIR=/var/lib/home-system-backup
ID_FILE=$ID_DIR/last-successful-snapshot
INFO=$(findmnt --noheadings --output TARGET,UUID,FSTYPE,OPTIONS --mountpoint /mnt/forgejo-backup) || fail 'backup mountpoint missing'
read -r TARGET UUID FSTYPE OPTIONS <<<"$INFO"
[[ "$TARGET" == /mnt/forgejo-backup && "$UUID" == d5c4224f-c02a-4d03-8941-dae8ade4c9b6 && "$FSTYPE" == ext4 && ",$OPTIONS," == *,rw,* ]] || fail 'wrong backup mount'
sudo test -d /etc/home-system-backup || fail 'password directory missing'
sudo test ! -L /etc/home-system-backup || fail 'password directory is a symlink'
[[ "$(sudo stat -c '%u:%g:%a' /etc/home-system-backup)" == 0:0:700 ]] || fail 'password directory permissions/owner invalid'
sudo test -f "$PASS" || fail 'password file missing'
sudo test ! -L "$PASS" || fail 'password file is a symlink'
[[ "$(sudo stat -c '%u:%g:%a' "$PASS")" == 0:0:600 ]] || fail 'password file permissions/owner invalid'
[[ -d "$ID_DIR" && ! -L "$ID_DIR" && "$(sudo stat -c '%u:%g:%a' "$ID_DIR")" == 0:0:700 ]] || fail 'accepted-ID directory must be root:root mode 700'
[[ "$(stat -c '%u:%g:%a' /usr/local/bin/restic)" == 0:0:755 && "$(/usr/local/bin/restic version)" == 'restic 0.19.1'* ]] || fail 'Restic binary ownership/mode/version invalid'
sudo test -d "$REPO" || fail 'restic repository directory missing'
sudo test ! -L "$REPO" || fail 'restic repository path is a symlink'
sudo test -s "$REPO/config" || fail 'restic repository config missing or empty'
sudo test ! -L "$REPO/config" || fail 'restic repository config is a symlink'
[[ "$(sudo stat -c '%u:%g:%a' "$ID_FILE")" == 0:0:600 ]] || fail 'accepted ID file permissions/owner invalid'
SNAPSHOT_ID=$(sudo cat "$ID_FILE")
[[ "$SNAPSHOT_ID" =~ ^[0-9a-f]{64}$ ]] || fail 'accepted full snapshot ID is invalid'
sudo env RESTIC_REPOSITORY="$REPO" RESTIC_PASSWORD_FILE="$PASS" /usr/local/bin/restic cat config >/dev/null
sudo env RESTIC_REPOSITORY="$REPO" RESTIC_PASSWORD_FILE="$PASS" /usr/local/bin/restic snapshots "$SNAPSHOT_ID" >/dev/null
STATS=$(sudo env RESTIC_REPOSITORY="$REPO" RESTIC_PASSWORD_FILE="$PASS" /usr/local/bin/restic stats --mode restore-size "$SNAPSHOT_ID")
printf '%s\n' "$STATS"
RESTORE_BYTES=$(printf '%s\n' "$STATS" | python3 -c 'from decimal import Decimal,ROUND_CEILING; import re,sys; s=sys.stdin.read(); m=re.search(r"(?m)^Total Size:\s*([0-9]+(?:\.[0-9]+)?)\s*(B|Bytes?|kB|MB|GB|TB|KiB|MiB|GiB|TiB|PiB)\s*$",s); u={"B":1,"Byte":1,"Bytes":1,"kB":1000,"MB":1000**2,"GB":1000**3,"TB":1000**4,"KiB":1024,"MiB":1024**2,"GiB":1024**3,"TiB":1024**4,"PiB":1024**5}; assert m and m.group(2) in u,"cannot parse Total Size; abort"; print(int((Decimal(m.group(1))*u[m.group(2)]).to_integral_value(rounding=ROUND_CEILING)))') || fail 'could not determine required restore size'
[[ "$RESTORE_BYTES" =~ ^[0-9]+$ ]] || fail 'invalid restore size'
AVAILABLE_BYTES=$(df --block-size=1 --output=avail /mnt/forgejo-backup | awk 'NR==2 {print $1}')
[[ "$AVAILABLE_BYTES" =~ ^[0-9]+$ ]] || fail 'could not determine free capacity'
REQUIRED_BYTES=$((RESTORE_BYTES + (RESTORE_BYTES + 4) / 5))
(( AVAILABLE_BYTES >= REQUIRED_BYTES )) || fail 'insufficient free space for restore plus 20% headroom'
printf 'Capacity guard passed: restore=%s bytes free=%s bytes required-with-headroom=%s bytes.\n' "$RESTORE_BYTES" "$AVAILABLE_BYTES" "$REQUIRED_BYTES"
RESTORE_DIR=$(sudo mktemp -d /mnt/forgejo-backup/home-system-restore-test.XXXXXX)
sudo chmod 0700 "$RESTORE_DIR"
printf 'Created private restore review path: %s\n' "$RESTORE_DIR"
sudo env RESTIC_REPOSITORY="$REPO" RESTIC_PASSWORD_FILE="$PASS" /usr/local/bin/restic restore "$SNAPSHOT_ID" --target "$RESTORE_DIR"
sudo test -f "$RESTORE_DIR/etc/passwd"
sudo test -f "$RESTORE_DIR/etc/hostname"
sudo test -d "$RESTORE_DIR/home/cloudcassette"
sudo stat -c '%u:%g %a %n' "$RESTORE_DIR/etc/passwd" "$RESTORE_DIR/etc/hostname" "$RESTORE_DIR/home/cloudcassette"
if sudo test -d "$RESTORE_DIR/home/cloudcassette/.ssh"; then sudo stat -c '%u:%g %a %n' "$RESTORE_DIR/home/cloudcassette/.ssh"; fi
```

Keep and review the printed `RESTORE_DIR` path. Do not restore over live paths or
execute restored configuration as root. Inspect representative files and
modes; do not print secrets. Do not remove the restore directory as part of this
procedure. After reviewing that exact path, separately approve any cleanup; do
not touch the repository or dated archives.

Only after manual backup, `restic check --read-data`, and restore review succeed,
enable the daily local-time 08:00 timer (after the 03:00 user job and 05:30
Forgejo timer):

```bash
sudo systemctl enable --now home-system-restic-backup.timer
systemctl list-timers home-system-restic-backup.timer
```

No retention/pruning or failure alert is configured. Plan and test those
separately after restore validation.
