#!/bin/bash
# wifi-watchdog.sh — recover cassette-lab (192.168.86.4) from a wedged Wi-Fi link.
# cassete-lab runs on Wi-Fi (Intel Centrino Wireless-N 2230, wpa_supplicant-managed);
# long-uptime wedges kill LAN reachability + the cloudflared tunnel at once.
# Runs every 2 minutes from wifi-watchdog.timer (system service, root).
#
# Decision tree (all check results from the box itself):
#   gateway OK                          -> healthy; reset counters
#   gateway dead, neighbor (media) OK   -> router/LAN problem; hold (bouncing Wi-Fi won't fix it)
#   gateway dead, WAN 1.1.1.1 OK        -> router problem; hold
#   gateway + neighbor + WAN all dead   -> Wi-Fi link itself is gone; ESCALATE:
#       fails >= 3: bounce the interface (ip link down/up -> reassociate)
#       fails >= 5: restart wpa_supplicant (full reassociation)
#       fails >= 8: reboot (true recovery action of last resort; ~16 min of downtime total)
#
# State lives in /run (tmpfs): counters reset on every boot, so a reboot starts clean.
# Every failure is logged (journald + /var/log/wifi-watchdog.log) with the raw
# /proc/net/wireless state so the wedge has forensic evidence even if recovery works.

IFACE="${WIFI_WATCHDOG_IFACE:-wlp2s0}"
GATEWAY="${WIFI_WATCHDOG_GATEWAY:-192.168.86.1}"
NEIGHBOR="${WIFI_WATCHDOG_NEIGHBOR:-192.168.86.40}"
WAN_TARGET="${WIFI_WATCHDOG_WAN_TARGET:-1.1.1.1}"

STATE=/run/wifi-watchdog.state
LOG=/var/log/wifi-watchdog.log
LOCK=/run/wifi-watchdog.lock

exec 9>"$LOCK"
flock -n 9 || exit 0        # previous run still in flight (slow ping): skip this tick

log() {
    logger -t wifi-watchdog "$1"
    echo "$(date '+%b %d %T') $1" >> "$LOG" 2>/dev/null || true
}

ping_ok() { ping -q -c 2 -W 2 "$1" >/dev/null 2>&1; }

got_gw=$(ping_ok "$GATEWAY" && echo yes || echo no)
got_nb=$(ping_ok "$NEIGHBOR" && echo yes || echo no)
got_wan=$(ping_ok "$WAN_TARGET" && echo yes || echo no)

fails=0
[ -f "$STATE" ] && . "$STATE"
fails=${fails:-0}

if [ "$got_gw" = yes ]; then
    if [ "$fails" -gt 0 ]; then
        log "connectivity recovered after $fails failed check(s); counters reset"
    fi
    fails=0
else
    fails=$((fails + 1))
    if [ "$got_nb" = yes ]; then
        # Neighbor answers on the same LAN => Wi-Fi link works; the router/AP is the problem.
        log "gateway dead but $NEIGHBOR answers — router/LAN issue, holding (not Wi-Fi)"
        fails=0
    elif [ "$got_wan" = yes ]; then
        log "gateway dead but WAN reachable — routing issue, holding"
        fails=0
    else
        wl=$(awk '$1 ~ /:/ {printf "%s link=%s level=%s", $1, $3, $4}' /proc/net/wireless 2>/dev/null)
        log "ALL targets unreachable (fails=$fails, $wl) — Wi-Fi wedge suspected"
        case "$fails" in
            3)
                log "stage 1: bouncing $IFACE (down/up) to force reassociation"
                ip link set "$IFACE" down
                sleep 2
                ip link set "$IFACE" up
                ;;
            5)
                log "stage 2: restarting wpa_supplicant"
                systemctl restart wpa_supplicant
                ;;
            8)
                log "stage 3: link still dead, rebooting"
                sync
                systemctl reboot
                ;;
        esac
    fi
fi

printf 'fails=%s\n' "$fails" > "$STATE"
