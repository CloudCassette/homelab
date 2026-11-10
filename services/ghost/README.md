# Ghost — cloudcassette.blog

Personal Ghost blog, restored Nov 2026 on the homelab from the Steam Dock
volume backups (Ghost 6.75 + MySQL 8.0, migrated from the old MySQL 5.7
datadir). Served via Cloudflare tunnel (`cloudcassette-blog-tunnel`, pinned
`cloudflare/cloudflared:2026.10.7`, host network → `localhost:2368`).

## Layout

- `docker-compose.yml` — Ghost + MySQL stack (externally-named volumes
  `cloudcassette_ghost_content` / `cloudcassette_ghost_mysql`; the MySQL
  datadir was upgraded 5.7 → 8.0 in place, pre-upgrade backup kept at
  `/media/Steam Dock/docker_backup_mysql8`).
- `theme/` — `tape-deck-v2` theme (cassette/J-card aesthetic, custom-built).
  Deploy: replace the theme dir in the container
  (`/var/lib/ghost/content/themes/tape-deck-v2`), then restart Ghost.
  Active theme lives in the `active_theme` setting (`tape-deck-v2`).

## Deploy

```bash
cd /home/cloudcassette
docker compose -f ghost-restore-compose.yaml up -d        # stack
docker compose -f ghost-restore-compose.yaml restart cloudcassette-ghost  # theme swap
```

Note: Ghost 6 templates need `{{!< default}}` as the first line and post
contexts wrapped in `{{#post}}` — both already handled in the theme.