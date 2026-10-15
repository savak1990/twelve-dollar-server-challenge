#!/usr/bin/env bash
# PGO training cycle:
#   1. redeploy with SQLITE_PGO=gen (gcc-instrumented SQLite) and PROFILE_DIR set
#   2. run a hold at VUS; toggle the Go CPU profile with SIGUSR1 after the ramp and before the end
#   3. stop the service gracefully (flushes .gcda via __gcov_dump), fetch cpu/heap pprof + *.gcda
#   4. what the build consumes goes to the submission root: default.pgo (the CPU profile, the name
#      `go build` picks up by itself), *.gcda + gcc-version (gcc PGO of SQLite). The raw cpu/heap
#      pprof copies go to <submission>/pgo/ (gitignored) for inspection.
#   5. you commit + push them and `make deploy` (the box builds from GitHub)
#
#   profile.sh <vus> <submission-dir>     (DURATION env, default 3m)
set -euo pipefail
VUS="${1:?vus}"; NAME="${2:?submission name}"; DUR="${DURATION:-3m}"; SUB="submissions/$NAME"
source "$(dirname "$0")/lib.sh"
cd "$REPO_ROOT"
TARGET="$(tf_out target_public_ip)"; TARGET_PRIV="$(tf_out target_private_ip)"
LG="$(tf_out loadgen_public_ip)"; LOCAL_IPS="$(tf_out loadgen_private_ips)"
[ -n "$LG" ] || { echo "loadgen required (make test first)" >&2; exit 1; }

log "instrumented deploy"
rssh "$TARGET" 'sudo touch /srv/app/twelve.env; sudo sed -i "/^PROFILE_DIR=/d" /srv/app/twelve.env; echo PROFILE_DIR=/srv/app/prof | sudo tee -a /srv/app/twelve.env >/dev/null; sudo rm -rf /srv/app/submission/*.gcda /srv/app/prof/*'
SQLITE_PGO=gen bash scripts/deploy-target.sh "$TARGET" "$NAME" "$SSH_KEY"

log "training hold: $VUS VUs for $DUR"
LABEL="$(date -u +%Y%m%dT%H%M%SZ)-train-vus$VUS"
rssh "$LG" "TARGET=$TARGET_PRIV LOCAL_IPS=$LOCAL_IPS nohup bash /srv/bench/src/bench/hold.sh $VUS $DUR 60s $LABEL > /srv/bench/results/$LABEL.out 2>&1 &"
sleep 75; log "start Go CPU profile"; rssh "$TARGET" 'sudo pkill -USR1 -f submission/bin/server'
dur_s=$(( $(echo "$DUR" | sed 's/m/*60/;s/s//') )); sleep $((dur_s - 30))
log "stop Go CPU profile"; rssh "$TARGET" 'sudo pkill -USR1 -f submission/bin/server'
sleep 60
log "graceful stop (flush gcov)"; rssh "$TARGET" 'sudo systemctl stop twelve.service'

log "fetch profiles"
RAW="$(mktemp -d)"
mkdir -p "$SUB/pgo"
rsync -az -e "ssh ${SSH_OPTS[*]}" "ubuntu@$TARGET:/srv/app/prof/" "$RAW/"
rsync -az -e "ssh ${SSH_OPTS[*]}" --include '*.gcda' --exclude '*' "ubuntu@$TARGET:/srv/app/submission/" "$SUB/"
rssh "$TARGET" 'gcc -dumpversion | cut -d. -f1' > "$SUB/gcc-version"
go tool pprof -proto "$RAW"/cpu-*.pprof > "$SUB/pgo/cpu.pprof"     # merged if more than one
cp "$(ls -t "$RAW"/heap-*.pprof | head -1)" "$SUB/pgo/heap.pprof"   # newest
rm -rf "$RAW"
cp "$SUB/pgo/cpu.pprof" "$SUB/default.pgo"                           # the name go build auto-detects
ls -la "$SUB/default.pgo" "$SUB"/*.gcda "$SUB/gcc-version" "$SUB/pgo/"

rssh "$TARGET" 'sudo sed -i "/^PROFILE_DIR=/d" /srv/app/twelve.env'
cat <<EOF
Profiles saved locally. The target builds from GitHub, so publish them and redeploy:
  git add $SUB/default.pgo $SUB/*.gcda $SUB/gcc-version && git commit -m "pgo: profiles from $VUS VUs" && git push
  make deploy                      # rebuilds with both profiles
  make test VUS=$VUS DURATION=5m   # A/B against the earlier hold
Inspect the profiles (the heap one is taken at profile stop, after a forced GC):
  go tool pprof -http=: $SUB/bin/server $SUB/pgo/cpu.pprof
  go tool pprof -http=: -sample_index=inuse_space $SUB/bin/server $SUB/pgo/heap.pprof
EOF
