#!/usr/bin/env bash
# Re-deploys the target from GitHub: fast-forwards /srv/app/src to the configured ref and re-runs
# scripts/bootstrap-target.sh there (build on the box, fresh DB, 42 checks). Push first.
#
#   deploy-target.sh <target-ip> <submission-name> <ssh-key>
set -euo pipefail
IP="${1:?target ip}"; NAME="${2:?submission name}"; export SSH_KEY="${3:?ssh key}"
source "$(dirname "$0")/lib.sh"
REF="$(tf_out repo_ref)"; URL="$(tf_out repo_url)"

log "waiting for $IP"
wait_ssh "$IP"

log "pull $URL @ $REF on the box"
rssh "$IP" "sudo git -C /srv/app/src fetch -q --depth 1 origin '$REF' && sudo git -C /srv/app/src reset -q --hard FETCH_HEAD && sudo git -C /srv/app/src log -1 --format='%h %s'"

log "bootstrap on the box"
rc=0
rssh "$IP" "sudo ${SQLITE_PGO:+SQLITE_PGO=$SQLITE_PGO} bash /srv/app/src/scripts/bootstrap-target.sh $NAME" || rc=$?
echo "target: http://$IP/health"
exit $rc
