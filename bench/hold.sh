#!/usr/bin/env bash
# One scored k6 hold, run ON THE LOAD GENERATOR. Writes results/<label>/{summary.json,k6.log,meta.json}
# and prints PASS/FAIL (k6 exits non-zero when a threshold in load.js fails).
#
#   hold.sh <vus> <duration> [ramp_up] [label]
# Env: TARGET (private IP of the target), LOCAL_IPS (comma list for k6 --local-ips),
#      TOKENS (default /srv/bench/tokens.json), RESULTS (default /srv/bench/results)
set -uo pipefail
VUS="${1:?vus}"; DURATION="${2:?duration}"; RAMP="${3:-60s}"; LABEL="${4:-$(date -u +%Y%m%dT%H%M%SZ)-vus$VUS}"
TARGET="${TARGET:?TARGET ip}"
TOKENS="${TOKENS:-/srv/bench/tokens.json}"
RESULTS="${RESULTS:-/srv/bench/results}"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$RESULTS/$LABEL"; mkdir -p "$OUT"

read_cpu() { awk '/^cpu /{print $2+$3+$4+$6+$7+$8, $5}' /proc/stat; }
read -r b0 i0 < <(read_cpu)
start=$(date -u +%s)

ulimit -n 1048576 2>/dev/null || true
k6 run --quiet --no-usage-report \
  ${LOCAL_IPS:+--local-ips "$LOCAL_IPS"} \
  -e BASE_URL="http://$TARGET" -e VUS="$VUS" -e DURATION="$DURATION" -e RAMP_UP="$RAMP" -e TOKENS="$TOKENS" \
  --summary-export "$OUT/summary.json" "$HERE/load.js" > "$OUT/k6.log" 2>&1
rc=$?

end=$(date -u +%s)
read -r b1 i1 < <(read_cpu)
db=$((b1 - b0)); tot=$((db + i1 - i0)); lgcpu=0; [ "$tot" -gt 0 ] && lgcpu=$((100 * db / tot))
verdict=PASS; [ $rc -eq 0 ] || verdict=FAIL
jq -n --arg vus "$VUS" --arg dur "$DURATION" --arg ramp "$RAMP" --arg start "$start" --arg end "$end" \
      --arg rc "$rc" --arg lgcpu "$lgcpu" --arg verdict "$verdict" --arg target "$TARGET" --arg backend "${BACKEND:-cgo}" \
      '{vus:($vus|tonumber),duration:$dur,ramp_up:$ramp,start:($start|tonumber),end:($end|tonumber),
        k6_exit:($rc|tonumber),loadgen_cpu_pct:($lgcpu|tonumber),verdict:$verdict,target:$target,backend:$backend}' > "$OUT/meta.json"
echo "$verdict vus=$VUS $(jq -r '"p95=\(.metrics.http_req_duration["p(95)"]|floor)ms p99=\(.metrics.http_req_duration["p(99)"]|floor)ms failed=\(.metrics.http_req_failed.value*100|.*100|round/100)% rps=\(.metrics.http_reqs.rate|floor)"' "$OUT/summary.json" 2>/dev/null) loadgen_cpu=${lgcpu}% -> $OUT"
exit $rc
