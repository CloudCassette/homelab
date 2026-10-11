#!/usr/bin/env bash
set -Eeuo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 077

readonly RESTIC_BIN=/usr/local/bin/restic
readonly REPOSITORY=/mnt/forgejo-backup/forgejo-restic
readonly PASSWORD_FILE=/etc/forgejo-backup/password
readonly BACKUP_MOUNT=/mnt/forgejo-backup
readonly DATA_MOUNT='/media/Steam Dock'
readonly DATA_DIR='/media/Steam Dock/forgejo'
readonly COMPOSE_FILE=/home/cloudcassette/services/forgejo/compose.yaml
readonly CONTAINER=forgejo
readonly HTTP_URL=http://192.168.86.4:3000/
readonly REQUIRED_DATA_UUID=6ad67dcc-e3d3-4906-a0f9-c4fee067b74e
readonly REQUIRED_BACKUP_UUID=d5c4224f-c02a-4d03-8941-dae8ade4c9b6
readonly STATE_DIR=/var/lib/forgejo-backup
readonly SUCCESSFUL_SNAPSHOT_FILE=/var/lib/forgejo-backup/last-successful-snapshot

fail() { printf 'forgejo-restic-backup: ERROR: %s\n' "$*" >&2; exit 1; }

[[ "$EUID" -eq 0 ]] || fail 'must run as root'
[[ "$(id -u)" -eq 0 ]] || fail 'effective UID is not root'
[[ "$(stat -c '%u:%g:%a' "$RESTIC_BIN" 2>/dev/null || true)" == '0:0:755' ]] || fail '/usr/local/bin/restic must be root:root mode 755'
for cmd in docker findmnt flock curl python3 timeout awk df stat mktemp mv rm sleep chmod chown; do
  command -v "$cmd" >/dev/null || fail "$cmd is unavailable"
done
python3 -c 'import yaml' >/dev/null 2>&1 || fail 'python3-yaml is required to validate the Compose scope'

exec 9>/run/lock/forgejo-restic-backup.lock
flock -n 9 || fail 'another Forgejo backup holds the lock'

check_mount() {
  local mountpoint=$1 expected_uuid=$2 expected_fstype=$3 info uuid fstype options
  info=$(findmnt --noheadings --output UUID,FSTYPE,OPTIONS --mountpoint "$mountpoint") || fail "required exact mountpoint is not mounted: $mountpoint"
  read -r uuid fstype options <<<"$info"
  [[ "$uuid" == "$expected_uuid" ]] || fail "wrong UUID mounted at $mountpoint"
  [[ "$fstype" == "$expected_fstype" ]] || fail "wrong filesystem type mounted at $mountpoint"
  [[ ",$options," == *,rw,* ]] || fail "mount is not read-write: $mountpoint"
}

check_no_nested_mounts() {
  local path=$1
  python3 - "$path" <<'PYMOUNTS' || fail "nested mount found at or below $path"
import os,re,sys
base=os.path.realpath(sys.argv[1])
def decode_mount_path(s):
    return re.sub(r'\\([0-7]{3})',lambda m:chr(int(m.group(1),8)),s)
with open('/proc/self/mountinfo',encoding='utf-8') as f:
    targets=[decode_mount_path(line.split()[4]) for line in f if len(line.split())>4]
for target in targets:
    try: within=os.path.commonpath((base,os.path.realpath(target)))==base
    except ValueError: within=False
    if within and (target==base or target.startswith(base.rstrip('/')+'/')):
        print('nested mount',file=sys.stderr)
        raise SystemExit(1)
PYMOUNTS
}

check_mount "$DATA_MOUNT" "$REQUIRED_DATA_UUID" ext4
check_mount "$BACKUP_MOUNT" "$REQUIRED_BACKUP_UUID" ext4
[[ -d "$DATA_DIR" && ! -L "$DATA_DIR" ]] || fail 'Forgejo data directory is missing or is a symlink'
[[ -d "$DATA_DIR/gitea" && ! -L "$DATA_DIR/gitea" ]] || fail 'Forgejo gitea data directory is missing or is a symlink'
[[ -f "$DATA_DIR/gitea/gitea.db" && ! -L "$DATA_DIR/gitea/gitea.db" ]] || fail 'Forgejo SQLite database is missing or is a symlink'
[[ -f "$COMPOSE_FILE" && ! -L "$COMPOSE_FILE" && -r "$COMPOSE_FILE" ]] || fail 'Compose file is missing, a symlink, or unreadable'
[[ -d "$REPOSITORY" && ! -L "$REPOSITORY" ]] || fail 'restic repository directory is missing or is a symlink'
[[ -f "$REPOSITORY/config" && -s "$REPOSITORY/config" && ! -L "$REPOSITORY/config" ]] || fail 'restic repository config is missing or invalid'
[[ -f "$PASSWORD_FILE" && ! -L "$PASSWORD_FILE" && -r "$PASSWORD_FILE" ]] || fail 'restic password file is missing or unreadable'
[[ "$(stat -c '%u:%g:%a' "$PASSWORD_FILE")" == '0:0:600' ]] || fail 'password file must be root:root mode 600'
check_no_nested_mounts "$DATA_DIR"
check_no_nested_mounts "$REPOSITORY"

