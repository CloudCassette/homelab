#!/usr/bin/env bash
set -Eeuo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 077

readonly RESTIC_BIN=/usr/local/bin/restic
readonly REPOSITORY=/mnt/forgejo-backup/home-system-restic
readonly PASSWORD_DIR=/etc/home-system-backup
readonly PASSWORD_FILE=/etc/home-system-backup/password
readonly BACKUP_MOUNT=/mnt/forgejo-backup
readonly HOME_SOURCE=/home/cloudcassette
readonly ETC_SOURCE=/etc
readonly ROOT_UUID=2d65ee0e-7126-4150-a47a-ac8b08f8bdd4
readonly BACKUP_UUID=d5c4224f-c02a-4d03-8941-dae8ade4c9b6
readonly STATE_DIR=/var/lib/home-system-backup
readonly ACCEPTED_ID_FILE=/var/lib/home-system-backup/last-successful-snapshot

fail() { printf 'home-system-restic-backup: ERROR: %s\n' "$*" >&2; exit 1; }
[[ "$EUID" -eq 0 && "$(id -u)" -eq 0 ]] || fail 'must run as root'
[[ "$(stat -c '%u:%g:%a' "$RESTIC_BIN" 2>/dev/null || true)" == '0:0:755' ]] || fail '/usr/local/bin/restic must be root:root mode 755'
restic_version=$("$RESTIC_BIN" version 2>/dev/null || true)
[[ "$restic_version" == "restic 0.19.1"* ]] || fail '/usr/local/bin/restic must be v0.19.1'
for cmd in findmnt flock timeout awk df stat python3 mktemp chmod chown mv rm mkdir realpath date; do
  command -v "$cmd" >/dev/null || fail "$cmd is unavailable"
done

# Serialize with the Forgejo backup service using the same lock inode; append mode avoids truncation.
exec 9>>/run/lock/forgejo-restic-backup.lock
flock --wait 1800 9 || fail 'could not acquire shared backup lock within 30 minutes; backup not started'

check_mount() {
  local mountpoint=$1 expected_uuid=$2 expected_fstype=$3 info uuid fstype options
  info=$(findmnt --noheadings --output UUID,FSTYPE,OPTIONS --mountpoint "$mountpoint") || fail "exact mountpoint is not mounted: $mountpoint"
  read -r uuid fstype options <<<"$info"
  [[ "$uuid" == "$expected_uuid" ]] || fail "wrong UUID at $mountpoint"
  [[ "$fstype" == "$expected_fstype" ]] || fail "wrong filesystem type at $mountpoint"
  [[ ",$options," == *,rw,* ]] || fail "$mountpoint is not read-write"
}

check_source_mount() {
  local source=$1 info target uuid fstype options
  info=$(findmnt -T "$source" --noheadings --output TARGET,UUID,FSTYPE,OPTIONS) || fail "cannot determine source filesystem for $source"
  read -r target uuid fstype options <<<"$info"
  [[ "$target" == / && "$uuid" == "$ROOT_UUID" && "$fstype" == ext4 && ",$options," == *,rw,* ]] || fail "$source is not on the expected root ext4 UUID mounted rw"
}

check_no_nested_mounts() {
  local path=$1
  python3 - "$path" <<'PYMOUNTS' || fail "mount exists at or below source/repository path: $path"
import os,re,sys
base=os.path.realpath(sys.argv[1])
def decode(s): return re.sub(r'\\([0-7]{3})',lambda m:chr(int(m.group(1),8)),s)
with open('/proc/self/mountinfo',encoding='utf-8') as f:
    targets=[decode(line.split()[4]) for line in f if len(line.split())>4]
for target in targets:
    try: below=os.path.commonpath((base,os.path.realpath(target)))==base
    except ValueError: below=False
    if below and (target==base or target.startswith(base.rstrip('/')+'/')):
        print('nested mount',file=sys.stderr); raise SystemExit(1)
PYMOUNTS
}

check_mount / "$ROOT_UUID" ext4
check_mount "$BACKUP_MOUNT" "$BACKUP_UUID" ext4
for src in "$HOME_SOURCE" "$ETC_SOURCE"; do
  [[ -d "$src" && ! -L "$src" ]] || fail "source directory missing or symlinked: $src"
  [[ "$(realpath -e "$src")" == "$src" ]] || fail "source path is not canonical: $src"
  check_source_mount "$src"
  check_no_nested_mounts "$src"
done
[[ -d "$REPOSITORY" && ! -L "$REPOSITORY" ]] || fail 'new restic repository directory is missing or a symlink'
[[ -f "$REPOSITORY/config" && -s "$REPOSITORY/config" && ! -L "$REPOSITORY/config" ]] || fail 'restic repository config missing or invalid'
[[ -d "$PASSWORD_DIR" && ! -L "$PASSWORD_DIR" ]] || fail 'password directory missing or unsafe'
[[ "$(stat -c '%u:%g:%a' "$PASSWORD_DIR")" == '0:0:700' ]] || fail 'password directory must be root:root mode 700'
[[ -f "$PASSWORD_FILE" && ! -L "$PASSWORD_FILE" && -r "$PASSWORD_FILE" ]] || fail 'password file missing or unreadable'
[[ "$(stat -c '%u:%g:%a' "$PASSWORD_FILE")" == '0:0:600' ]] || fail 'password must be root:root mode 600'
check_no_nested_mounts "$REPOSITORY"
available_bytes=$(df --block-size=1 --output=avail "$BACKUP_MOUNT" | awk 'NR==2 {print $1}')
[[ "$available_bytes" =~ ^[0-9]+$ ]] || fail 'could not determine backup free space'
(( available_bytes >= 200 * 1024 * 1024 * 1024 )) || fail 'backup filesystem has less than 200 GiB available'

