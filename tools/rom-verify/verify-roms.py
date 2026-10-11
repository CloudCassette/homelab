#!/usr/bin/env python3
import argparse
import base64
import datetime as dt
import errno
import hashlib
import json
import os
import re
import signal
import stat
import subprocess
import sys
import tempfile
import time
from decimal import Decimal, ROUND_CEILING
from pathlib import Path

SOURCE = b"/media/Steam Dock/retro-roms-best-set"
ARCHIVE = b"/mnt/forgejo-backup/cassette-lab-steam-dock-archive/retro-roms-best-set"
SOURCE_MOUNT = b"/media/Steam Dock"
ARCHIVE_MOUNT = b"/mnt/forgejo-backup"
SOURCE_UUID = "6ad67dcc-e3d3-4906-a0f9-c4fee067b74e"
ARCHIVE_UUID = "d5c4224f-c02a-4d03-8941-dae8ade4c9b6"
EXPECTED_FILES = 95
CHUNK_SIZE = 1024 * 1024
MAX_SECONDS = 10 * 60 * 60
BACKUP_GUARD = 15 * 60
BACKUP_TIMES = ((5, 30), (8, 0))
REPORT_ROOT = Path.home() / "rom-verify" / "report"
MOUNT_ESCAPE = re.compile(rb"\\([0-7]{3})")


class VerificationFailure(Exception):
    pass


def now_local():
    return dt.datetime.now().astimezone().isoformat(timespec="seconds")


def ensure_private_dir(path):
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    st = path.lstat()
    if not stat.S_ISDIR(st.st_mode) or stat.S_ISLNK(st.st_mode):
        raise VerificationFailure(f"report directory is not a real directory: {path}")
    if st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) != 0o700:
        raise VerificationFailure(f"report directory must be owned by this user and mode 700: {path}")


def atomic_write(path, data, mode=0o600):
    path = Path(path)
    fd, temp_name = tempfile.mkstemp(prefix="." + path.name + ".", suffix=".tmp", dir=path.parent)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp_name, path)
        dirfd = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(dirfd)
        finally:
            os.close(dirfd)
    except BaseException:
        try:
            os.unlink(temp_name)
        except OSError:
            pass
        raise


def write_json(path, value):
    atomic_write(path, (json.dumps(value, sort_keys=True, ensure_ascii=True, indent=2) + "\n").encode("ascii"))


def create_run_dir(prefix="run"):
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    path = REPORT_ROOT / f"{prefix}-{stamp}-{os.getpid()}"
    path.mkdir(mode=0o700)
    os.chmod(path, 0o700)
    return path


def find_mount(target):
    proc = subprocess.run(
        ["findmnt", "--json", "--output", "TARGET,UUID,FSTYPE,OPTIONS", "--mountpoint", os.fsdecode(target)],
        capture_output=True, text=True, timeout=5, check=False,
    )
    if proc.returncode != 0:
        raise VerificationFailure(f"exact mountpoint unavailable: {os.fsdecode(target)}")
    try:
        parsed = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise VerificationFailure(f"cannot parse mountpoint information: {os.fsdecode(target)}: {exc}")
    entries = parsed.get("filesystems") or []
    if len(entries) != 1:
        raise VerificationFailure(f"expected exactly one filesystem entry at {os.fsdecode(target)}")
    entry = entries[0]
    return {"target": entry.get("target"), "uuid": entry.get("uuid"), "fstype": entry.get("fstype"), "options": entry.get("options")}


def require_mount(target, expected_uuid):
    info = find_mount(target)
    if info["target"] != os.fsdecode(target) or info["uuid"] != expected_uuid or info["fstype"] != "ext4":
        raise VerificationFailure(f"unexpected filesystem at {os.fsdecode(target)}")
    if "rw" not in info["options"].split(","):
        raise VerificationFailure(f"filesystem is not read-write: {os.fsdecode(target)}")
    return info


