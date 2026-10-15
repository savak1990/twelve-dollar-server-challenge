#!/usr/bin/env bash
# Waits for a target that bootstraps itself from GitHub (REPO_URL set): cloud-init done, bootstrap
# log tail, /health answering.
#
#   wait-bootstrap.sh <target-ip> <ssh-key>
set -euo pipefail
IP="${1:?target ip}"; export SSH_KEY="${2:?ssh key}"
source "$(dirname "$0")/lib.sh"

log "waiting for cloud-init + bootstrap on $IP (first boot builds Go, SQLite and the seed DB: ~5-8 min)"
wait_ssh "$IP"
rssh "$IP" 'sudo tail -n 8 /var/log/twelve-bootstrap.log 2>/dev/null || echo "no bootstrap log (REPO_URL unset?)"'
for _ in $(seq 30); do
  if curl -sf --max-time 3 "http://$IP/health"; then echo; echo "target ready: http://$IP/health"; exit 0; fi
  sleep 5
done
echo "target not healthy; inspect with: make ssh-target; sudo cat /var/log/twelve-bootstrap.log" >&2
exit 1
