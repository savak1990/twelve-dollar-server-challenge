#!/usr/bin/env bash
# The full scoring methodology, run ON THE LOAD GENERATOR (see README "Scoring" upstream + the videos):
#   1. warm-up: 1,000 VUs for 2 min (not scored)
#   2. raw /feed throughput probe, 30 s (not scored)
#   3. search: start at 2,500 VUs, double while passing, then bisect to within 250 (2-min holds)
#   4. confirm: 5-min hold at the found level; on failure step down 250 and retry
# Each hold starts from a fresh database on the target (FRESH_DB_CMD, run over ssh).
#
# Env: TARGET, LOCAL_IPS, TOKENS, RESULTS (see hold.sh); START (2500), STEP (250), HOLD (2m),
#      CONFIRM (5m), REPEATS (1), FRESH_DB_CMD (command that resets the target DB), SKIP_WARMUP.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RESULTS="${RESULTS:-/srv/bench/results}"
START="${START:-2500}"; STEP="${STEP:-250}"; HOLD="${HOLD:-2m}"; CONFIRM="${CONFIRM:-5m}"; REPEATS="${REPEATS:-1}"
RUN="$(date -u +%Y%m%dT%H%M%SZ)-search"
LOG="$RESULTS/$RUN.log"; mkdir -p "$RESULTS"
exec > >(tee -a "$LOG") 2>&1

say() { echo "[$(date -u +%H:%M:%S)] $*"; }
fresh() { [ -n "${FRESH_DB_CMD:-}" ] && { say "fresh database"; eval "$FRESH_DB_CMD"; }; sleep 5; }
hold() { # hold <vus> <duration> <label>
  fresh
  bash "$HERE/hold.sh" "$1" "$2" 60s "$RUN/$3-vus$1"
}

say "search run $RUN against $TARGET (start=$START step=$STEP hold=$HOLD confirm=$CONFIRM)"

if [ -z "${SKIP_WARMUP:-}" ]; then
  say "warm-up: 1000 VUs, 2m"; hold 1000 2m warmup || true
  say "raw /feed probe: 64 VUs, 30s"
  k6 run --quiet --no-usage-report -e BASE_URL="http://$TARGET" "$HERE/raw-feed.js" 2>&1 | grep -E 'http_reqs|http_req_duration\.\.|feed 200' || true
fi

# doubling phase
lo=0; hi=0; n=$START
while :; do
  if hold "$n" "$HOLD" "search"; then lo=$n; n=$((n * 2)); else hi=$n; break; fi
  [ "$n" -gt 400000 ] && { say "stopping doubling at $lo"; hi=$n; break; }
done
# bisection phase
while [ $((hi - lo)) -gt "$STEP" ]; do
  mid=$(( (lo + hi) / 2 / STEP * STEP ))
  [ "$mid" -le "$lo" ] && mid=$((lo + STEP))
  if hold "$mid" "$HOLD" "search"; then lo=$mid; else hi=$mid; fi
done
say "2-minute limit: $lo (first fail at $hi)"

# confirmation phase
n=$lo
while [ "$n" -gt 0 ]; do
  ok=1
  for r in $(seq "$REPEATS"); do
    hold "$n" "$CONFIRM" "confirm$r" || { ok=0; break; }
  done
  [ $ok -eq 1 ] && break
  n=$((n - STEP))
done
say "SCORE: $n users pass a $CONFIRM hold"
echo "$n" > "$RESULTS/$RUN.score"