def decoded_mountpoints():
    result = []
    try:
        with open("/proc/self/mountinfo", "rb") as stream:
            for line in stream:
                fields = line.split()
                if len(fields) > 4:
                    result.append(MOUNT_ESCAPE.sub(lambda m: bytes([int(m.group(1), 8)]), fields[4]))
    except OSError as exc:
        raise VerificationFailure(f"cannot read mount table: {exc}")
    return result


def is_at_or_below(path, root):
    try:
        return os.path.commonpath((path, root)) == root
    except ValueError:
        return False


def check_no_nested_mounts(root, mounts=None):
    root_real = os.path.realpath(root)
    for target in mounts if mounts is not None else decoded_mountpoints():
        target_real = os.path.realpath(target)
        if target_real == root_real or (is_at_or_below(target_real, root_real) and target_real != root_real):
            raise VerificationFailure(f"nested mount found under scanned tree: {base64.b64encode(target).decode('ascii')}")


def next_backup_cutoff(now):
    candidates = []
    for offset in (0, 1):
        day = now.date() + dt.timedelta(days=offset)
        for hour, minute in BACKUP_TIMES:
            candidate = dt.datetime.combine(day, dt.time(hour, minute)).astimezone()
            if candidate > now:
                candidates.append(candidate)
    if not candidates:
        raise VerificationFailure("cannot determine next scheduled backup time")
    event = min(candidates)
    cutoff = event - dt.timedelta(seconds=BACKUP_GUARD)
    remaining = (cutoff - now).total_seconds()
    if remaining < 30 * 60:
        raise VerificationFailure("too close to the next 05:30/08:00 backup window; refusing to start")
    return cutoff, min(MAX_SECONDS, remaining)


def check_backup_services():
    for unit in ("forgejo-restic-backup.service", "home-system-restic-backup.service"):
        proc = subprocess.run(["systemctl", "is-active", unit], capture_output=True, text=True, timeout=5, check=False)
        state = proc.stdout.strip()
        if state in ("active", "activating", "reloading", "deactivating"):
            raise VerificationFailure(f"backup service is active: {unit}")
        if state not in ("inactive", "failed", "unknown", "not-found", ""):
            raise VerificationFailure(f"cannot establish backup service state for {unit}")
        if proc.returncode not in (0, 3, 4):
            raise VerificationFailure(f"cannot query backup service state for {unit}")


class RunGuard:
    def __init__(self, deadline):
        self.deadline = deadline
        self.next_check = 0.0

    def __call__(self, force=False):
        now = time.monotonic()
        if now >= self.deadline:
            raise VerificationFailure("10-hour/next-backup safety deadline reached; verification incomplete")
        if force or now >= self.next_check:
            require_mount(SOURCE_MOUNT, SOURCE_UUID)
            require_mount(ARCHIVE_MOUNT, ARCHIVE_UUID)
            mounts = decoded_mountpoints()
            check_no_nested_mounts(SOURCE, mounts)
            check_no_nested_mounts(ARCHIVE, mounts)
            check_backup_services()
            self.next_check = now + 60


def stable_signature(st):
    return (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns)


def metadata_signature(st):
    return stable_signature(st) + (stat.S_IMODE(st.st_mode), st.st_uid, st.st_gid)


def entry_type(st):
    if stat.S_ISDIR(st.st_mode):
        return "dir"
    if stat.S_ISREG(st.st_mode):
        return "file"
    if stat.S_ISLNK(st.st_mode):
        raise VerificationFailure("symlink found; refusing to follow or skip it")
    raise VerificationFailure("special file found; refusing to skip it")


