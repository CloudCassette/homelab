#!/bin/bash
set -u
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 077
readonly DIR=/home/cloudcassette/network-diagnostics
readonly LOG="$DIR/sample.log"

# Nonblocking lock prevents a slow sample overlapping the next minute.
exec 9>"$DIR/.sample.lock"
flock -n 9 || exit 0

# Keep the single log below 9 MiB; truncate only this task-owned log.
if [[ -f "$LOG" ]]; then
  size=$(stat -c %s "$LOG" 2>/dev/null || printf 0)
  if [[ "$size" =~ ^[0-9]+$ ]] && (( size >= 9 * 1024 * 1024 )); then
    : >"$LOG"
    chmod 0600 "$LOG"
  fi
fi

ipv4=$(ip -4 -o addr show dev wlp2s0 scope global 2>/dev/null | awk 'NR==1 {sub(/\/.*/,"",$4); print $4}')
[[ -n "$ipv4" ]] || ipv4=na
if [[ -r /sys/class/net/wlp2s0/operstate ]]; then
  IFS= read -r link </sys/class/net/wlp2s0/operstate || link=na
else
  link=na
fi
if [[ -r /proc/net/wireless ]]; then
  signal=$(awk '$1=="wlp2s0:" {printf "quality=%s,level=%s,noise=%s",$3,$4,$5; found=1} END {if (!found) printf "unavailable"}' /proc/net/wireless)
else
  signal=unavailable
fi
ping_status() {
  if timeout --signal=KILL 2s ping -n -c 1 -W 1 "$1" >/dev/null 2>&1; then printf up; else printf down; fi
}
router=$(ping_status 192.168.86.1)
external=$(ping_status 1.1.1.1)
http_code=$(timeout --signal=KILL 2s curl --connect-timeout 1 --max-time 1.5 --silent --output /dev/null --write-out '%{http_code}' http://192.168.86.4:3000/ 2>/dev/null || true)
[[ -n "$http_code" ]] || http_code=000
printf '%s iface=wlp2s0 ipv4=%s link=%s signal=%s router=%s external=%s http=%s\n' \
  "$(date -Is)" "$ipv4" "$link" "$signal" "$router" "$external" "$http_code" >>"$LOG"