# Create or validate the private accepted-ID parent before stopping Forgejo.
[[ -d /var/lib && ! -L /var/lib ]] || fail '/var/lib is missing or unsafe'
if [[ -L "$STATE_DIR" ]]; then
  fail 'accepted-snapshot state directory must not be a symlink'
elif [[ -e "$STATE_DIR" ]]; then
  [[ -d "$STATE_DIR" && "$(stat -c '%u:%g:%a' "$STATE_DIR")" == '0:0:700' ]] || fail 'accepted-snapshot state directory must be root:root mode 700'
else
  mkdir -m 0700 -- "$STATE_DIR" || fail 'could not create accepted-snapshot state directory'
fi
[[ "$(stat -c '%u:%g:%a' "$STATE_DIR")" == '0:0:700' ]] || fail 'accepted-snapshot state directory must be root:root mode 700'
if [[ -e "$SUCCESSFUL_SNAPSHOT_FILE" || -L "$SUCCESSFUL_SNAPSHOT_FILE" ]]; then
  [[ -f "$SUCCESSFUL_SNAPSHOT_FILE" && ! -L "$SUCCESSFUL_SNAPSHOT_FILE" ]] || fail 'accepted-snapshot file is not a regular file'
  [[ "$(stat -c '%u:%g:%a' "$SUCCESSFUL_SNAPSHOT_FILE")" == '0:0:600' ]] || fail 'accepted-snapshot file must be root:root mode 600'
  previous_snapshot_id=$(<"$SUCCESSFUL_SNAPSHOT_FILE")
  [[ "$previous_snapshot_id" =~ ^[0-9a-f]{64}$ ]] || fail 'existing accepted snapshot ID is malformed'
fi

available_bytes=$(df --block-size=1 --output=avail "$BACKUP_MOUNT" | awk 'NR==2 {print $1}')
[[ "$available_bytes" =~ ^[0-9]+$ ]] || fail 'could not determine backup filesystem free space'
(( available_bytes >= 200 * 1024 * 1024 * 1024 )) || fail 'backup filesystem has less than 200 GiB available'

# Verify the Compose file describes only the supported Forgejo data scope; never execute it.
python3 - "$COMPOSE_FILE" "$DATA_DIR" <<'PYCOMPOSE' || fail 'Compose file scope is unexpected'
import pathlib,sys,yaml
path=pathlib.Path(sys.argv[1]); data_dir=sys.argv[2]
try: doc=yaml.safe_load(path.read_text())
except Exception: raise SystemExit('invalid Compose YAML')
if not isinstance(doc,dict) or set(doc.get('services',{}))!={'forgejo'}:
    raise SystemExit('expected only the Forgejo service')
service=doc['services']['forgejo']
if 'env_file' in service:
    raise SystemExit('env_file is outside the backup scope')
if service.get('restart')!='always':
    raise SystemExit('Compose restart policy must be always before scheduled backup')
if doc.get('volumes'):
    raise SystemExit('top-level/named volumes are outside the backup scope')
volumes=service.get('volumes',[])
if len(volumes)!=1 or not isinstance(volumes[0],dict):
    raise SystemExit('expected one explicit /data bind only')
v=volumes[0]
if v.get('type')!='bind' or v.get('source')!=data_dir or v.get('target')!='/data' or v.get('read_only',False):
    raise SystemExit('unexpected Compose data volume')
PYCOMPOSE

# Verify the existing repository and password before touching the Forgejo container.
export RESTIC_REPOSITORY="$REPOSITORY"
export RESTIC_PASSWORD_FILE="$PASSWORD_FILE"
"$RESTIC_BIN" cat config >/dev/null

