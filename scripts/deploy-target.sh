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
# bootstrap chowns /srv/app to the app user, so root's git needs safe.directory
G="sudo git -c safe.directory=/srv/app/src -C /srv/app/src"
rssh "$IP" "if [ -d /srv/app/src/.git ]; then $G fetch -q --depth 1 origin '$REF' && $G reset -q --hard FETCH_HEAD; else sudo rm -rf /srv/app/src && sudo git clone -q --depth 1 --branch '$REF' '$URL' /srv/app/src; fi && $G log -1 --format='%h %s'"

log "bootstrap on the box"
rc=0
rssh "$IP" "sudo ${SQLITE_PGO:+SQLITE_PGO=$SQLITE_PGO} bash /srv/app/src/scripts/bootstrap-target.sh $NAME" || rc=$?
echo "target: http://$IP/health"
exit $rc
