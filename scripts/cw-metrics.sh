#!/usr/bin/env bash
# CPU and memory of both boxes from the CloudWatch agent (namespace twelve-dollar, dimension role).
# One table per role over the last MINUTES (default 15); WATCH=1 refreshes every 30 s.
# CloudWatch ingests with ~1-2 min delay, so the last row lags; the on-box sampler is the live view.
#
#   cw-metrics.sh            MINUTES=30 cw-metrics.sh            WATCH=1 cw-metrics.sh
set -euo pipefail
MINUTES="${MINUTES:-15}"

since() { date -u -v-"${MINUTES}"M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "$MINUTES min ago" +%Y-%m-%dT%H:%M:%SZ; }

series() { # <role> <metric> [extra dimension]
  aws cloudwatch get-metric-statistics --namespace twelve-dollar --metric-name "$2" \
    --dimensions Name=role,Value="$1" ${3:+"$3"} --statistics Maximum --period 60 \
    --start-time "$(since)" --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --query 'sort_by(Datapoints,&Timestamp)[].[Timestamp,Maximum]' --output text
}

show() {
  for role in target loadgen; do
    echo "== $role (1-min max, last ${MINUTES} min)"
    join -a1 -a2 -e - -o 0,1.2,2.2 \
      <(series "$role" cpu_usage_active Name=cpu,Value=cpu-total | sort) \
      <(series "$role" mem_used_percent | sort) \
      | awk 'function f(v){return v=="-"?"-":sprintf("%.1f",v)}
             BEGIN{printf "%-20s %6s %6s\n","time","cpu%","mem%"} {printf "%-20s %6s %6s\n",$1,f($2),f($3)}'
  done
}

if [ "${WATCH:-0}" = 1 ]; then
  while true; do clear; date -u; show; sleep 30; done
else
  show
fi
