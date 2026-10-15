#!/usr/bin/env bash
# Drives a benchmark from the laptop: pulls the configured ref on the loadgen (it cloned the repo at
# boot), resets the target DB, runs hold.sh or search.sh there under nohup (so a dropped ssh doesn't
# kill a 2-hour search), streams the log, then pulls results and prints the report.
#
#   run-bench.sh hold <vus> <duration> [ramp_up]
#   run-bench.sh search
set -euo pipefail
MODE="${1:?hold|search}"
source "$(dirname "$0")/lib.sh"
cd "$REPO_ROOT"

TARGET_PUB="$(tf_out target_public_ip)"; TARGET_PRIV="$(tf_out target_private_ip)"
LG="$(tf_out loadgen_public_ip)"; LOCAL_IPS="$(tf_out loadgen_private_ips)"
[ -n "$LG" ] || { echo "no loadgen: run 'make test' (it enables it)" >&2; exit 1; }

REF="$(tf_out repo_ref)"
BENCH=/srv/bench/src/bench

log "waiting for loadgen $LG"
wait_ssh "$LG"
log "pull @ $REF on the loadgen"
rssh "$LG" "git -C /srv/bench/src fetch -q --depth 1 origin '$REF' && git -C /srv/bench/src reset -q --hard FETCH_HEAD && git -C /srv/bench/src log -1 --format='%h %s'
  [ -s /srv/bench/tokens.json ] || { node /srv/bench/src/seed/generate.mjs /tmp/seedout >/dev/null && mv /tmp/seedout/tokens.json /srv/bench/tokens.json && rm -rf /tmp/seedout; }
  k6 version | head -1; ip -4 -o addr | grep -c ' 10\.42\.' | xargs echo 'private ips attached:'"

# a single hold resets the target from the laptop; a search resets it from the loadgen with the
# dedicated bench key that Terraform generated (never the operator's key)
FRESH="ssh ${SSH_OPTS[*]} ubuntu@$TARGET_PUB sudo bash /srv/app/src/scripts/fresh-db.sh"
# which SQLite backend the target runs (SQLITE_BACKEND in /srv/app/twelve.env, set by `make backend`)
BACKEND="$(rssh "$TARGET_PUB" 'sudo grep -o "^SQLITE_BACKEND=[a-z]*" /srv/app/twelve.env 2>/dev/null | tail -1 | cut -d= -f2')"
BACKEND="${BACKEND:-cgo}"; log "target backend: $BACKEND"
case "$MODE" in
  hold)
    VUS="${2:?vus}"; DUR="${3:?duration}"; RAMP="${4:-60s}"
    log "fresh database on target"; $FRESH
    LABEL="$(date -u +%Y%m%dT%H%M%SZ)-hold-vus$VUS"
    log "hold: $VUS VUs for $DUR (ramp $RAMP) -> $LABEL"
    rssh "$LG" "TARGET=$TARGET_PRIV LOCAL_IPS=$LOCAL_IPS BACKEND=$BACKEND nohup bash $BENCH/hold.sh $VUS $DUR $RAMP $LABEL > /srv/bench/results/$LABEL.out 2>&1; cat /srv/bench/results/$LABEL.out" || true
    ;;
  search)
    log "search (this takes 1.5–2 h; log streams below, Ctrl-C only stops the stream)"
    rssh "$LG" "TARGET=$TARGET_PRIV LOCAL_IPS=$LOCAL_IPS BACKEND=$BACKEND FRESH_DB_CMD='ssh -i ~/.ssh/target_key -o StrictHostKeyChecking=accept-new ubuntu@$TARGET_PRIV sudo bash /srv/app/src/scripts/fresh-db.sh' nohup bash $BENCH/search.sh > /srv/bench/results/search.out 2>&1 &
      sleep 2; tail -f /srv/bench/results/search.out --pid=\$(pgrep -f bench/search.sh | head -1)" || true
    ;;
  *) echo "usage: run-bench.sh hold <vus> <duration> [ramp] | search" >&2; exit 1 ;;
esac

bash "$REPO_ROOT/scripts/fetch-results.sh"
