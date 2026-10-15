#!/usr/bin/env bash
# Builds bin/server as a normal user. Fetches the pinned SQLite amalgamation (sha256-checked),
# compiles it into sqlite/libsqlite3.a with flags tuned for the CPU this runs on, and links it into
# the Go binary through cgo. The library is built outside cgo so its object has a fixed path, which
# gcc profile-guided optimisation needs to match .gcda files between training and final builds.
#
#   GOAMD64=v2 bash build.sh      # override the detected microarchitecture level
#   SQLITE_PGO=gen bash build.sh  # instrumented build for gcc profile training (see ../../scripts/profile.sh)
set -euo pipefail
cd "$(dirname "$0")"

SQLITE_VER=3540000
SQLITE_URL="https://www.sqlite.org/2026/sqlite-amalgamation-${SQLITE_VER}.zip"
SQLITE_SHA256=68e913b0fe8ec6b4e5f391c594a28872884e80d6cd042a1e50c957be46b5aa4d

sha256() { if command -v sha256sum >/dev/null; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi; }

if [ ! -f sqlite/.version ] || [ "$(cat sqlite/.version)" != "$SQLITE_SHA256" ]; then
  tmp="$(mktemp -d)"
  curl -fsSL "$SQLITE_URL" -o "$tmp/sqlite.zip"
  [ "$(sha256 < "$tmp/sqlite.zip")" = "$SQLITE_SHA256" ] || { echo "sqlite checksum mismatch"; exit 1; }
  unzip -q -j "$tmp/sqlite.zip" "sqlite-amalgamation-${SQLITE_VER}/sqlite3.c" "sqlite-amalgamation-${SQLITE_VER}/sqlite3.h" -d "$tmp/out"
  rm -rf sqlite && mkdir sqlite && mv "$tmp/out/sqlite3.c" "$tmp/out/sqlite3.h" sqlite/
  echo "$SQLITE_SHA256" > sqlite/.version
  rm -rf "$tmp"
fi

GO=go; command -v go >/dev/null 2>&1 || GO=/usr/local/go/bin/go
CC="${CC:-gcc}"
CFLAGS="-O2 -fno-plt -fomit-frame-pointer -pipe"
# SQLite compile-time options: single-threaded (one connection, one goroutine), no stats
# bookkeeping, and the usual OMIT set from sqlite.org/compile.html.
DEFS="-DSQLITE_THREADSAFE=0 -DSQLITE_DEFAULT_MEMSTATUS=0 -DSQLITE_DQS=0 -DSQLITE_OMIT_LOAD_EXTENSION
      -DSQLITE_OMIT_DEPRECATED -DSQLITE_OMIT_SHARED_CACHE -DSQLITE_OMIT_PROGRESS_CALLBACK -DSQLITE_OMIT_DECLTYPE
      -DSQLITE_OMIT_AUTOINIT -DSQLITE_USE_ALLOCA -DSQLITE_MAX_EXPR_DEPTH=0 -DSQLITE_LIKE_DOESNT_MATCH_BLOBS
      -DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1 -DSQLITE_OMIT_UTF16 -DSQLITE_TEMP_STORE=3"
DEFS="$(echo $DEFS)"

# Microarchitecture: the box builds its own binary, so target the CPU it has. x86-64-v3 (AVX2)
# covers every DigitalOcean/AWS host we know of; v2 is the fallback.
if [ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ]; then
  if [ -z "${GOAMD64:-}" ]; then
    if grep -q -w avx2 /proc/cpuinfo && grep -q -w bmi2 /proc/cpuinfo; then GOAMD64=v3; else GOAMD64=v2; fi
  fi
  export GOAMD64
  CFLAGS="$CFLAGS -march=x86-64-$GOAMD64"
fi

# gcc profile-guided optimisation of SQLite. `gen` instruments; otherwise profiles in pgo/ are used
# when they come from the same gcc major, and silently skipped when they don't (CI stays green).
# -fprofile-prefix-path makes the .gcda name independent of where the checkout lives.
gcc_major="$("$CC" -dumpversion 2>/dev/null | cut -d. -f1 || echo 0)"
is_gcc=0; "$CC" --version 2>/dev/null | head -1 | grep -qi 'gcc' && is_gcc=1
PGOFLAGS=""; LDPGO=""
case "${SQLITE_PGO:-use}" in
  gen)
    [ $is_gcc = 1 ] || { echo "SQLITE_PGO=gen needs gcc"; exit 1; }
    PGOFLAGS="-fprofile-generate -fprofile-update=single -fprofile-dir=$PWD/pgo -fprofile-prefix-path=$PWD -DSHIM_GCOV"
    LDPGO="-fprofile-generate"; mkdir -p pgo; echo "$gcc_major" > pgo/gcc-version ;;
  use)
    if [ $is_gcc = 1 ] && ls pgo/*.gcda >/dev/null 2>&1 && [ "$gcc_major" = "$(cat pgo/gcc-version 2>/dev/null)" ]; then
      PGOFLAGS="-fprofile-use -fprofile-dir=$PWD/pgo -fprofile-prefix-path=$PWD -fprofile-correction -Wno-missing-profile -Wno-coverage-mismatch"
      echo "build: using gcc PGO profiles from pgo/"
    fi ;;
esac

# The amalgamation: rebuilt only when the flags change (the flag string is recorded next to it).
stamp="$CC $CFLAGS $DEFS $PGOFLAGS"
if [ ! -f sqlite/libsqlite3.a ] || [ "$(cat sqlite/.flags 2>/dev/null)" != "$stamp" ]; then
  echo "build: compiling sqlite3.c ($CC)"
  # shellcheck disable=SC2086
  "$CC" $CFLAGS $DEFS $PGOFLAGS -c sqlite/sqlite3.c -o sqlite/sqlite3.o
  rm -f sqlite/libsqlite3.a && ar rcs sqlite/libsqlite3.a sqlite/sqlite3.o
  echo "$stamp" > sqlite/.flags
fi

export CGO_ENABLED=1 GOTOOLCHAIN=local GOFLAGS=-mod=mod
export CGO_CFLAGS="$CFLAGS $DEFS ${PGOFLAGS:+-DSHIM_GCOV}"
export CGO_LDFLAGS="$LDPGO"
[ -f default.pgo ] && echo "build: using Go PGO profile default.pgo"
echo "build: GOAMD64=${GOAMD64:-n/a} CFLAGS=$CFLAGS"
"$GO" build -trimpath -ldflags='-s -w' -o bin/server .
