#!/bin/bash
# Ensure a default route exists on the homelab so cloudflared tunnels (and
# external reachability generally) survive WiFi carrier events.
#
# Root cause observed 2026-11-04: the box had a healthy WiFi link and reachable
# LAN gateway, but no default route, so `ping 1.1.1.1` failed with "network is
# unreachable" and the cloudflared-dav tunnel crash-looped for ~10 hours.
# Nothing runs on the box that maintains a static default route, so this
# watchdog restores it.
#
# Safe by construction: only ADDs a missing route for a fixed gateway; never
# deletes or rewrites existing routes; never touches other interfaces; keeps
# /run as an ephemeral state file for transition logging.
set -euo pipefail

readonly WAN_IFACE="${NETWORK_ENSURE_IFACE:-wlp2s0}"
readonly GATEWAY="${NETWORK_ENSURE_GATEWAY:-192.168.86.1}"
readonly STATE_DIR=/run/network-ensure
readonly IFACE_STATE="$STATE_DIR/iface-state"

log() { systemd-cat -t network-ensure -- echo "$*"; }

gw_reachable() { timeout --signal=KILL 3s ping -n -c 1 -W 1 "$GATEWAY" >/dev/null 2>&1; }
link_up() { [[ -r /sys/class/net/$WAN_IFACE/operstate ]] && [[ "$(<"/sys/class/net/$WAN_IFACE/operstate")" == "up" ]]; }

mkdir -p "$STATE_DIR"
prev_state=$(cat "$IFACE_STATE" 2>/dev/null || true)

# Already have a working path to the internet? Nothing to do.
if ip route get 1.1.1.1 >/dev/null 2>&1; then
  if [[ "$prev_state" != "ok" ]]; then
    log "internet reachable; default route present"
    printf 'ok\n' >"$IFACE_STATE"
  fi
  exit 0
fi

# No internet path. Only act if the link and gateway look usable.
if link_up && gw_reachable; then
  if ip route show default dev "$WAN_IFACE" >/dev/null 2>&1; then
    # Default route exists on the iface but the internet is still unreachable
    # (e.g. wrong gateway on the link). Log once per state change.
    if [[ "$prev_state" != "route-present-but-down" ]]; then
      log "default route exists on $WAN_IFACE but internet unreachable; further diagnosis needed"
      printf 'route-present-but-down\n' >"$IFACE_STATE"
    fi
    exit 0
  fi
  if ip route add default via "$GATEWAY" dev "$WAN_IFACE"; then
    if ip route get 1.1.1.1 >/dev/null 2>&1; then
      log "restored default route via $GATEWAY dev $WAN_IFACE; internet reachable"
      printf 'ok\n' >"$IFACE_STATE"
    else
      log "added default via $GATEWAY dev $WAN_IFACE but internet still unreachable"
      printf 'route-present-but-down\n' >"$IFACE_STATE"
    fi
  else
    log "failed to add default route via $GATEWAY dev $WAN_IFACE"
    printf 'failed\n' >"$IFACE_STATE"
  fi
  exit 0
fi

# Link or gateway is down; keep monitoring. Log only on state transition.
if [[ "$prev_state" != "down" ]]; then
  log "link=$(link_up && echo up || echo down) gateway=$GATEWAY unreachable; waiting for uplink"
  printf 'down\n' >"$IFACE_STATE"
fi
exit 0