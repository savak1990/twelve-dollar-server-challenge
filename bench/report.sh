#!/usr/bin/env bash
# Builds a markdown table from results/*/{summary.json,meta.json} plus the target's metrics.csv,
# one row per hold, like the tables in the videos. A FAIL with loadgen CPU > 70 % is flagged
# "loadgen-bound": the client, not the server, ran out of steam.
#
#   report.sh <results-dir> [metrics.csv] > REPORT.md
set -euo pipefail
RES="${1:?results dir}"; METRICS="${2:-$RES/metrics.csv}"

echo "| run | VUs | verdict | reqs | rps | med | p95 | p99 | errors | target CPU | server RAM (anon) | RSS incl. mmap | WAL max | conns | loadgen CPU |"
echo "|---|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"
find "$RES" -name meta.json | sort | while read -r meta; do
  dir="$(dirname "$meta")"; sum="$dir/summary.json"
  [ -s "$sum" ] || continue
  start=$(jq -r .start "$meta"); end=$(jq -r .end "$meta")
  # steady-state window of the target metrics: after the ramp, before the ramp-down
  host="-|-|-|-|-"
  if [ -s "$METRICS" ]; then
    host=$(awk -F, -v s=$((start + 70)) -v e=$((end - 40)) '
      NR>1 && $1>=s && $1<=e {c+=$2; n++; if($3>r) r=$3; if($12>a) a=$12; if($6>w) w=$6; if($5>k) k=$5}
      END{ if(n) printf "%d%%|%d MB|%d MB|%.1f MB|%d", c/n, a/1024, r/1024, w/1048576, k; else print "-|-|-|-|-" }' "$METRICS")
  fi
  IFS='|' read -r cpu anon rss wal conns <<< "$host"
  jq -r --arg run "$(basename "$dir")" --arg cpu "$cpu" --arg anon "$anon" --arg rss "$rss" --arg wal "$wal" --arg conns "$conns" \
     --slurpfile m "$meta" '
    . as $s | $m[0] as $m |
    def ms: if . < 10 then (.*10|round/10) else floor end;
    ($m.verdict + (if $m.verdict == "FAIL" and $m.loadgen_cpu_pct > 70 then " (loadgen-bound)" else "" end)) as $verdict |
    "| \($run) | \($m.vus) | \($verdict) | \($s.metrics.http_reqs.count) | \($s.metrics.http_reqs.rate|floor) " +
    "| \($s.metrics.http_req_duration.med|ms) ms | \($s.metrics.http_req_duration["p(95)"]|ms) ms | \($s.metrics.http_req_duration["p(99)"]|ms) ms " +
    "| \($s.metrics.http_req_failed.value*100|.*100|round/100)% | \($cpu) | \($anon) | \($rss) | \($wal) | \($conns) | \($m.loadgen_cpu_pct)% |"' "$sum"
done
