# Twelve-Dollar Server Challenge: own benchmark rig + Go submission.
# See README.md. `make help` lists targets.
SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
.ONESHELL:
.DEFAULT_GOAL := help

export AWS_PROFILE ?= viacheslav-dev
export AWS_REGION  ?= eu-west-1

GH_USER    ?= savak1990
NAME       := go-fasthttp-$(GH_USER)
SUBMISSION := submissions/$(NAME)
SSH_PUBKEY ?= $(HOME)/.ssh/id_ed25519_personal.pub
SSH_KEY    := $(patsubst %.pub,%,$(SSH_PUBKEY))
SSH        := ssh -i $(SSH_KEY) -o UserKnownHostsFile=infra/known_hosts -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30
TF         := terraform -chdir=infra

# Both instances clone this public repo at boot and `make deploy` pulls it again: nothing is copied
# from the workstation, so push before serve/deploy/test.
REPO_URL ?= https://github.com/savak1990/twelve-dollar-server-challenge.git
REPO_REF ?= main

# Benchmark knobs (make test VUS=60000 DURATION=5m)
VUS      ?= 1000
DURATION ?= 2m
RAMP_UP  ?= 60s
# Open-connection ceiling of the server unit (LimitNOFILE). Upstream uses 65535; the default here
# lets the box go past 65k users. TARGET_NOFILE=65535 for an upstream-faithful run.
TARGET_NOFILE ?= 1048576

TF_VARS = -var ssh_pubkey_path=$(SSH_PUBKEY) -var my_ip=$$(bash scripts/my-ip.sh) \
          -var submission=$(NAME) -var repo_url=$(REPO_URL) -var repo_ref=$(REPO_REF) \
          -var target_nofile=$(TARGET_NOFILE)
# Current loadgen state, normalised to a bool: with no state yet, `terraform output` prints nothing.
LOADGEN_STATE = $$(v=$$($(TF) output -raw loadgen_enabled 2>/dev/null || true); [ "$$v" = true ] && echo true || echo false)

.PHONY: help seed unit build test-local serve deploy test search profile results status ssh-target ssh-loadgen test-down down tf-init tf-validate check-aws check-pushed

help: ## List targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

# ---------------------------------------------------------------- local

seed: seed/feed.db ## Build seed/feed.db + seed/tokens.json locally (node >= 18, sqlite3)
seed/feed.db:
	bash seed/make-seed.sh

unit: build ## Go unit tests for the submission (needs the SQLite static lib from build)
	cd $(SUBMISSION) && go test ./...

build: ## Build the submission for this host (cgo)
	bash $(SUBMISSION)/build.sh

test-local: seed ## Run the upstream 42-check suite against a local build
	bash test/run.sh $(SUBMISSION)

tf-validate: ## terraform fmt + validate (offline)
	$(TF) fmt -recursive -check
	$(TF) init -backend=false -input=false >/dev/null
	$(TF) validate

# ---------------------------------------------------------------- infra

check-aws: ## Verify AWS_PROFILE exists and its credentials work
	@aws configure list-profiles | grep -qx "$(AWS_PROFILE)" || { echo "AWS_PROFILE='$(AWS_PROFILE)' is not a configured profile. Known: $$(aws configure list-profiles | tr '\n' ' ')"; exit 1; }
	@acct=$$(aws sts get-caller-identity --query Account --output text 2>/dev/null) && echo "aws: profile $(AWS_PROFILE), account $$acct, region $(AWS_REGION)" \
	  || { echo "AWS_PROFILE='$(AWS_PROFILE)': credentials not valid (expired SSO/session?)"; exit 1; }

tf-init: check-aws
	@$(TF) init -input=false >/dev/null

serve: tf-init check-pushed ## Launch the 1 vCPU / 2 GB target; it clones $(REPO_URL)@$(REPO_REF) and bootstraps itself
	$(TF) apply -input=false -auto-approve $(TF_VARS) -var enable_loadgen=$(LOADGEN_STATE)
	bash scripts/wait-bootstrap.sh "$$($(TF) output -raw target_public_ip)" "$(SSH_KEY)"

