# wifi-watchdog

Self-healing Wi-Fi link watchdog for **cassette-lab** (the homelab box at
`192.168.86.4`, ThinkCentre M93p running on an Intel Centrino Wireless-N 2230
card). Long-uptime Wi-Fi wedges take down LAN reachability *and* the outbound
cloudflared tunnel at once — this recovers the link without pressing the
power button, and leaves forensic evidence when it strikes.

## Files

| File | Installed to | Description |
|---|---|---|
| `wifi-watchdog.sh` | `/usr/local/sbin/wifi-watchdog.sh` (0755, root) | Detection + staged recovery script |
| `wifi-watchdog.service` | `/etc/systemd/system/wifi-watchdog.service` | Oneshot unit running the script |
| `wifi-watchdog.timer` | `/etc/systemd/system/wifi-watchdog.timer` | Fires the service every 2 minutes |

## Behavior

Every 2 minutes the script pings three targets from the box itself:

| Target | Purpose |
|---|---|
| `192.168.86.1` (gateway) | Is the Wi-Fi link working? |
| `192.168.86.40` (media server) | LAN alive? (answers + dead gateway = router problem, not Wi-Fi) |
| `1.1.1.1` (WAN) | Full outbound path (cloudflared tunnel health) |

Only when **all three** are unreachable is a wedge assumed; escalation is
staged by consecutive failed checks (~2 min apart):

| Fails | Action | Elapsed |
|---|---|---|
| 3 | `ip link set wlp2s0 down/up` (force reassociation) | ~6 min |
| 5 | `systemctl restart wpa_supplicant` | ~10 min |
| 8 | `systemctl reboot` | ~16 min |

Gateway dead but the media server answers (or WAN reachable) → logs and holds;
bouncing Wi-Fi will not fix a dead router, and rebooting the box for a WAN
outage would needlessly take it offline.

## Logs

- **`/var/log/wifi-watchdog.log`** — persistent per-check history: every
  failed check records the failure count and the raw `/proc/net/wireless`
  state (link quality / level), plus recovery events and each escalation step.
- Counters live in `/run/wifi-watchdog.state` (tmpfs) so every boot starts
  clean; the script is `flock`-protected against overlapping runs.

## Install

```bash
sudo install -m 755 wifi-watchdog.sh /usr/local/sbin/wifi-watchdog.sh \
  && sudo install -m 644 wifi-watchdog.service /etc/systemd/system/ \
  && sudo install -m 644 wifi-watchdog.timer /etc/systemd/system/ \
  && sudo systemctl daemon-reload \
  && sudo systemctl enable --now wifi-watchdog.timer
```

Verify: `systemctl list-timers wifi-watchdog.timer` and
`cat /run/wifi-watchdog.state` (should read `fails=0` once the first run
completes).

## Tuning

The targets and interface are overridable via environment variables in the
unit: `WIFI_WATCHDOG_IFACE`, `WIFI_WATCHDOG_GATEWAY`,
`WIFI_WATCHDOG_NEIGHBOR`, `WIFI_WATCHDOG_WAN_TARGET` — useful if this ever
moves to the media server or another box.

Happy hardwiring — the watchdog should make the wait painless.