# Pipe inspect JSON directly into Python. Only the validated immutable ID is emitted.
container_id=$(
  docker inspect --type container "$CONTAINER" |
    python3 -c '
import json,sys
try:
    obj=json.load(sys.stdin)[0]
except Exception:
    print("invalid Docker inspect response",file=sys.stderr); raise SystemExit(1)
labels=obj.get("Config",{}).get("Labels") or {}
expected={
    "com.docker.compose.project":"forgejo",
    "com.docker.compose.service":"forgejo",
    "com.docker.compose.project.working_dir":"/home/cloudcassette/services/forgejo",
    "com.docker.compose.project.config_files":"/home/cloudcassette/services/forgejo/compose.yaml",
}
if obj.get("Name")!="/forgejo": raise SystemExit("unexpected container name")
if obj.get("Config",{}).get("Image")!="codeberg.org/forgejo/forgejo:15.0.9": raise SystemExit("unexpected Forgejo image")
if any(labels.get(k)!=v for k,v in expected.items()): raise SystemExit("unexpected Forgejo Compose labels")
if obj.get("State",{}).get("Running") is not True: raise SystemExit("Forgejo is not initially running")
if obj.get("HostConfig",{}).get("RestartPolicy",{}).get("Name")!="always": raise SystemExit("container restart policy is not always")
mounts=obj.get("Mounts",[])
if len(mounts)!=1: raise SystemExit("expected exactly one container mount")
m=mounts[0]
if m.get("Type")!="bind" or m.get("Source")!="/media/Steam Dock/forgejo" or m.get("Destination")!="/data" or m.get("RW") is not True:
    raise SystemExit("unexpected /data bind mount")
container_id=obj.get("Id","")
if len(container_id)!=64 or any(c not in "0123456789abcdef" for c in container_id):
    raise SystemExit("invalid immutable container ID")
print(container_id)
'
) || fail 'Forgejo identity validation failed'
readonly CONTAINER_ID="$container_id"

container_state() {
  timeout --signal=TERM --kill-after=1s 3s docker inspect --type container \
    --format '{{.State.Running}} {{.State.ExitCode}} {{.RestartCount}} {{.State.StartedAt}}' "$CONTAINER_ID"
}
initial_state=$(container_state) || fail 'could not read initial Forgejo state by immutable ID'
read -r initial_running initial_exit initial_restart_count initial_started_at <<<"$initial_state"
[[ "$initial_running" == true ]] || fail 'Forgejo is not initially running'

snapshot_id_file=''
container_needs_restart=0
stop_request_in_progress=0
backup_succeeded=0
stopped_invariant_verified=0
stop_uncertain=0
restart_failed=0
health_verified=0
snapshot_id=''

wait_for_http() {
  local attempt code
  for attempt in {1..10}; do
    code=$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 2 "$HTTP_URL" 2>/dev/null || true)
    [[ "$code" == 200 ]] && return 0
    sleep 1
  done
  return 1
}

reconcile_pending_stop() {
  local deadline=$((SECONDS + 75)) state running exit_code restart_count started_at
  printf 'forgejo-restic-backup: reconciling an interrupted Docker stop request (up to 75 seconds)\n' >&2
  while (( SECONDS < deadline )); do
    state=$(container_state 2>/dev/null || true)
    if [[ -n "$state" ]]; then
      read -r running exit_code restart_count started_at <<<"$state" || true
      if [[ "$running" == false ]]; then
        stop_request_in_progress=0
        printf 'forgejo-restic-backup: Docker stop settled; original container is stopped\n' >&2
        return 0
      fi
    fi
    sleep 1
  done
  state=$(container_state 2>/dev/null || true)
  if [[ -n "$state" ]]; then
    read -r running exit_code restart_count started_at <<<"$state" || true
    if [[ "$running" == false ]]; then
      stop_request_in_progress=0
      printf 'forgejo-restic-backup: Docker stop settled at reconciliation deadline\n' >&2
      return 0
    fi
  fi
  stop_uncertain=1
  printf 'forgejo-restic-backup: ERROR: Docker stop remains uncertain after 75 seconds; refusing to assume container state\n' >&2
  return 1
}

record_accepted_snapshot() {
  local tmp
  [[ "$snapshot_id" =~ ^[0-9a-f]{64}$ ]] || return 1
  tmp=$(mktemp "$STATE_DIR/.last-successful-snapshot.XXXXXX") || return 1
  if ! printf '%s\n' "$snapshot_id" >"$tmp"; then rm -f -- "$tmp"; return 1; fi
  if ! chown root:root "$tmp" || ! chmod 0600 "$tmp" || ! mv -fT -- "$tmp" "$SUCCESSFUL_SNAPSHOT_FILE"; then
    rm -f -- "$tmp"
    return 1
  fi
  return 0
}

