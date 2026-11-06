# OpenSSH musl password-auth bypass — audit & status

CVE-type finding: Wakefield "sshhole" — OpenSSH on **musl** (Alpine) without
PAM can accept *any* password of 257–1024 chars for accounts whose password
field is `*` (no password set), when **password login is enabled** and at least
one account has a real SHA-256/512 hash. Fix: OpenSSH **10.6p2** (2026-11-05).
Full write-up: https://wakefield.co/research/openssh-musl-authentication-bypass

## Audit (2026-11-06)

| Surface | libc | sshd? | Verdict |
|---|---|---|---|
| `cassette-lab` (Debian 12) | glibc | yes (host) | **Not affected** (glibc) |
| `framework-pro` (Fedora Silverblue) | glibc | not running | **Not affected** |
| `media-server` (Debian 13) | glibc | yes | **Not affected** (glibc) |
| Forgejo container (Alpine) | **musl** | **yes** (`sshd -D`, port 2222) | **Not exploitable** (gates below) |
| openbao / webdav / cloudflared containers | musl (Alpine) | no sshd | **Not affected** |

## Why the Forgejo container is not exploitable

Exploit preconditions vs. reality inside `codeberg.org/forgejo/forgejo:15.0.9`:

1. musl + OpenSSH without PAM — **present** (the reason this needs watching).
2. `PasswordAuthentication` — **`no`** (`/etc/ssh/sshd_config`).
3. `PermitRootLogin` — **`no`**.
4. Account with a real SHA-512 hash — **absent**: 0 of 19 entries have a
   `$6$`/`$5$` hash (all `*`/empty). The bypass requires at least one.
5. History: **zero** `Accepted password`/`Failed password` in the container's
   sshd logs → no evidence of past use.

So: three independent gates are closed; the advisory's final trigger (real
hash present) is missing entirely.

## Watching / hardening plan

- The durable fix is a rebuilt Forgejo image carrying patched OpenSSH
  (OpenSSH ≥10.6p2, or Alpine `openssh-server` ≥ `10.2_p1-r1` with the
  backport). **TODO: when `docker pull codeberg.org/forgejo/forgejo:15.0.9`
  reports a new digest, recheck:**
  ```sh
  docker run --rm --entrypoint /usr/sbin/sshd codeberg.org/forgejo/forgejo:15.0.9 -V
  docker exec forgejo sh -c 'apk list -I | grep openssh-server'
  ```
  then recreate the container (`docker compose up -d --force-recreate`) and
  re-verify the Forgejo restic backup still passes (the backup unit validates
  the container image/ID — re-run `forgejo-restic-backup.service` after).
- Do NOT enable `PasswordAuthentication` in the Forgejo sshd; Forgejo SSH is
  key-only by design.
- Interim in-container `apk upgrade openssh` was attempted; carries the fix
  **only once the repos serve `openssh-server` ≥ r1** — currently they don't,
  so leave it to the image bump rather than forcing a mixed-version upgrade.
- Meta-package `openssh` was moved to `10.2_p1-r1` in the live container
  (harmless; the server binary is untouched).