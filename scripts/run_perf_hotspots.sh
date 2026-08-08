#!/usr/bin/env bash

# Runs only perf profiling at explicitly selected best points.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

GRPC_PERF_CONCURRENCY="${GRPC_PERF_CONCURRENCY:-128}"
BARE_PERF_THREADS="${BARE_PERF_THREADS:-64}"

exec env MODE=perf RUN_PERF=1 REPORT_PREFIX=perf-hotspot-summary \
    GRPC_PERF_CONCURRENCY="$GRPC_PERF_CONCURRENCY" \
    BARE_PERF_THREADS="$BARE_PERF_THREADS" \
    ./scripts/run_benchmark_suite.sh "$@"
