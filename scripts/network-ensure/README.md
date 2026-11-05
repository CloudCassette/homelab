# network-ensure

Watchdog that guarantees the homelab always has a default route to the
internet, so the Cloudflare tunnels (including `webdav` → `cloudflared-dav`)
stay reachable.

## Why this exists

**Incident, 2026-11-04:** the server's WiFi link was healthy and the LAN
gateway/`192.168.86.1` responded (`sample.sh` reported `link=up router=up
external=down`), but there was **no default route**. Nothing on the box
maintains a static default route, so after a carrier event the route was never
restored: `ping 1.1.1.1` failed with `network is unreachable` and the tunnel
crash-looped for ~10 h (the WebDAV origin stayed up all along — the route loss
was purely a network-layer problem). Last good sample: `external=up`
2026-11-04T14:29; first hard evidence of the outage in
`~/network-diagnostics/sample.log` after that timestamp.

This unit restores the route automatically and logs transitions via
`systemd-cat -t network-ensure` (journal).

Complements `watchdog/wifi-watchdog` (also in this repo): that one handles a
genuinely dead Wi-Fi link (gateway + neighbor + WAN all unreachable), where
bouncing the link/`wpa_supplicant` is the fix. `network-ensure` handles the
opposite case that actually bit us — link healthy, gateway reachable, but no
default route — with a minimal one-line route add and no higher escalation.

## Behavior

- Runs as root as a oneshot via `network-ensure.timer`: ~1 min after boot, then
  every minute.
- If a working path to the internet exists, it does nothing.
- If the default route is missing **and** the link is up and the gateway is
  reachable, it runs `ip route add default via 192.168.86.1 dev wlp2s0` and
  verifies the result.
- Safe by construction: it only ever adds one fixed missing route; it never
  deletes, flushes, or rewrites routes, and never touches other interfaces.
- Logs on state transitions only (`/run/network-ensure/iface-state` records
  last state, so no per-minute journal spam).

## Variables

Override via the environment (applied by the unit/service, or by an
`Environment=` drop-in):
`NETWORK_ENSURE_IFACE` (default `wlp2s0`), `NETWORK_ENSURE_GATEWAY` (default
`192.168.86.1`).

## Install (as root on cassette-lab)

```sh
STAGE=/home/cloudcassette/homelab/scripts/network-ensure   # or your checkout path
sudo install -o root -g root -m 0750 "$STAGE/ensure-route.sh" /usr/local/sbin/network-ensure
sudo install -o root -g root -m 0644 "$STAGE/network-ensure.service" /etc/systemd/system/
sudo install -o root -g root -m 0644 "$STAGE/network-ensure.timer" /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now network-ensure.timer
systemctl list-timers network-ensure.timer
```

Manual run for an immediate check:

```sh
sudo systemctl start network-ensure.service
journalctl -t network-ensure -e
```

## Verify after install

- `ip route | grep default` shows `default via 192.168.86.1 dev wlp2s0`.
- `ping -c1 1.1.1.1` succeeds.
- `journalctl -t network-ensure --since today` shows the restored-route line.
- `docker logs cloudflared-dav 2>&1 | tail` shows `Registered tunnel
  connection` (tunnel back up), then PROPFIND your WebDAV URL to confirm.