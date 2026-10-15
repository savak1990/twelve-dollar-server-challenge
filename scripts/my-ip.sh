#!/usr/bin/env bash
# Prints the operator's public IPv4 (for the SSH security-group rule).
set -euo pipefail
curl -fsS --max-time 5 https://checkip.amazonaws.com | tr -d '[:space:]'