def inventory(root, guard, manifest_path=None):
    root = os.path.realpath(root)
    root_stat = os.lstat(root)
    if not stat.S_ISDIR(root_stat.st_mode) or stat.S_ISLNK(root_stat.st_mode):
        raise VerificationFailure(f"scan root is not a real directory: {os.fsdecode(root)}")
    entries = {b"": {"type": "dir", "size": 0, "stat": root_stat}}
    stack = [(root, b"")]
    visited = 0
    while stack:
        guard()
        directory, relative_dir = stack.pop()
        try:
            with os.scandir(directory) as iterator:
                children = sorted(list(iterator), key=lambda item: item.name)
        except OSError as exc:
            raise VerificationFailure(f"directory scan failed at b64={base64.b64encode(relative_dir).decode('ascii')}: {exc}")
        dirs = []
        for child in children:
            guard()
            name = child.name
            relative = name if not relative_dir else relative_dir + b"/" + name
            full = os.path.join(directory, name)
            try:
                st = os.stat(full, follow_symlinks=False)
            except OSError as exc:
                raise VerificationFailure(f"lstat failed at b64={base64.b64encode(relative).decode('ascii')}: {exc}")
            kind = entry_type(st)
            entries[relative] = {"type": kind, "size": st.st_size if kind == "file" else 0, "stat": st}
            if kind == "dir":
                dirs.append((full, relative))
            visited += 1
            if visited % 128 == 0:
                guard(force=True)
        stack.extend(reversed(dirs))
    if manifest_path is not None:
        data = b"".join(json.dumps(manifest_record(path, entry), sort_keys=True, ensure_ascii=True).encode("ascii") + b"\n" for path, entry in sorted(entries.items()))
        atomic_write(manifest_path, data)
    return entries


def manifest_record(path, entry):
    st = entry["stat"]
    return {
        "path_b64": base64.b64encode(path).decode("ascii"),
        "type": entry["type"],
        "logical_size": entry["size"],
        "st_size": st.st_size,
        "mode": stat.S_IMODE(st.st_mode),
        "uid": st.st_uid,
        "gid": st.st_gid,
        "st_dev": st.st_dev,
        "st_ino": st.st_ino,
        "mtime_ns": st.st_mtime_ns,
        "ctime_ns": st.st_ctime_ns,
    }


def inventory_totals(entries):
    files = [entry for entry in entries.values() if entry["type"] == "file"]
    dirs = sum(1 for entry in entries.values() if entry["type"] == "dir")
    regular_bytes = sum(entry["size"] for entry in files)
    apparent_tree_bytes = sum(entry["stat"].st_size for entry in entries.values())
    return len(files), dirs, regular_bytes, apparent_tree_bytes


def compare_inventories(source, archive):
    differences = []
    source_paths = set(source)
    archive_paths = set(archive)
    for path in sorted(source_paths - archive_paths):
        differences.append({"kind": "missing_from_archive", "path_b64": base64.b64encode(path).decode("ascii")})
    for path in sorted(archive_paths - source_paths):
        differences.append({"kind": "extra_in_archive", "path_b64": base64.b64encode(path).decode("ascii")})
    for path in sorted(source_paths & archive_paths):
        left, right = source[path], archive[path]
        if left["type"] != right["type"]:
            differences.append({"kind": "type_mismatch", "path_b64": base64.b64encode(path).decode("ascii"), "source_type": left["type"], "archive_type": right["type"]})
        elif left["size"] != right["size"]:
            differences.append({"kind": "size_mismatch", "path_b64": base64.b64encode(path).decode("ascii"), "source_size": left["size"], "archive_size": right["size"]})
    return differences


