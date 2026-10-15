#!/usr/bin/env bash
# Pulls k6 results from the loadgen and metrics.csv from the target into results/, then rebuilds
# results/REPORT.md.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$REPO_ROOT"
mkdir -p results
LG="$(tf_out loadgen_public_ip)"; TARGET="$(tf_out target_public_ip)"
if [ -n "$LG" ]; then
  log "fetch results from loadgen"
  rsync -az -e "ssh ${SSH_OPTS[*]}" "ubuntu@$LG:/srv/bench/results/" results/ || true
fi
if [ -n "$TARGET" ]; then
  log "fetch metrics.csv from target"
  rsync -az -e "ssh ${SSH_OPTS[*]}" "ubuntu@$TARGET:/srv/app/metrics.csv" results/metrics.csv || true
fi
bash bench/report.sh results results/metrics.csv > results/REPORT.md
cat results/REPORT.md
