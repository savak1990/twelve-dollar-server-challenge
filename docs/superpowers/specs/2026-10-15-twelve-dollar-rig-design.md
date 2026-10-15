# Twelve-Dollar Server Challenge — benchmark rig + Go submission (design)

Approved 2026-10-15. The authoritative, task-level version lives in the Claude plan file; this is
the design record.

## Goal

1. A reproducible benchmark rig on AWS that scores an implementation exactly like
   `arjaythedev/twelve-dollar-server-challenge`: 1 vCPU / 2 GB target, k6 `bench/load.js`,
   pass = p95 < 500 ms, p99 < 1 s, < 1 % errors over a 5-minute hold.
2. A Go submission that holds 60k virtual users on that target, PR-ready for upstream.

## Decisions

| Topic | Decision | Why |
|---|---|---|
| Cloud | AWS `eu-west-1`, profile `viacheslav-dev` | Only account with EC2 rights; same-AZ private networking keeps WAN jitter out of p99 |
| Target | `c7a.medium` (1 vCPU / 2 GiB) | Only non-burstable 1-vCPU-2-GB shape. Faster than a DO shared vCPU → results optimistic; documented |
| Load generator | `r7a.2xlarge` spot, 4 private IPs, k6 `--local-ips` | k6 ≈ 280 KB/VU → ~17 GB at 60k; 4 IPs avoid ephemeral-port exhaustion; tuning the loadgen is allowed |
| SG on target | 80 from `0.0.0.0/0`, all egress | Makes port-80 flows untracked, so the SG conntrack allowance can't be a hidden wall |
| Target kernel | untouched | Upstream rule 11; only the systemd unit (`LimitNOFILE=65535`, `CAP_NET_BIND_SERVICE`) |
| HTTP | fasthttp, direct on :80, `ReduceMemoryUsage` | Simplest path to 60k keep-alive connections; epoll loop only if fasthttp caps out |
| SQLite | pinned amalgamation via thin cgo shim, `THREADSAFE=0`, one connection, one DB goroutine | No `database/sql` boxing, one cgo call per request, SQLite compiled with target flags + gcc PGO |
| JSON | built by SQLite (`json_object`, `json_group_array(json(o) ORDER BY …)`) | One text column copied straight to the socket |
| Writes | group commit: batch all queued writes in one `BEGIN IMMEDIATE … COMMIT`, respond after COMMIT | Rule 6 kept; one WAL append per batch |
| Checkpoint | `wal_autocheckpoint=0`, inline `TRUNCATE` when queue is idle and WAL > 1,000 frames | Avoids the WAL-never-rewinds trap seen with PASSIVE in other Go PRs |
| PGO | Go `default.pgo` from SIGUSR1 CPU profiles; gcc `-fprofile-use` for SQLite with `__gcov_dump` | Expect single-digit % — the hot path is SQLite + kernel TCP |
| State | local Terraform state, `make status` by tag | Single operator; orphan safety via tags |

## Make contract

`make serve` (target up + deploy + 42/42 on the box), `make test VUS=N DURATION=5m` (one hold),
`make search` (warm-up → raw `/feed` probe → binary search from 2,500 with 2-min holds → 5-min
confirm), `make profile VUS=N`, `make results`, `make down CONFIRM=yes`.

## Fidelity gaps vs the videos (documented, not fixed)

- Dedicated Zen 4 vCPU vs DigitalOcean shared vCPU → our numbers are optimistic.
- AWS Ubuntu AMI has no ufw, so `nf_conntrack` is not loaded: the 64k Linux conntrack wall from the
  video does not exist here. The AWS SG allowance is sidestepped by untracked flows.
- One k6 process on one box instead of four; loadgen CPU is recorded per run and a failing run with
  loadgen CPU > 70 % is flagged loadgen-bound.
