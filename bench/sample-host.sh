#!/usr/bin/env bash
# Samples the target every 5 s into a CSV: CPU %, server RSS, established :80 connections, WAL size,
# Linux conntrack count (0 when the module isn't loaded) and the ENA "allowance exceeded" counters that
# reveal AWS-side throttling. Runs as a systemd service; results are joined with k6 summaries by time.
#
#   sample-host.sh /srv/app/metrics.csv
set -uo pipefail
OUT="${1:-/srv/app/metrics.csv}"
IFACE="$(ip -o -4 route show to default | awk '{print $5}' | head -1)"

# rss_kb includes the mmap'd database pages (file-backed, reclaimable); rss_anon_kb is the
# process's own memory and is the number to quote as "server RAM".
[ -s "$OUT" ] || echo "ts,cpu_pct,rss_kb,mem_avail_kb,established,wal_bytes,conntrack,ena_conntrack_exceeded,ena_pps_exceeded,ena_bw_in_exceeded,ena_bw_out_exceeded,rss_anon_kb" > "$OUT"

read_cpu() { awk '/^cpu /{print $2+$3+$4+$6+$7+$8, $5}' /proc/stat; }   # busy idle
ena() { ethtool -S "$IFACE" 2>/dev/null | awk -v k="$1" '$1==k":"{print $2}' | head -1; }

read -r busy0 idle0 < <(read_cpu)
while sleep 5; do
  read -r busy1 idle1 < <(read_cpu)
  db=$((busy1 - busy0)); di=$((idle1 - idle0)); tot=$((db + di))
  cpu=0; [ "$tot" -gt 0 ] && cpu=$((100 * db / tot))
  busy0=$busy1; idle0=$idle1

  pid="$(pgrep -f 'submission/bin/server' | head -1 || true)"
  rss=0; anon=0
  if [ -n "$pid" ]; then
    rss="$(awk '/^VmRSS:/{print $2}' "/proc/$pid/status" 2>/dev/null || echo 0)"
    anon="$(awk '/^RssAnon:/{print $2}' "/proc/$pid/status" 2>/dev/null || echo 0)"
  fi
  avail="$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)"
  est="$(ss -Htn state established '( sport = :80 )' 2>/dev/null | wc -l | tr -d ' ')"
  wal="$(stat -c %s /srv/app/feed.db-wal 2>/dev/null || echo 0)"
  ct="$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)"
  echo "$(date -u +%s),$cpu,${rss:-0},$avail,$est,$wal,$ct,$(ena conntrack_allowance_exceeded),$(ena pps_allowance_exceeded),$(ena bw_in_allowance_exceeded),$(ena bw_out_allowance_exceeded),${anon:-0}" >> "$OUT"
done
