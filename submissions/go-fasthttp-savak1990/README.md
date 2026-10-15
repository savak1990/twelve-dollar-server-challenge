# Go + fasthttp + SQLite (amalgamation, cgo), direct on :80

| | |
|---|---|
| Language | Go 1.27.1 (official tarball, sha256-checked by `install.sh`) |
| HTTP | [`valyala/fasthttp`](https://github.com/valyala/fasthttp) v1.75.0, no router, no middleware |
| SQLite | 3.54.0 amalgamation, downloaded and sha256-checked by `build.sh`, compiled to a static library and linked in through a ~60-line C shim; **no `database/sql`**. Optional `SQLITE_BACKEND=go` swaps in [`zombiezen.com/go/sqlite`](https://pkg.go.dev/zombiezen.com/go/sqlite) v1.4.2 (pure Go, modernc) behind the same interface, for A/B runs; default is `cgo` |
| JSON | responses are rendered **by SQLite** (`json_object`, `json_group_array`); request JSON and JWTs are read by a small allocation-free scanner |
| Auth | HS256 with precomputed HMAC pads, constant-time compare, verified on every request |
| Dependencies | fasthttp, zombiezen/go-sqlite (only used when `SQLITE_BACKEND=go`) + the Go standard library + SQLite. `go.sum` pins everything |
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

**Profile-guided optimisation.** Two profile files sit next to the source, both recorded under the
k6 workload on the target: `default.pgo` (Go PGO, picked up automatically by `go build`) and
`sqlite#sqlite3.gcda` + `gcc-version` (gcc PGO of the SQLite amalgamation, used by `build.sh` when the
box's gcc major matches and silently skipped otherwise, so the build is identical on CI). Both are
profile data, not build output. The raw cpu/heap pprof copies live in `pgo/`, gitignored.
Expect single-digit percent: the hot path is SQLite and the kernel's TCP stack.

## Measured

AWS `c7a.medium` (1 dedicated Zen 4 vCPU / 2 GiB, Ubuntu 24.04, kernel untouched, direct on :80),
k6 on a separate box in the same AZ, 5-minute holds of `bench/load.js`. The unit's `LimitNOFILE`
was raised to 1,048,576 for the rows above 65k; upstream benchmarks at 65,535, and a dedicated vCPU
is faster than the DigitalOcean shared one, so these are upper bounds, not leaderboard numbers.

| VUs | verdict | rps | p95 | p99 | errors | CPU | RSS (anon) |
|---:|---|---:|---:|---:|---:|---:|---:|
| 20,000 | PASS | 1,868 | 0.4 ms | 15 ms | 0 % | 19 % | 118 MB |
| 40,000 | PASS | 3,736 | 1 ms | 13 ms | 0 % | 33 % | 231 MB |
| 60,000 | PASS | 5,601 | 6.1 ms | 18 ms | 0 % | ~45 % | ~340 MB |
| 80,000 | PASS | 7,468 | 7.1 ms | 21 ms | 0 % | 56 % | 459 MB |
| 120,000 | PASS | 11,171 | 117 ms | 187 ms | 0 % | 80 % | 703 MB |
| 135,000 | PASS | 12,477 | 184 ms | 644 ms | 0 % | 85 % | 795 MB |
| 140,000 | FAIL / PASS | 12,800 | 491 / 246 ms | 1,820 / 825 ms | 0 % | 86–89 % | 869 MB |

135,000 confirmed. The limit is tail latency from the inline WAL checkpoint (an fsync on the one DB
goroutine, every ~1,000 frames ≈ once a second at this write rate), not CPU saturation, errors or
memory; no GC ran during the 140k hold. With the pure-Go binding (`SQLITE_BACKEND=go`) the same
80k load costs 86 % CPU with p99 154 ms, against 56 % and 21 ms through the C shim.

Local sanity (Apple M-series, not comparable to the droplet): 5,000 VUs of `bench/load.js` →
0 errors, p95 0.75 ms, p99 1.8 ms, 49 MB RSS; write stress 58k rps, 0 errors, WAL ≤ 5 MB.

## License

MIT, under the repo's [license](../../LICENSE).