on_exit() {
  local original_rc=$? state running exit_code restart_count started_at start_rc=0
  trap - EXIT
  trap '' INT TERM HUP
  if (( stop_request_in_progress )); then
    reconcile_pending_stop || true
  fi
  if (( original_rc != 0 )); then
    printf 'forgejo-restic-backup: ERROR: backup/stop/verification failed (exit %s)\n' "$original_rc" >&2
  fi
  if (( container_needs_restart )); then
    state=$(container_state 2>/dev/null || true)
    running=${state%% *}
    if [[ "$running" == false ]]; then
      timeout --signal=TERM --kill-after=3s 15s docker start "$CONTAINER_ID" >/dev/null || start_rc=$?
      if (( start_rc != 0 )); then
        printf 'forgejo-restic-backup: ERROR: bounded docker start failed for original container ID (exit %s)\n' "$start_rc" >&2
        restart_failed=1
      fi
    elif [[ "$running" != true ]]; then
      printf 'forgejo-restic-backup: ERROR: original container state is uncertain; not issuing docker start\n' >&2
      restart_failed=1
      stop_uncertain=1
    fi
    state=$(container_state 2>/dev/null || true)
    read -r running exit_code restart_count started_at <<<"$state" || true
    if [[ "$running" != true ]]; then
      printf 'forgejo-restic-backup: ERROR: original Forgejo container is not confirmed running after restart attempt\n' >&2
      restart_failed=1
    elif wait_for_http; then
      health_verified=1
    else
      printf 'forgejo-restic-backup: ERROR: Forgejo did not return HTTP 200 at %s within the health deadline\n' "$HTTP_URL" >&2
      restart_failed=1
    fi
  fi
  if (( original_rc == 0 && backup_succeeded && stopped_invariant_verified && health_verified && !restart_failed && !stop_uncertain )); then
    if record_accepted_snapshot; then
      printf 'forgejo-restic-backup: accepted successful snapshot ID recorded atomically\n'
    else
      printf 'forgejo-restic-backup: ERROR: could not atomically record accepted snapshot ID\n' >&2
      restart_failed=1
    fi
  elif (( backup_succeeded )); then
    printf 'forgejo-restic-backup: snapshot not accepted because restart/health/exit checks did not all pass\n' >&2
  fi
  if [[ -n "$snapshot_id_file" ]]; then rm -f -- "$snapshot_id_file" || true; fi
  if (( restart_failed || stop_uncertain )); then exit 1; fi
  exit "$original_rc"
}
trap on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

snapshot_id_file=$(mktemp /run/forgejo-restic-snapshot-id.XXXXXX)
chmod 0600 "$snapshot_id_file"
container_needs_restart=1
stop_request_in_progress=1
printf 'Stopping Forgejo with a 50-second grace period; cancellation here is reconciled for up to 75 seconds.\n'
timeout --signal=TERM --kill-after=5s 55s docker stop --time 50 "$CONTAINER_ID" >/dev/null
stopped_state=$(container_state) || fail 'could not inspect Forgejo after stop'
read -r stopped_running stopped_exit_code stopped_restart_count stopped_started_at <<<"$stopped_state"
[[ "$stopped_running" == false ]] || fail 'Forgejo did not stop'
stop_request_in_progress=0
[[ "$stopped_exit_code" == 0 ]] || fail "Forgejo did not exit gracefully (exit code $stopped_exit_code; expected 0)"
[[ "$stopped_restart_count" == "$initial_restart_count" && "$stopped_started_at" == "$initial_started_at" ]] || fail 'Forgejo restarted while being stopped'
printf 'Forgejo stopped cleanly (exit 0); starting bounded restic backup with JSON Lines summary capture.\n'

if timeout --signal=TERM --kill-after=30s 1h "$RESTIC_BIN" backup --json --tag forgejo "$DATA_DIR" "$COMPOSE_FILE" |
  python3 -c '
import json,re,sys
path=sys.argv[1]
summary_id=None
last_type=None
summary_count=0
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
            print("successful summary missing a full snapshot_id",file=sys.stderr); raise SystemExit(1)
        summary_id=candidate
if summary_count!=1 or last_type!="summary" or summary_id is None:
    print("restic JSON Lines ended without one final successful summary snapshot_id",file=sys.stderr); raise SystemExit(1)
with open(path,"w",encoding="ascii") as f:
    f.write(summary_id+"\n")
' "$snapshot_id_file"; then
  snapshot_id=$(<"$snapshot_id_file")
else
  backup_rc=$?
  fail "restic backup or JSON summary validation failed (exit $backup_rc)"
fi
rm -f -- "$snapshot_id_file"
snapshot_id_file=''
[[ "$snapshot_id" =~ ^[0-9a-f]{64}$ ]] || fail 'restic summary snapshot ID is malformed'

# A successful restic command is invalid if Forgejo restarted during the backup.
after_backup_state=$(container_state) || fail 'could not verify Forgejo state after backup'
read -r after_running after_exit_code after_restart_count after_started_at <<<"$after_backup_state"
[[ "$after_running" == false && "$after_exit_code" == 0 ]] || fail 'Forgejo was not still cleanly stopped after backup; snapshot invalidated'
[[ "$after_restart_count" == "$initial_restart_count" && "$after_started_at" == "$initial_started_at" ]] || fail 'Forgejo restarted during backup; snapshot invalidated'
backup_succeeded=1
stopped_invariant_verified=1
printf 'Restic backup and stopped-container invariant verified; accepted-ID commit waits for restart and HTTP health.\n'