def hash_regular_file(root, relative, expected_stat, guard, after_chunk=None):
    path = os.path.join(root, relative)
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except OSError as exc:
        raise VerificationFailure(f"open failed at b64={base64.b64encode(relative).decode('ascii')}: {exc}")
    digest = hashlib.sha256()
    bytes_read = 0
    chunk_index = 0
    try:
        before_fd = os.fstat(fd)
        before_path = os.stat(path, follow_symlinks=False)
        expected_sig = stable_signature(expected_stat)
        if stable_signature(before_fd) != expected_sig or stable_signature(before_path) != expected_sig:
            raise VerificationFailure(f"file changed before hash at b64={base64.b64encode(relative).decode('ascii')}")
        while True:
            guard()
            chunk = os.read(fd, CHUNK_SIZE)
            if not chunk:
                break
            digest.update(chunk)
            bytes_read += len(chunk)
            chunk_index += 1
            if after_chunk is not None and chunk_index == 1:
                after_chunk()
        after_fd = os.fstat(fd)
        after_path = os.stat(path, follow_symlinks=False)
        if stable_signature(after_fd) != expected_sig or stable_signature(after_path) != expected_sig:
            raise VerificationFailure(f"file changed during hash at b64={base64.b64encode(relative).decode('ascii')}")
        if bytes_read != expected_stat.st_size:
            raise VerificationFailure(f"short/long read at b64={base64.b64encode(relative).decode('ascii')}")
    finally:
        os.close(fd)
    return digest.hexdigest(), bytes_read


def write_hash_manifest(path, hashes, entries):
    records = []
    for relative in sorted(hashes):
        records.append({"path_b64": base64.b64encode(relative).decode("ascii"), "size": entries[relative]["size"], "sha256": hashes[relative]})
    data = b"".join(json.dumps(item, sort_keys=True).encode("ascii") + b"\n" for item in records)
    atomic_write(path, data)


def same_final_inventory(before, after):
    if set(before) != set(after):
        return False
    for path in before:
        a, b = before[path], after[path]
        if a["type"] != b["type"] or a["size"] != b["size"] or metadata_signature(a["stat"]) != metadata_signature(b["stat"]):
            return False
    return True


def next_backup_cutoff(now):
    candidates = []
    for offset in (0, 1):
        day = now.date() + dt.timedelta(days=offset)
        for hour, minute in BACKUP_TIMES:
            candidate = dt.datetime.combine(day, dt.time(hour, minute)).astimezone()
            if candidate > now:
                candidates.append(candidate)
    if not candidates:
        raise VerificationFailure("cannot determine next backup schedule")
    cutoff = min(candidates) - dt.timedelta(seconds=BACKUP_GUARD)
    remaining = (cutoff - now).total_seconds()
    if remaining < 30 * 60:
        raise VerificationFailure("too close to next 05:30/08:00 backup window; refusing to start")
    return min(MAX_SECONDS, remaining), cutoff.isoformat(timespec="seconds")


