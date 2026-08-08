#!/usr/bin/env bash

# Runs only the clean gRPC and KCache concurrency gradients.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

exec env MODE=gradient RUN_PERF=0 REPORT_PREFIX=gradient-summary \
    ./scripts/run_benchmark_suite.sh "$@"
