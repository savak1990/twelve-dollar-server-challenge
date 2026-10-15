# Go + fasthttp + SQLite (amalgamation, cgo), direct on :80

| | |
|---|---|
| Language | Go 1.27.1 (official tarball, sha256-checked by `install.sh`) |
| HTTP | [`valyala/fasthttp`](https://github.com/valyala/fasthttp) v1.75.0, no router, no middleware |
| SQLite | 3.54.0 amalgamation, downloaded and sha256-checked by `build.sh`, compiled to a static library and linked in through a ~60-line C shim; **no `database/sql`** |
| JSON | responses are rendered **by SQLite** (`json_object`, `json_group_array`); request JSON and JWTs are read by a small allocation-free scanner |
| Auth | HS256 with precomputed HMAC pads, constant-time compare, verified on every request |
| Dependencies | fasthttp + the Go standard library + SQLite. `go.sum` pins everything |
| **Nginx or direct** | **Direct**: serves `0.0.0.0:80` itself |

```bash
sudo bash install.sh   # build-essential, curl, unzip; Go 1.27.1 into /usr/local/go
bash build.sh          # fetches SQLite 3.54.0, builds bin/server for this CPU
SQLITE_PATH=... JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

`test/run.sh` passes 42/42.

## Design

**One cgo call per request.** Every read is a single prepared statement whose only column is the
complete response body, built by SQLite's JSON functions. `/feed` is
`json_group_array(json_object(...) ORDER BY created_at DESC, id DESC)` over a 20-row subquery of plain
columns (building the object inside the aggregate avoids a `json()` re-parse: 22 % of feed CPU); the bytes are
copied once, from SQLite's result buffer into the response buffer. No row objects, no Go JSON
encoder, no per-column cgo crossings.

**One SQLite connection, one goroutine, group commit.** SQLite is compiled with `THREADSAFE=0` and
touched by exactly one goroutine. Handlers hand it a pooled request struct through a channel; each
pass drains everything queued (up to 256), answers reads immediately and runs **all queued likes and
posts inside one `BEGIN IMMEDIATE … COMMIT`**. A writer's response is released only after that
COMMIT returns, so a 201 means the row is committed (rule 6) — just with one transaction per batch
instead of one per request. A failed commit fails the whole batch with 500.

**Checkpoints off the request path, WAL kept small.** `wal_autocheckpoint=0`; a `sqlite3_wal_hook`
counts frames and when the queue is empty past 1,000 frames the DB goroutine runs a `TRUNCATE`
checkpoint inline. Under a sustained write stress (58k rps of create+like locally) the WAL stays
between 1 and 5 MB. `PASSIVE` checkpoints on a side thread were rejected: under steady writes they
never catch up and the WAL grows without bound.

**Pragmas**: `journal_mode=WAL`, `synchronous=NORMAL` (rule 6), `mmap_size=1 GiB` (the 250 MB
database is read through the OS page cache with no copies), `cache_size=-2048` (a small SQLite page
cache on top of mmap), `temp_store=MEMORY`. Nothing is cached across requests (rule 5).

**fasthttp tuned for tens of thousands of idle keep-alive connections.** `ReduceMemoryUsage` returns
per-connection buffers to pools while a connection waits in think time; 4 KiB read / 8 KiB write
buffers (a full feed fits in one write); no `Server`/`Date`/default `Content-Type` headers; header
name normalisation off (so `Authorization` is matched case-sensitively — k6, curl and browsers all
send it canonically); no read/idle timeouts (SPEC asks us to keep idle connections open).
Measured locally: ~7 KB of RSS per open connection.

**Allocation-free request path.** Static pre-serialised error bodies; pooled response buffers; the
JWT is base64-decoded and HMAC-verified into a pooled scratch buffer; the create body is unescaped
in place and trimmed with JavaScript's `trim()` whitespace set. `go test` asserts zero allocations
for token verification and body parsing. `start.sh` sets `GOGC=off` and `GOMEMLIMIT=1GiB` (both
overridable from the environment), so the collector has nothing to do during a run and the other
half of the 2 GB box stays with the kernel's socket buffers and the mmap'd database in page cache.

**Compiled for the box.** `build.sh` detects the CPU: `GOAMD64=v3` and `-march=x86-64-v3` when AVX2
is present (every DigitalOcean/AWS host we have seen), `v2` otherwise. SQLite is built with the
recommended `OMIT_*`/`DEFAULT_MEMSTATUS=0`/`USE_ALLOCA`/`MAX_EXPR_DEPTH=0` set.

**Profile-guided optimisation.** `default.pgo` (Go PGO, picked up automatically by `go build`) is a
copy of `pgo/cpu.pprof`, a CPU profile taken under the k6 workload; `pgo/heap.pprof` from the same
run is there for inspection only, PGO uses CPU profiles alone. `pgo/*.gcda` (gcc PGO for SQLite and the shim)
are used by `build.sh` when the box's gcc major version matches the one that produced them and are
silently skipped otherwise, so the build is identical on CI. Both are profile data, not build output.
Expect single-digit percent: the hot path is SQLite and the kernel's TCP stack.

## Measured

_To be filled from `results/REPORT.md` after the AWS runs (c7a.medium, 1 vCPU / 2 GiB, Ubuntu 24.04,
kernel untouched, `LimitNOFILE=65535`, k6 on a separate box in the same AZ)._

Local sanity (Apple M-series, not comparable to the droplet): 5,000 VUs of `bench/load.js` →
0 errors, p95 0.75 ms, p99 1.8 ms, 49 MB RSS; write stress 58k rps, 0 errors, WAL ≤ 5 MB.

## License

MIT, under the repo's [license](../../LICENSE).
