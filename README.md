# homelab
Just a punk doing DevOps at home.

This is where I keep all the configurations for my homelab.

## 🏗️ **Infrastructure Architecture**

### **Repository Strategy**
- **🏠 This repo (homelab)**: Terraform infrastructure provisioning + homelab documentation
- **🎸 [orlandopunx-infrastructure](https://github.com/CloudCassette/orlandopunx-infrastructure)**: Ansible service configuration
- **🔁 Mirrored to self-hosted Forgejo** at `http://192.168.86.4:3000/` (`git@192.168.86.4:2222`)

### **Technology Stack**
- **Terraform**: Infrastructure provisioning and base resource creation
- **Ansible**: Service configuration and application deployment
- **Docker**: Container runtime with custom Steam Dock storage
- **Portainer**: Container management UI
- **Cloudflare Tunnels**: Secure external access with SSL termination
- **Forgejo**: Self-hosted Git hosting (Docker, pinned LTS)
- **Restic**: Encrypted nightly backups to a dedicated 4 TB drive

## 🖥️ **Homelab Server (`cassette-lab`)**

Single-server setup at `192.168.86.4` (LAN). Runs Fedora-style Linux with Docker Compose.

### **Running Services**
| Service | Port | Notes |
|---|---|---|
| Forgejo | `3000` (HTTP), `2222` (SSH) | Git hosting; LAN-only, install locked, registration disabled |
| webdav | internal | Existing WebDAV service |
| cloudflared-dav | internal | Cloudflare tunnel origin for `orlandopunx.com` |

### **Forgejo**
- Pinned image `codeberg.org/forgejo/forgejo:15.0.9` (LTS)
- Compose file: `~/services/forgejo/compose.yaml`, persistent data at `/media/Steam Dock/forgejo` → `/data`
- SQLite database, `restart: always`, `USER_UID/GID=1000`
- Admin account: `cloudcassette` (created locally, never in chat)

### **Storage Layout**
| Filesystem | Mount | Purpose |
|---|---|---|
| `/dev/sdc1` (1.8 TB ext4) | `/media/Steam Dock` | Docker data + ROM collection (ext4 reserve lowered to 1%) |
| `/dev/sdd1` (4 TB ext4) | `/mnt/forgejo-backup` | Encrypted backups + ROM archive copy (UUID `d5c4224f-c02a-4d03-8941-dae8ade4c9b6`, via fstab `nofail,nodev,nosuid,noexec`) |

## 💾 **Backups (restic, encrypted, nightly)**

Passphrases live in `/etc/*-backup/password` (root-only) **and** in the pass password manager off-host.

| Job | Timer | Content | Repository |
|---|---|---|---|
| Forgejo | 05:30 daily | `/media/Steam Dock/forgejo` + compose.yaml (briefly stops Forgejo for consistency) | `/mnt/forgejo-backup/forgejo-restic` |
| Home/system | 08:00 daily | `/home/cloudcassette` + `/etc` | `/mnt/forgejo-backup/home-system-restic` |

Installed as root-owned systemd units (`/usr/local/sbin/*-restic-backup`, service + timer). Both verified: `restic check --read-data` passed and isolated restore tests succeeded. The old 02:00 rsync home backup is **paused** (2026-10-11, low disk space on `/media/Steam Dock`); replace it with the restic job once verified history is reviewed.

## 🕹️ **ROM Archive (`retro-roms-best-set`)**

- ~514 GiB, 95 files, on `/media/Steam Dock/retro-roms-best-set`
- Full copy on backup drive at `/mnt/forgejo-backup/cassette-lab-steam-dock-archive/retro-roms-best-set` (SHA-256 verification in progress)
- Google Drive upload (`gdrive:Homelab Archive/retro-roms-best-set`): **paused** after repeated Wi-Fi outages; do not delete any local copy until the archive is verified and deletion is explicitly approved

## 📡 **Monitoring**

- **Network diagnostics**: cron every minute logging Wi-Fi signal/router/external reachability to `~/network-diagnostics/sample.log` (server survived a Wi-Fi drop; root cause under investigation — Wi-Fi loses the router while the server itself keeps running)
- **Desktop watcher** (`framework-pro`): user timer every 5 min, `systemd-notify`-style desktop alerts for ROM job and backup status — `~/.local/bin/forgejo-job-notify`

## 📁 **Current Modules**

### **Ghost Module** (`terraform/modules/ghost/`)
- Base Ghost container configuration
- Configurable ports and networking
- Integration ready for Ansible configuration management

## 🔗 **Service Integration**

### **Terraform → Ansible Flow**
1. **Terraform**: Provisions base infrastructure and Ghost containers
2. **Ansible**: Configures services, nginx, domains, and application settings
3. **Portainer**: Provides runtime management and monitoring

### **Current Deployments**
Managed by the orlandopunx-infrastructure Ansible configuration:
- **cloudcassette.blog**: Personal blog (port 2368)
- **orlandogirlsrockcamp.com**: Girls Rock Camp blog (port 2369) *ready for restoration*
- **tamtamthesandwichman.com**: Sandwich Man blog (port 2370) *planned*
- **godless-america.com**: Godless America blog (port 2371) *planned*

## 🚀 **Usage**

### **Infrastructure Provisioning**
```bash
cd terraform/
terraform init
terraform plan
terraform apply
```

### **Service Configuration**
```bash
cd ../orlandopunx-infrastructure/ansible/
ansible-playbook playbooks/site.yml --ask-vault-pass
```

### **Git Hosting (Forgejo)**
```bash
git remote add forgejo ssh://git@192.168.86.4:2222/cloudcassette/homelab.git
git push forgejo main
```

## 🔧 **Development**

### **Adding New Services**
1. Create Terraform module in this repo
2. Create Ansible role in orlandopunx-infrastructure repo
3. Deploy via Terraform → Ansible workflow

**Infrastructure provisioning and configuration management working together!** 🎸⚡