deploy: check-pushed ## Pull $(REPO_REF) on the target and re-bootstrap (build on the box, fresh DB, 42 checks)
	bash scripts/deploy-target.sh "$$($(TF) output -raw target_public_ip)" "$(NAME)" "$(SSH_KEY)"

check-pushed: ## Warn when the local branch has commits or changes not yet on $(REPO_URL)
	@git diff --quiet && git diff --cached --quiet || echo "warning: uncommitted changes; the boxes build from GitHub, not from this tree"
	@u=$$(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null) && [ "$$(git rev-list --count $$u..HEAD)" = 0 ] \
	  || echo "warning: local commits not pushed (or no upstream set); the boxes will build $(REPO_REF) as it is on GitHub"

test: tf-init ## One k6 hold: make test VUS=60000 DURATION=5m
	$(TF) apply -input=false -auto-approve $(TF_VARS) -var enable_loadgen=true
	bash scripts/run-bench.sh hold "$(VUS)" "$(DURATION)" "$(RAMP_UP)"

search: tf-init ## Full methodology: warm-up, raw probe, binary search, 5-min confirm
	$(TF) apply -input=false -auto-approve $(TF_VARS) -var enable_loadgen=true
	bash scripts/run-bench.sh search

profile: ## PGO cycle at VUS: train Go + SQLite profiles, rebuild, redeploy
	bash scripts/profile.sh "$(VUS)" "$(NAME)"

results: ## Fetch results/ from the loadgen and rebuild results/REPORT.md
	bash scripts/fetch-results.sh

BACKEND ?= cgo
backend: ## Switch the target's SQLite backend (BACKEND=cgo|go) via /srv/app/twelve.env and restart
	@[ "$(BACKEND)" = cgo ] || [ "$(BACKEND)" = go ] || { echo "BACKEND must be cgo or go"; exit 1; }
	$(SSH) ubuntu@$$($(TF) output -raw target_public_ip) 'sudo touch /srv/app/twelve.env; sudo sed -i "/^SQLITE_BACKEND=/d" /srv/app/twelve.env; \
	  echo SQLITE_BACKEND=$(BACKEND) | sudo tee -a /srv/app/twelve.env >/dev/null; sudo systemctl restart twelve.service; \
	  for i in $$(seq 30); do curl -sf http://127.0.0.1/health >/dev/null && break; sleep 1; done; curl -s http://127.0.0.1/health; echo " backend=$(BACKEND)"'

dashboard: tf-init ## Create/refresh the CloudWatch dashboard (CPU + memory, target vs loadgen) and print its URL
	$(TF) apply -input=false -auto-approve $(TF_VARS) -var enable_loadgen=$(LOADGEN_STATE) -target=aws_cloudwatch_dashboard.rig >/dev/null
	@$(TF) output -raw dashboard_url; echo

status: ## List every instance tagged Project=twelve-dollar
	aws ec2 describe-instances --filters Name=tag:Project,Values=twelve-dollar Name=instance-state-name,Values=pending,running,stopping,stopped \
	  --query 'Reservations[].Instances[].[Tags[?Key==`Role`]|[0].Value,InstanceType,State.Name,PublicIpAddress,LaunchTime]' --output table

ssh-target: ## SSH into the target
	$(SSH) ubuntu@$$($(TF) output -raw target_public_ip)

ssh-loadgen: ## SSH into the load generator
	$(SSH) ubuntu@$$($(TF) output -raw loadgen_public_ip)

test-down: tf-init ## Destroy only the load generator
	$(TF) apply -input=false -auto-approve $(TF_VARS) -var enable_loadgen=false

down: tf-init ## Destroy everything (CONFIRM=yes)
	@[ "$(CONFIRM)" = yes ] || { echo "refusing: run 'make down CONFIRM=yes'"; exit 1; }
	$(TF) destroy -input=false -auto-approve $(TF_VARS)