def run_self_test():
    ensure_private_dir(REPORT_ROOT)
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    summary_path = REPORT_ROOT / f"self-test-{stamp}-{os.getpid()}.json"
    checks = {"equal_tree": False, "one_byte_mismatch": False, "symlink_rejected": False, "mutation_during_hash_rejected": False, "hidden_and_empty_paths": False, "non_utf8_name_preserved": False}
    with tempfile.TemporaryDirectory(prefix=".rom-verify-selftest-", dir=REPORT_ROOT) as tmp:
        root = os.fsencode(tmp)
        src = os.path.join(root, b"source")
        dst = os.path.join(root, b"archive")
        os.mkdir(src, 0o700); os.mkdir(dst, 0o700)
        for base in (src, dst):
            os.mkdir(os.path.join(base, b"empty dir"), 0o700)
            for name, content in ((b"space name.rom", b"same-bytes" * 100), (b".hidden", b"hidden"), (b"odd-\xff-name", b"binary-name")):
                with open(os.path.join(base, name), "wb") as f: f.write(content)
        guard=lambda force=False: None
        left=inventory(src,guard); right=inventory(dst,guard)
        checks["hidden_and_empty_paths"]=b".hidden" in left and b"empty dir" in left
        checks["non_utf8_name_preserved"]=b"odd-\xff-name" in left
        inventory_ok=not compare_inventories(left,right)
        left_hash={p:hash_regular_file(src,p,e["stat"],guard)[0] for p,e in left.items() if e["type"]=="file"}
        right_hash={p:hash_regular_file(dst,p,e["stat"],guard)[0] for p,e in right.items() if e["type"]=="file"}
        checks["equal_tree"]=inventory_ok and left_hash==right_hash
        target=os.path.join(dst,b"space name.rom")
        with open(target,"r+b") as f: f.seek(0); f.write(b"X"); f.flush(); os.fsync(f.fileno())
        changed=inventory(dst,guard)
        changed_hash={p:hash_regular_file(dst,p,e["stat"],guard)[0] for p,e in changed.items() if e["type"]=="file"}
        checks["one_byte_mismatch"]=left_hash[b"space name.rom"]!=changed_hash[b"space name.rom"]
        os.symlink(b".hidden",os.path.join(src,b"unsafe-link"))
        try: inventory(src,guard)
        except VerificationFailure: checks["symlink_rejected"]=True
        os.unlink(os.path.join(src,b"unsafe-link"))
        mutate=os.path.join(src,b"mutate.bin")
        with open(mutate,"wb") as f: f.write(b"A"*(2*CHUNK_SIZE))
        mut_entries=inventory(src,guard)
        def mutate_file():
            with open(mutate,"r+b") as f: f.seek(0); f.write(b"Z"); f.flush(); os.fsync(f.fileno())
        try: hash_regular_file(src,b"mutate.bin",mut_entries[b"mutate.bin"]["stat"],guard,after_chunk=mutate_file)
        except VerificationFailure: checks["mutation_during_hash_rejected"]=True
    result="SELF-TEST PASS" if all(checks.values()) else "SELF-TEST FAIL"
    write_json(summary_path,{"result":result,"started_at":now_local(),"ended_at":now_local(),"real_trees_scanned":False,"checks":checks})
    print(f"{result}: {summary_path}")
    return 0 if all(checks.values()) else 1


def hard_deadline_alarm(signum, frame):
    signal.setitimer(signal.ITIMER_REAL, 0)
    raise VerificationFailure("wall-clock deadline reached; verification incomplete")


def run_preflight():
    ensure_private_dir(REPORT_ROOT)
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    summary_path = REPORT_ROOT / f"preflight-{stamp}-{os.getpid()}.json"
    result = "PREFLIGHT PASS"
    errors = []
    cutoff = None
    info = {}
    try:
        info["source"] = require_mount(SOURCE_MOUNT, SOURCE_UUID)
        info["archive"] = require_mount(ARCHIVE_MOUNT, ARCHIVE_UUID)
        if os.path.realpath(SOURCE) != SOURCE or os.path.realpath(ARCHIVE) != ARCHIVE:
            raise VerificationFailure("source/archive path resolves through a symlink")
        source_root_stat = os.lstat(SOURCE); archive_root_stat = os.lstat(ARCHIVE)
        if not stat.S_ISDIR(source_root_stat.st_mode) or not stat.S_ISDIR(archive_root_stat.st_mode):
            raise VerificationFailure("source/archive root is not a directory")
        if source_root_stat.st_dev == archive_root_stat.st_dev:
            raise VerificationFailure("source and archive appear on the same filesystem")
        mounts = decoded_mountpoints()
        check_no_nested_mounts(SOURCE, mounts); check_no_nested_mounts(ARCHIVE, mounts)
        check_backup_services()
        duration, cutoff = next_backup_cutoff(dt.datetime.now().astimezone())
    except BaseException as exc:
        result = "PREFLIGHT FAIL"
        errors.append(f"{type(exc).__name__}: {exc}")
    write_json(summary_path, {
        "result": result, "started_at": now_local(), "ended_at": now_local(),
        "real_trees_scanned": False, "source_mount_uuid": SOURCE_UUID,
        "archive_mount_uuid": ARCHIVE_UUID, "next_backup_cutoff": cutoff,
        "source_mount": info.get("source"), "archive_mount": info.get("archive"),
        "errors": errors,
    })
    print(f"{result}: {summary_path}")
    return 0 if result == "PREFLIGHT PASS" else 1


