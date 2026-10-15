# shellcheck shell=bash
# Shared helpers for the scripts/ directory. Source after setting SSH_KEY.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519_personal}"
SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -o ConnectTimeout=10 -o LogLevel=ERROR)

# Code never travels over ssh: the boxes clone GitHub. ssh is for commands and for pulling results.
rssh() { ssh "${SSH_OPTS[@]}" "ubuntu@$1" "${@:2}"; }

tf_out() { terraform -chdir="$REPO_ROOT/infra" output -raw "$1" 2>/dev/null; }

# wait_ssh <ip>: waits for sshd and for cloud-init to finish.
wait_ssh() {
  local ip=$1
  for _ in $(seq 60); do
    if rssh "$ip" true 2>/dev/null; then break; fi
    sleep 5
  done
  rssh "$ip" true || { echo "no ssh on $ip after 5 min" >&2; return 1; }
  rssh "$ip" 'cloud-init status --wait >/dev/null 2>&1 || true; cloud-init status --long 2>/dev/null | head -2 || true'
}

log() { printf '\033[1;34m== %s\033[0m\n' "$*" >&2; }
