# OpenBao on cassette-lab

Single-node, **LAN-only**, auto-unsealing secrets store for the homelab.
OpenBao is the open-source fork of HashiCorp Vault (CNCF). Pinned to
`openbao/openbao:2.7.2`.

- **Storage**: `raft`, single node (`bao-node-1`), data at
  `/media/Steam Dock/openbao/data` (docker data area).
- **Unseal**: built-in `seal "static"` — a 32-byte AES-256-GCM key file at
  `/etc/openbao/secrets/unseal.key` on the host. Auto-unseals itself on every
  (re)boot, no cloud, no babysitting. **Whoever holds the key can unseal** —
  a copy MUST live off-host (the laptop's `pass` store) before it's relied on.
- **TLS**: terminated inside OpenBao with a self-signed cert (SAN:
  `IP:192.168.86.4`). No plaintext secret traffic on the LAN.
- **Access**: `https://192.168.86.4:8200` only — no tunnel, no internet
  surface. All clients (laptop `bao`, future homelab services) stay on-LAN.
- **Backup**: `backup/openbao-snapshot/` — daily sealed raft snapshot to
  `/mnt/forgejo-backup/openbao-snapshots`, keep last 7.

## Security model (read first)

- The unseal key is root-only on the host (`0600`, owned by the container's
  runtime uid so the service can read it — never world-readable). Anyone with
  **root on cassette-lab** or the **key copy in pass** can unseal. That's
  accepted homelab risk; no attacker with root there has much to gain from a
  locked store when they can read its keys anyway.
- Sealed snapshots are ciphertext — safe on the backup drive alongside restic.
- Root token + recovery keys go straight into `pass` on the laptop; never in
  this repo, never in shell history.
- The compose drops all Linux capabilities and runs `no-new-privileges`.

## Deploy (on cassette-lab, root for the /etc steps)

```sh
# 1. Staging + image
mkdir -p ~/services && cd ~/services
git clone ssh://git@192.168.86.4:2222/cloudcassette/homelab.git
cd homelab/services/openbao
docker pull openbao/openbao:2.7.2

# 2. Find the container's runtime uid (varies by base image) — record it:
docker run --rm openbao/openbao:2.7.2 id openbao
#    (typically uid=100 gid=1000 on the UBI build; use what it prints)

# 3. Host dirs + perms (data must be writable by that uid)
sudo mkdir -p "/media/Steam Dock/openbao/data" /etc/openbao/tls /etc/openbao/secrets
sudo chown -R openbao-uid:openbao-gid "/media/Steam Dock/openbao/data"   # from step 2
```

**TLS (self-signed CA so the laptop can verify):**

```sh
sudo openssl req -x509 -newkey rsa:4096 -nodes -days 3650 \
  -keyout /etc/openbao/tls/ca.key -out /etc/openbao/tls/ca.pem \
  -subj "/CN=cassette-lab OpenBao CA"
sudo openssl req -newkey rsa:2048 -nodes \
  -keyout /etc/openbao/tls/privkey.pem \
  -out /etc/openbao/tls/csr.pem \
  -subj "/CN=openbao.lan"
sudo sh -c 'echo "subjectAltName=IP:192.168.86.4,DNS:openbao.lan" > /etc/openbao/tls/ext.cnf'
sudo openssl x509 -req -days 3650 \
  -in /etc/openbao/tls/csr.pem \
  -CA /etc/openbao/tls/ca.pem -CAkey /etc/openbao/tls/ca.key -CAcreateserial \
  -extfile /etc/openbao/tls/ext.cnf \
  -out /etc/openbao/tls/fullchain.pem
sudo rm /etc/openbao/tls/csr.pem /etc/openbao/tls/ext.cnf
```

**Unseal key + presence in pass:**

```sh
sudo openssl rand -out /etc/openbao/secrets/unseal.key 32
sudo chmod 0600 /etc/openbao/secrets/unseal.key
sudo chown root:root /etc/openbao/secrets/unseal.key   # container uid reads via group-perms or chown per step 2
#   If the container uid can't read root:root 0600, instead:
#   sudo chown openbao-uid:root /etc/openbao/secrets/unseal.key && sudo chmod 0640 ...
# Off-host copy (laptop, into the pass store) — DO THIS NOW:
pass insert homelab/openbao/unseal.key     # paste the base64 of: openssl base64 -in unseal.key
```

For simplicity on the UBI build the unseal key can stay `0640 root:root`
(supplemental root group inside the container reads it).

**Config + compose + init:**

```sh
# copy-openbao-config   (root-owned, read-only mount is enforced by compose)
sudo cp config/openbao.hcl /etc/openbao/openbao.hcl && sudo chown root:root /etc/openbao/openbao.hcl && sudo chmod 0644 /etc/openbao/openbao.hcl
# adjust the mount in docker-compose.yml if needed, then:
docker compose up -d
docker compose exec openbao bao server -config=/openbao/config/openbao.hcl -verify-only
# or check via logs: docker logs openbao

# Sanity: config errors show here before init
docker logs openbao | tail

# Initialize (auto-unseal makes this ONCE): recovery keys, not Shamir
docker compose exec openbao bao operator init -key-shares=1 -key-threshold=1
# -> prints root token + the recovery key. Put BOTH in pass immediately:
pass insert homelab/openbao/root-token
pass insert homelab/openbao/recovery-key

# Confirm it came up unsealed
docker compose exec openbao bao status
curl -sk https://192.168.86.4:8200/v1/sys/health -o /dev/null -w '%{http_code}\n'   # 200
```

**Post-init defaults (one-time):**

```sh
# KV v2 at secret/ (default mount is v1)
docker compose exec openbao bao secrets enable -path=secret kv-v2
# Human login (your laptop)
docker compose exec openbao bao auth enable userpass
docker compose exec openbao bao policy write admin - <<'EOF'
path "secret/data/*"          { capabilities = ["create","read","update","delete","list"] }
path "secret/metadata/*"      { capabilities = ["list"] }
path "auth/token/lookup-self" { capabilities = ["read"] }
EOF
# Replace 'jordan' with your username; use a pass-generated password
pass generate homelab/openbao/user-jordan 24
docker compose exec openbao bao write auth/userpass/users/jordan \
  password="$(pass homelab/openbao/user-jordan)" policies=admin
```

**Laptop client (framework-pro / management station):**

```sh
# CA for verification
mkdir -p ~/.config/openbao && scp homelab:/etc/openbao/tls/ca.pem ~/.config/openbao/ca.pem
# bao binary (Silverblue: user-level, not layered)
curl -Lo /tmp/bao.tar.gz https://openbao.org/... # or: find it in the container:
docker exec openbao which bao   # copy to ~/.local/bin if your arch matches
cat >> ~/.bashrc <<'EOF'
export BAO_ADDR=https://192.168.86.4:8200
export BAO_CACERT=$HOME/.config/openbao/ca.pem
EOF
bao login -method=userpass -username=jordan
```

**Backup unit (root, on cassette-lab):**

```sh
sudo install -o root -g root -m 0750 backup/openbao-snapshot/snapshot.sh /usr/local/sbin/openbao-snapshot
sudo install -o root -g root -m 0644 backup/openbao-snapshot/openbao-snapshot.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl start openbao-snapshot.service     # first run while watching: journalctl -fu openbao-snapshot.service
ls -l /mnt/forgejo-backup/openbao-snapshots
sudo systemctl enable --now openbao-snapshot.timer
```

## Restore (worst case)

Fresh node, same or recovered unseal key, sealed then:

```sh
docker compose exec openbao bao operator raft snapshot restore /openbao/data/restore.snap
# (copy the .snap into the data dir first; restore puts the node into a
# restored state — re-init is not needed)
```

## Migrating existing secrets ("big ones next" — planned sprint)

- restic passphrases, cloudflared token, Forgejo secrets move into `secret/`
  with `approle` roles per consumer; `pass` remains the bootstrapping store.
- The `post-commit` hook / pass stays untouched until each consumer is wired.