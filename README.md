# homelab
Just a punk doing DevOps at home.

This is where I keep all the configurations for my homelab.

## 🏗️ **Infrastructure Architecture**

### **Repository Strategy**
- **🏠 This repo (homelab)**: Service configs (Docker Compose), encrypted backup jobs (restic + systemd), and operational scripts for the homelab server
- **🎸 [orlandopunx-infrastructure](http://192.168.86.4:3000/cloudcassette/orlandopunx-infrastructure)**: Ansible service configuration + Gancio event sync tooling (self-hosted on Forgejo; GitHub mirror at [github.com/CloudCassette/orlandopunx-infrastructure](https://github.com/CloudCassette/orlandopunx-infrastructure))
- **🔁 All repos mirrored to self-hosted Forgejo** at `http://192.168.86.4:3000/` (`ssh://git@192.168.86.4:2222`)

### **Technology Stack**
- **Docker Compose**: Container runtime with custom Steam Dock storage
- **Forgejo**: Self-hosted Git hosting (Docker, pinned LTS)
- **Restic**: Encrypted nightly backups to a dedicated 4 TB drive
- **Cloudflare Tunnels**: Secure external access with SSL termination
- **systemd**: Root-run backup services and timers
- **Portainer**: Container management UI

## 🖥️ **Homelab Server (`cassette-lab`)**

Single-server setup at `192.168.86.4` (LAN). Runs Linux with Docker Compose. Previously provisioned with Terraform; the actual infrastructure is now Compose + systemd, so all configs live in this repo's `services/` and `backup/` directories (git history preserves the old `terraform/` module).

### **Running Services** (`services/`)
| Service | Compose file | Ports | Notes |
|---|---|---|---|
| Forgejo | `services/forgejo/compose.yaml` | `3000` (HTTP), `2222` (SSH) | Git hosting; LAN-only, install locked, registration disabled, `restart: always` |
| WebDAV | `services/webdav/docker-compose.yml` | internal | Files served via Cloudflare tunnel; needs local `.env` (see `.env.example`) |
| OpenBao | `services/openbao/docker-compose.yml` | `192.168.86.4:8200` (HTTPS) | LAN-only secrets store; auto-unseal via static key (`/etc/openbao/secrets/unseal.key`), raft storage, daily sealed snapshots |
| cloudflared | `services/webdav/docker-compose.yml` | internal | Tunnel origin for `orlandopunx.com` |

### **Storage Layout**
| Filesystem | Mount | Purpose |
|---|---|---|
| `/dev/sdc1` (1.8 TB ext4) | `/media/Steam Dock` | Docker data + ROM collection (ext4 reserve lowered to 1%) |
| `/dev/sdd1` (4 TB ext4) | `/mnt/forgejo-backup` | Encrypted backups + ROM archive copy (UUID `d5c4224f-c02a-4d03-8941-dae8ade4c9b6`, via fstab `nofail,nodev,nosuid,noexec`) |

## 💾 **Backups (restic, encrypted, nightly)** (`backup/`)

Root-owned systemd units, installed from the staging files in this repo. Passphrases live in `/etc/*-backup/password` (root-only) **and** in the pass password manager off-host.

| Job | Timer | Content | Repository | Files here |
|---|---|---|---|---|
| Forgejo | 05:30 daily | `/media/Steam Dock/forgejo` + compose.yaml (briefly stops Forgejo for consistency) | `/mnt/forgejo-backup/forgejo-restic` | `backup/forgejo-restic/` |
| OpenBao | 06:15 daily | sealed raft snapshot (last 7) | `/mnt/forgejo-backup/openbao-snapshots` | `backup/openbao-snapshot/` |
| Home/system | 08:00 daily | `/home/cloudcassette` + `/etc` | `/mnt/forgejo-backup/home-system-restic` | `backup/home-system-restic/` |

Both verified: `restic check --read-data` passed and isolated restore tests succeeded. The old 02:00 rsync home backup is **paused** (2026-10-11, low disk space on `/media/Steam Dock`); the 08:00 restic job replaces it.

**Install** (see the README.md in each backup directory):
```bash
sudo install -o root -g root -m 0750 backup/forgejo-restic/backup.sh /usr/local/sbin/forgejo-restic-backup
sudo install -o root -g root -m 0644 backup/forgejo-restic/forgejo-restic-backup.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now forgejo-restic-backup.timer
```

## 🕹️ **ROM Archive (`retro-roms-best-set`)**

- ~514 GiB, 95 files, on `/media/Steam Dock/retro-roms-best-set`
- Full copy on backup drive at `/mnt/forgejo-backup/cassette-lab-steam-dock-archive/retro-roms-best-set` (SHA-256 verification in progress)
- Google Drive upload (`gdrive:Homelab Archive/retro-roms-best-set`): **paused** after repeated Wi-Fi outages; do not delete any local copy until the archive is verified and deletion is explicitly approved
- Verification tool: `tools/rom-verify/verify-roms.py` — read-only SHA-256 identity check between the two trees

## 📡 **Monitoring** (`scripts/`)

- **Network diagnostics**: `scripts/network-diagnostics/sample.sh` on cron every minute — logs Wi-Fi signal/router/external reachability to `~/network-diagnostics/sample.log`
- **Network self-heal**: `scripts/network-ensure/` (root systemd unit + 1-min timer) — restores the default route when the WiFi carrier event leaves the box reachable on LAN but with no route to the internet (see its README for the 2026-11-04 incident where the cloudflared tunnel crash-looped ~10 h because of exactly this)
- **Docker cleanup**: `scripts/docker-cleanup.sh` on cron weekly (Sundays 00:00) — prunes stopped containers, dangling images, networks, volumes
- **Desktop watcher** (`framework-pro`, not in this repo): user timer every 5 min, desktop alerts for ROM job and backup status — `~/.local/bin/forgejo-job-notify`

## 🚀 **Usage**

### **Service Deployment**
```bash
docker compose -f services/forgejo/compose.yaml up -d
docker compose -f services/webdav/docker-compose.yml up -d   # needs .env
```

### **Git Hosting (Forgejo)**
```bash
git remote add forgejo ssh://git@192.168.86.4:2222/cloudcassette/homelab.git
git push forgejo main
```

## 🔧 **Development**

### **Adding New Services**
1. Add a Compose file under `services/`
2. Deploy on the server (copy to `~/services/`, `docker compose up -d`)
3. Mirror the config here and push

**Infrastructure as code, punk edition.** 🎸⚡