def run_real():
    ensure_private_dir(REPORT_ROOT)
    run_dir=create_run_dir()
    summary_path=run_dir/"summary.json"
    started=now_local()
    summary={"result":"NOT VERIFIED","started_at":started,"ended_at":None,"source_mount_uuid":SOURCE_UUID,"archive_mount_uuid":ARCHIVE_UUID,"source_path_b64":base64.b64encode(SOURCE).decode("ascii"),"archive_path_b64":base64.b64encode(ARCHIVE).decode("ascii"),"expected_regular_files":EXPECTED_FILES,"source_regular_files":None,"archive_regular_files":None,"source_regular_bytes":None,"archive_regular_bytes":None,"sha256_equal_files":0,"sha256_mismatches":0,"inventory_differences":0,"skipped_files":0,"errors":[]}
    write_json(summary_path,summary)
    try:
        require_mount(SOURCE_MOUNT,SOURCE_UUID)
        require_mount(ARCHIVE_MOUNT,ARCHIVE_UUID)
        if os.path.realpath(SOURCE)!=SOURCE or os.path.realpath(ARCHIVE)!=ARCHIVE:
            raise VerificationFailure("source/archive path resolves through a symlink")
        source_root_stat=os.lstat(SOURCE); archive_root_stat=os.lstat(ARCHIVE)
        if not stat.S_ISDIR(source_root_stat.st_mode) or not stat.S_ISDIR(archive_root_stat.st_mode):
            raise VerificationFailure("source/archive root is not a directory")
        if source_root_stat.st_dev==archive_root_stat.st_dev:
            raise VerificationFailure("source and archive appear on the same filesystem")
        mounts=decoded_mountpoints()
        check_no_nested_mounts(SOURCE,mounts); check_no_nested_mounts(ARCHIVE,mounts)
        wall_now=dt.datetime.now().astimezone()
        duration,next_backup=next_backup_cutoff(wall_now)
        deadline=time.monotonic()+duration
        signal.signal(signal.SIGALRM, hard_deadline_alarm)
        signal.setitimer(signal.ITIMER_REAL, duration)
        guard=RunGuard(deadline)
        guard(force=True)
        summary["next_backup_cutoff"]=next_backup
        summary["deadline_seconds"]=int(duration)
        source_entries=inventory(SOURCE,guard,run_dir/"source-inventory.jsonl")
        archive_entries=inventory(ARCHIVE,guard,run_dir/"archive-inventory.jsonl")
        source_count,source_dirs,source_bytes,source_apparent=inventory_totals(source_entries)
        archive_count,archive_dirs,archive_bytes,archive_apparent=inventory_totals(archive_entries)
        summary.update({"source_regular_files":source_count,"archive_regular_files":archive_count,"source_directories":source_dirs,"archive_directories":archive_dirs,"source_regular_bytes":source_bytes,"archive_regular_bytes":archive_bytes,"source_apparent_tree_bytes":source_apparent,"archive_apparent_tree_bytes":archive_apparent})
        inventory_diffs=compare_inventories(source_entries,archive_entries)
        summary["inventory_differences"]=len(inventory_diffs)
        atomic_write(run_dir/"inventory-differences.jsonl",b"".join(json.dumps(x,sort_keys=True).encode("ascii")+b"\n" for x in inventory_diffs))
        source_hashes={}; archive_hashes={}; source_hashed_bytes=0; archive_hashed_bytes=0
        for path in sorted(p for p,e in source_entries.items() if e["type"]=="file"):
            guard(); digest,n=hash_regular_file(SOURCE,path,source_entries[path]["stat"],guard); source_hashes[path]=digest; source_hashed_bytes+=n
        write_hash_manifest(run_dir/"source-sha256.jsonl",source_hashes,source_entries)
        for path in sorted(p for p,e in archive_entries.items() if e["type"]=="file"):
            guard(); digest,n=hash_regular_file(ARCHIVE,path,archive_entries[path]["stat"],guard); archive_hashes[path]=digest; archive_hashed_bytes+=n
        write_hash_manifest(run_dir/"archive-sha256.jsonl",archive_hashes,archive_entries)
        common_files=set(source_hashes)&set(archive_hashes)
        hash_mismatches=[p for p in sorted(common_files) if source_hashes[p]!=archive_hashes[p]]
        unmatched_hashed=(set(source_hashes)^set(archive_hashes))
        summary["sha256_equal_files"]=len(common_files)-len(hash_mismatches)
        summary["sha256_mismatches"]=len(hash_mismatches)+len(unmatched_hashed)
        summary["source_hashed_bytes"]=source_hashed_bytes
        summary["archive_hashed_bytes"]=archive_hashed_bytes
        atomic_write(run_dir/"sha256-differences.jsonl",b"".join(json.dumps({"path_b64":base64.b64encode(p).decode("ascii"),"kind":"hash_mismatch" if p in common_files else "unmatched"},sort_keys=True).encode("ascii")+b"\n" for p in sorted(set(hash_mismatches)|unmatched_hashed)))
        final_source=inventory(SOURCE,guard)
        final_archive=inventory(ARCHIVE,guard)
        source_stable=same_final_inventory(source_entries,final_source)
        archive_stable=same_final_inventory(archive_entries,final_archive)
        summary["source_stable_after_read"]=source_stable
        summary["archive_stable_after_read"]=archive_stable
        summary["source_archive_distinct_devices"]=source_root_stat.st_dev!=archive_root_stat.st_dev
        summary["skipped_files"]=0
        guard(force=True)
        count_ok=source_count==EXPECTED_FILES and archive_count==EXPECTED_FILES
        sizes_equal=source_bytes==archive_bytes
        match=(not inventory_diffs and sizes_equal and count_ok and not hash_mismatches and not unmatched_hashed and source_stable and archive_stable and source_hashed_bytes==source_bytes and archive_hashed_bytes==archive_bytes)
        summary["logical_sizes_equal"]=sizes_equal
        summary["apparent_tree_sizes_equal"]=source_apparent==archive_apparent
        summary["expected_file_count_matched"]=count_ok
        summary["result"]="VERIFIED" if match else "NOT VERIFIED"
        if not match:
            summary["errors"].append("inventory, count, size, hash, or final-stability comparison failed")
        signal.setitimer(signal.ITIMER_REAL, 0)
        summary["ended_at"]=now_local()
        summary["report_directory"]=str(run_dir)
        write_json(summary_path,summary)
        print(f"{summary['result']}: files={source_count}/{archive_count} regular_bytes={source_bytes}/{archive_bytes} equal_sha256={summary['sha256_equal_files']} hash_mismatches={summary['sha256_mismatches']} report={run_dir}")
        return 0 if match else 1
    except BaseException as exc:
        signal.setitimer(signal.ITIMER_REAL, 0)
        summary["result"]="NOT VERIFIED"
        summary["ended_at"]=now_local()
        summary.setdefault("errors",[]).append(f"{type(exc).__name__}: {exc}")
        summary["report_directory"]=str(run_dir)
        try: write_json(summary_path,summary)
        except Exception: pass
        print(f"NOT VERIFIED: {type(exc).__name__}: {exc}; report={run_dir}",file=sys.stderr)
        return 1


def main():
    parser=argparse.ArgumentParser(description="Read-only SHA-256 ROM collection identity verifier")
    parser.add_argument("--self-test",action="store_true",help="test only tiny synthetic fixtures under the private report directory")
    parser.add_argument("--preflight-only",action="store_true",help="verify mounts/windows/backup services read-only without scanning ROM trees")
    args=parser.parse_args()
    try:
        if args.self_test:
            return run_self_test()
        if args.preflight_only:
            return run_preflight()
        return run_real()
    except Exception as exc:
        print(f"NOT VERIFIED: {type(exc).__name__}: {exc}",file=sys.stderr)
        return 1


if __name__=="__main__":
    raise SystemExit(main())
