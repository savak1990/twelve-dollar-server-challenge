#!/usr/bin/env bash
# Runs on the target as root: stop the service, replace the database with a fresh seed copy, start
# the service and wait for /health. Every test and benchmark run starts from this.
set -euo pipefail
APP=/srv/app
systemctl stop twelve.service 2>/dev/null || true
rm -f "$APP/feed.db" "$APP/feed.db-wal" "$APP/feed.db-shm"
cp "$APP/seed/feed.db" "$APP/feed.db"
chown app:app "$APP/feed.db"
systemctl start twelve.service
for _ in $(seq 60); do
  curl -sf http://127.0.0.1:80/health >/dev/null && exit 0
  sleep 1
done
echo "no healthy /health after 60 s" >&2
journalctl -u twelve.service -n 30 --no-pager >&2
exit 1
