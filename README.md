# Twelve-Dollar Server Challenge — own rig

A reproducible copy of the [$12 server challenge](https://github.com/arjaythedev/twelve-dollar-server-challenge)
benchmark on AWS, plus a Go submission tuned to hold 60k virtual users on a 1 vCPU / 2 GB box.

`SPEC.md`, `schema.sql`, `seed/`, `test/`, `bench/load.js` and `bench/nginx.conf` are copied verbatim
from upstream (MIT, see `LICENSE-upstream`, commit in `UPSTREAM_COMMIT`). Everything else is ours.

## Quick start

```bash
make seed                      # seed/feed.db + seed/tokens.json (node >= 18, sqlite3; ~1 min)
make unit test-local           # Go tests + the upstream 42-check suite against a local build
make serve                     # c7a.medium target up, submission built on the box, 42/42 there
make test VUS=60000 DURATION=5m   # one k6 hold from the load generator (created on demand)
make search                    # full methodology: warm-up, raw probe, binary search, 5-min confirm
make results                   # pull results/ and rebuild results/REPORT.md
make down CONFIRM=yes          # destroy everything
```

AWS profile defaults to `viacheslav-dev` / `eu-west-1` (override `AWS_PROFILE`, `AWS_REGION`).
`make status` lists every instance tagged `Project=twelve-dollar`, in case state is lost.

**CPU and memory in CloudWatch.** EC2's built-in charts cannot see guest memory and sample CPU every
5 minutes, so both boxes run the CloudWatch agent with a CPU + memory config (IAM role
`twelve-dollar-cwagent`). Metrics are in the custom namespace `twelve-dollar`, dimension
`role=target|loadgen`: CloudWatch → Metrics → All metrics → twelve-dollar, or `make mon` in the
terminal (`WATCH=1 make mon` refreshes every 30 s; CloudWatch lags 1–2 min). The agent costs the
target ~40 MB RSS; the 5-second sampler in `bench/sample-host.sh` remains the source for the report.

**Code reaches the boxes only through GitHub.** Both instances `git clone`
`https://github.com/savak1990/twelve-dollar-server-challenge.git` (`REPO_REF=main`) at boot; the
target then runs `scripts/bootstrap-target.sh` (install toolchain, build from source, build the seed
DB once, fresh DB, start, 42 checks). `make deploy` pulls the ref on the target and re-runs it;
`make test`/`make search` pull on the loadgen. So: commit, push, then run make — `make serve` and
`make deploy` warn if the local tree is ahead of the remote. Forks: override `REPO_URL` and
`GH_USER` (the submission folder's suffix).

## Layout

| Path | What |
|---|---|
| `submissions/go-fasthttp-<user>/` | The Go submission, in the upstream PR contract (`install.sh`, `build.sh`, `start.sh`, `README.md`) |
| `infra/` | Terraform: VPC, target `c7a.medium`, optional loadgen `r7a.2xlarge` spot with 4 private IPs |
| `bench/` | upstream `load.js` + our `hold.sh`, `search.sh`, `raw-feed.js`, `sample-host.sh`, `report.sh` |
| `scripts/` | deploy / run-bench / profile / fetch-results helpers used by the Makefile |
| `results/` | per-run k6 summaries + host metrics (gitignored) and `REPORT.md` |
| `docs/superpowers/specs/` | design record |
| `docs/curl-cheatsheet.md` | plain curl for every endpoint and error path, plus how to run a local server |

## Fidelity vs the videos

- Target is a dedicated Zen 4 vCPU (`c7a.medium`), faster than a DigitalOcean shared vCPU. Numbers here are optimistic.
- The target kernel is untouched (rule 11). Only the systemd unit mirrors upstream: `LimitNOFILE=65535`, `CAP_NET_BIND_SERVICE`, non-root.
- No ufw on the AWS Ubuntu AMI, so `nf_conntrack` is not loaded: the 64k conntrack wall from the video does not exist here.
  Port 80 is open to `0.0.0.0/0` with unrestricted egress so AWS security-group tracking leaves those flows untracked.
- One k6 process on one box with 4 source IPs instead of four machines. Loadgen CPU is recorded per run; a failing run
  with loadgen CPU > 70 % is flagged loadgen-bound rather than a server failure.

## Cost

| Resource | Hourly | Note |
|---|---|---|
| target `c7a.medium` | ≈ $0.06 | ~$40/month if forgotten — `make down` |
| loadgen `r7a.2xlarge` | ≈ $0.61 on-demand, ≈ $0.2 spot | self-terminates after 6 h |

A full `make search` is roughly 1.5–2 hours ≈ $1–2.
