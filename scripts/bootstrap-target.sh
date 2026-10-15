#!/usr/bin/env bash
# Runs ON THE TARGET as root, from a checkout of this repo at /srv/app/src (git clone via cloud-init,
# or rsync via `make deploy`). Builds the submission on the box (upstream rule 10), builds the seed
# database once, resets it, starts the service and runs the upstream 42-check suite against it.
#
#   bootstrap-target.sh <submission-name>        e.g. go-fasthttp-savak1990
set -euo pipefail
NAME="${1:?submission name}"
APP=/srv/app; SRC=$APP/src; SUB=$SRC/submissions/$NAME
[ -d "$SUB" ] || { echo "no such submission: $SUB" >&2; exit 1; }

ln -sfn "$SUB" "$APP/submission"
mkdir -p "$APP/seed" "$APP/prof" "$APP/.cache"
chown -R app:app "$APP"
chmod -R a+rX "$SRC/bench" "$SRC/test" "$SRC/scripts"

echo "== install.sh"
bash "$SUB/install.sh" | tail -1

echo "== build.sh (on the box)"
sudo -u app env HOME=$APP GOCACHE=$APP/.cache/go-build GOMODCACHE=$APP/.cache/mod GOPATH=$APP/go \
  PATH=/usr/local/go/bin:$PATH ${SQLITE_PGO:+SQLITE_PGO=$SQLITE_PGO} bash "$SUB/build.sh"

if [ ! -s "$APP/seed/feed.db" ]; then
  echo "== seed database (built once on the box)"
  sudo -u app env HOME=$APP bash "$SRC/seed/make-seed.sh" | tail -1
  mv "$SRC/seed/feed.db" "$SRC/seed/tokens.json" "$APP/seed/"
  rm -f "$SRC/seed/feed.db-wal" "$SRC/seed/feed.db-shm"
fi

systemctl daemon-reload
systemctl restart twelve-sampler.service || true

echo "== fresh database + start"
bash "$SRC/scripts/fresh-db.sh"

echo "== upstream test suite"
rc=0
JWT_SECRET=twelve-dollar-challenge bash "$SRC/test/test.sh" http://127.0.0.1:80 | tail -3 || rc=$?

echo "== fresh database for benchmarking"
bash "$SRC/scripts/fresh-db.sh"
echo "bootstrap done (tests rc=$rc)"
exit $rc