# The accepted-ID directory is created/validated before a long backup can start.
[[ -d /var/lib && ! -L /var/lib ]] || fail '/var/lib missing or unsafe'
if [[ -L "$STATE_DIR" ]]; then
  fail 'accepted snapshot state directory must not be a symlink'
elif [[ -e "$STATE_DIR" ]]; then
  [[ -d "$STATE_DIR" && "$(stat -c '%u:%g:%a' "$STATE_DIR")" == '0:0:700' ]] || fail 'state directory must be root:root mode 700'
else
  mkdir -m 0700 -- "$STATE_DIR" || fail 'could not create accepted snapshot state directory'
fi
[[ "$(stat -c '%u:%g:%a' "$STATE_DIR")" == '0:0:700' ]] || fail 'state directory must be root:root mode 700'
if [[ -e "$ACCEPTED_ID_FILE" || -L "$ACCEPTED_ID_FILE" ]]; then
  [[ -f "$ACCEPTED_ID_FILE" && ! -L "$ACCEPTED_ID_FILE" ]] || fail 'accepted-ID path is not a regular file'
  [[ "$(stat -c '%u:%g:%a' "$ACCEPTED_ID_FILE")" == '0:0:600' ]] || fail 'accepted-ID file must be root:root mode 600'
  old_snapshot_id=$(<"$ACCEPTED_ID_FILE")
  [[ "$old_snapshot_id" =~ ^[0-9a-f]{64}$ ]] || fail 'existing accepted snapshot ID is malformed'
fi

export RESTIC_REPOSITORY="$REPOSITORY"
export RESTIC_PASSWORD_FILE="$PASSWORD_FILE"
"$RESTIC_BIN" cat config >/dev/null

snapshot_id_file=''
cleanup() {
  local rc=$?
  trap - EXIT
  trap '' HUP INT TERM
  if [[ -n "$snapshot_id_file" ]]; then rm -f -- "$snapshot_id_file" || true; fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
snapshot_id_file=$(mktemp /run/home-system-restic-snapshot-id.XXXXXX)
chmod 0600 "$snapshot_id_file"
printf '%s Starting encrypted home+system Restic backup.\n' "$(date -Is)"

if timeout --signal=TERM --kill-after=60s 3h "$RESTIC_BIN" backup --json \
  --one-file-system \
  --exclude '/home/cloudcassette/.cache' \
  --exclude '/home/cloudcassette/.local/share/Trash' \
  --tag home-system \
  "$HOME_SOURCE" "$ETC_SOURCE" |
  python3 -c '
import json,re,sys
path=sys.argv[1]
summary_id=None
summary_count=0
last_type=None
for line in sys.stdin:
    if not line.strip(): continue
    try: message=json.loads(line)
    except Exception:
        print("invalid restic JSON Lines output",file=sys.stderr); raise SystemExit(1)
    if not isinstance(message,dict):
        print("unexpected restic JSON message",file=sys.stderr); raise SystemExit(1)
    last_type=message.get("message_type")
    if last_type=="summary":
        summary_count+=1
        candidate=message.get("snapshot_id")
        if not isinstance(candidate,str) or not re.fullmatch(r"[0-9a-f]{64}",candidate):
            print("successful summary missing full snapshot_id",file=sys.stderr); raise SystemExit(1)
        summary_id=candidate
if summary_count!=1 or last_type!="summary" or summary_id is None:
    print("restic JSON Lines ended without one final successful summary snapshot_id",file=sys.stderr); raise SystemExit(1)
with open(path,"w",encoding="ascii") as f: f.write(summary_id+"\n")
' "$snapshot_id_file"; then
  snapshot_id=$(<"$snapshot_id_file")
else
  rc=$?
  fail "restic backup or summary parsing failed (exit $rc)"
fi
[[ "$snapshot_id" =~ ^[0-9a-f]{64}$ ]] || fail 'parsed snapshot ID is malformed'
rm -f -- "$snapshot_id_file"
snapshot_id_file=''

# Atomic same-filesystem replacement; the prior accepted ID remains on any prior failure.
tmp=$(mktemp "$STATE_DIR/.last-successful-snapshot.XXXXXX")
if ! printf '%s\n' "$snapshot_id" >"$tmp"; then rm -f -- "$tmp"; fail 'could not write accepted snapshot ID'
fi
if ! chown root:root "$tmp" || ! chmod 0600 "$tmp" || ! mv -fT -- "$tmp" "$ACCEPTED_ID_FILE"; then
  rm -f -- "$tmp"
  fail 'could not atomically commit accepted snapshot ID'
fi
printf '%s Backup succeeded; accepted snapshot ID recorded atomically.\n' "$(date -Is)"
