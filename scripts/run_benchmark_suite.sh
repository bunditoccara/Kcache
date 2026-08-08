#!/usr/bin/env bash

# One-pass benchmark suite. It writes one compact Markdown summary only.

set -u
set -o pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

TARGET="${TARGET:-localhost:8001}"
ETCD_ENDPOINT="${ETCD_ENDPOINT:-http://127.0.0.1:2379}"
PROTO="${PROTO:-./src/proto/kcache.proto}"
GROUP="${GROUP:-default}"
KEY="${KEY:-Tom}"
GRPC_DURATION="${GRPC_DURATION:-60s}"
BARE_DURATION_SEC="${BARE_DURATION_SEC:-30}"
PERF_DURATION_SEC="${PERF_DURATION_SEC:-60}"
COOLDOWN_SEC="${COOLDOWN_SEC:-2}"
MAX_CONNECTIONS="${MAX_CONNECTIONS:-8}"
START_SERVER="${START_SERVER:-1}"
RUN_PERF="${RUN_PERF:-1}"
MODE="${MODE:-all}"
GRPC_PERF_CONCURRENCY="${GRPC_PERF_CONCURRENCY:-128}"
BARE_PERF_THREADS="${BARE_PERF_THREADS:-64}"
REPORT_PREFIX="${REPORT_PREFIX:-benchmark-summary}"
FLAMEGRAPH_DIR="${FLAMEGRAPH_DIR:-$HOME/FlameGraph}"
LEVELS=(1 2 4 8 16 32 64 128 256)

REPORT_DIR="results"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
REPORT_PATH="$REPORT_DIR/$REPORT_PREFIX-$RUN_ID.md"
PERF_ARTIFACT_DIR="$REPORT_DIR/perf-artifacts-$RUN_ID"
TMP_DIR="$(mktemp -d)"
SERVER_PID=""
STARTED_SERVER=0
PERF_ENABLED=0

usage() {
    cat <<'EOF'
Usage: ./scripts/run_benchmark_suite.sh

The script starts node_server by default. etcd must already be healthy at
http://127.0.0.1:2379, and the VM must have a non-loopback IPv4 address.

Environment overrides:
  START_SERVER=0          Use an already-running node_server
  RUN_PERF=0              Skip the two perf runs
  MODE=gradient           Run gradients only
  MODE=perf               Run only perf at the configured points
  GRPC_PERF_CONCURRENCY=128  gRPC concurrency for MODE=perf
  BARE_PERF_THREADS=64    Bare threads for MODE=perf
  GRPC_DURATION=60s       Duration of each gRPC gradient level
  BARE_DURATION_SEC=30    Duration of each bare-cache gradient level
  PERF_DURATION_SEC=60    Duration of each perf workload
  COOLDOWN_SEC=2          Pause between gradient levels
  MAX_CONNECTIONS=8       gRPC connection cap
  TARGET=localhost:8001   gRPC target
EOF
}

cleanup() {
    if (( STARTED_SERVER )) && [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

append() {
    printf '%s\n' "$*" >> "$REPORT_PATH"
}

parse_ghz() {
    awk '
        function strip(line) {
            sub(/^[[:space:]]+/, "", line)
            sub(/[[:space:]]+$/, "", line)
            return line
        }
        function after_colon(line) {
            sub(/^[^:]*:[[:space:]]*/, "", line)
            return strip(line)
        }
        /^[[:space:]]*Requests\/sec:/ { rps = after_colon($0) }
        /^[[:space:]]*Average:/ { average = after_colon($0) }
        /^[[:space:]]*Count:/ { count = after_colon($0) }
        $1 == "50" && $2 == "%" && $3 == "in" { p50 = $4 " " $5 }
        $1 == "95" && $2 == "%" && $3 == "in" { p95 = $4 " " $5 }
        $1 == "99" && $2 == "%" && $3 == "in" { p99 = $4 " " $5 }
        /^Status code distribution:/ { in_status = 1; next }
        /^Error distribution:/ { in_status = 0; next }
        in_status && /^[[:space:]]*\[/ {
            status = status (status == "" ? "" : "; ") strip($0)
        }
        END {
            printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", rps, average, p50, p95, p99, count, status
        }
    '
}

parse_bare() {
    awk '
        function after_colon(line) {
            sub(/^[^:]*:[[:space:]]*/, "", line)
            return line
        }
        /总操作数:/ { count = after_colon($0) }
        /总耗时:/ { elapsed = after_colon($0) }
        /平均 QPS:/ { qps = after_colon($0) }
        END { printf "%s\t%s\t%s\n", qps, count, elapsed }
    '
}

is_greater() {
    local candidate="${1//,/}"
    local current="${2//,/}"
    awk -v candidate="$candidate" -v current="$current" 'BEGIN { exit !(candidate > current) }'
}

run_ghz() {
    local connections="$1"
    local concurrency="$2"
    shift 2

    ghz --insecure \
        --proto "$PROTO" \
        --call kcache.pb.KCache/Get \
        --data "{\"group\":\"$GROUP\",\"key\":\"$KEY\"}" \
        --connections="$connections" \
        --concurrency="$concurrency" \
        "$@" \
        "$TARGET"
}

append_grpc_row() {
    local concurrency="$1"
    local connections="$2"
    local metrics="$3"
    local rps average p50 p95 p99 count status
    IFS=$'\t' read -r rps average p50 p95 p99 count status <<< "$metrics"
    append "| $concurrency | $connections | $rps | $average | $p50 | $p95 | $p99 | $count | $status |"
}

append_grpc_gradient_row() {
    local concurrency="$1"
    local connections="$2"
    local metrics="$3"
    local rps average p50 p95 p99 count status non_ok
    IFS=$'\t' read -r rps average p50 p95 p99 count status <<< "$metrics"
    non_ok="$(printf '%s\n' "$status" | awk -F '; ' '
        {
            for (i = 1; i <= NF; ++i) {
                if ($i !~ /^\[OK\]/) {
                    value = $i
                    sub(/^[^0-9]*/, "", value)
                    split(value, parts, / /)
                    total += parts[1]
                }
            }
        }
        END { print total + 0 }
    ')"
    append "| $concurrency | $connections | $rps | $p99 | $non_ok |"
}

append_bare_row() {
    local threads="$1"
    local metrics="$2"
    local qps count elapsed
    IFS=$'\t' read -r qps count elapsed <<< "$metrics"
    append "| $threads | $qps | $count | $elapsed |"
}

append_bare_gradient_row() {
    local threads="$1"
    local metrics="$2"
    local qps count elapsed
    IFS=$'\t' read -r qps count elapsed <<< "$metrics"
    append "| $threads | $qps |"
}

print_grpc_result() {
    local concurrency="$1"
    local connections="$2"
    local metrics="$3"
    local append_to_table="${4:-1}"
    local rps average p50 p95 p99 count status
    IFS=$'\t' read -r rps average p50 p95 p99 count status <<< "$metrics"

    printf '\n=== gRPC: concurrency=%s, connections=%s ===\n' "$concurrency" "$connections"
    printf 'Requests/sec: %s\nAverage: %s\np50: %s\np95: %s\np99: %s\nCount: %s\n%s\n' \
        "$rps" "$average" "$p50" "$p95" "$p99" "$count" "$status"

    if [[ "$append_to_table" == "1" ]]; then
        append_grpc_row "$concurrency" "$connections" "$metrics"
    fi
}

print_bare_result() {
    local threads="$1"
    local metrics="$2"
    local append_to_table="${3:-1}"
    local qps count elapsed
    IFS=$'\t' read -r qps count elapsed <<< "$metrics"

    printf '\n=== Bare: threads=%s ===\n' "$threads"
    printf 'Average QPS: %s\nTotal operations: %s\nElapsed: %s\n' "$qps" "$count" "$elapsed"
    if [[ "$append_to_table" == "1" ]]; then
        append_bare_row "$threads" "$metrics"
    fi
}

run_grpc_gradient() {
    local best_qps="-1"
    BEST_GRPC_CONCURRENCY=""
    BEST_GRPC_CONNECTIONS=""

    append ""
    append "## gRPC Full-Stack Gradient (No perf)"
    append "| Concurrency | Connections | Requests/sec | p99 | Non-OK |"
    append "|---:|---:|---:|---:|---:|"

    for concurrency in "${LEVELS[@]}"; do
        local connections="$concurrency"
        local output metrics rps
        if (( connections > MAX_CONNECTIONS )); then
            connections="$MAX_CONNECTIONS"
        fi

        if ! output="$(run_ghz "$connections" "$concurrency" "--duration=$GRPC_DURATION" --skipFirst=1000 2>&1)"; then
            printf '%s\n' "$output" >&2
            die "gRPC gradient failed at concurrency=$concurrency"
        fi
        metrics="$(printf '%s\n' "$output" | parse_ghz)"
        print_grpc_result "$concurrency" "$connections" "$metrics" 0
        append_grpc_gradient_row "$concurrency" "$connections" "$metrics"
        IFS=$'\t' read -r rps _ <<< "$metrics"
        if is_greater "$rps" "$best_qps"; then
            best_qps="$rps"
            BEST_GRPC_CONCURRENCY="$concurrency"
            BEST_GRPC_CONNECTIONS="$connections"
            BEST_GRPC_METRICS="$metrics"
        fi
        sleep "$COOLDOWN_SEC"
    done

    BEST_GRPC_QPS="$best_qps"
}

run_bare_gradient() {
    local best_qps="-1"
    BEST_BARE_THREADS=""

    append ""
    append "## KCache Bare Gradient (No perf)"
    append "| Threads | Average QPS |"
    append "|---:|---:|"

    for threads in "${LEVELS[@]}"; do
        local output metrics qps
        if ! output="$(./bin/bench_cache --threads="$threads" --duration_sec="$BARE_DURATION_SEC" --capacity_mb=64 2>&1)"; then
            printf '%s\n' "$output" >&2
            die "bare benchmark failed at threads=$threads"
        fi
        metrics="$(printf '%s\n' "$output" | parse_bare)"
        print_bare_result "$threads" "$metrics" 0
        append_bare_gradient_row "$threads" "$metrics"
        IFS=$'\t' read -r qps _ <<< "$metrics"
        if is_greater "$qps" "$best_qps"; then
            best_qps="$qps"
            BEST_BARE_THREADS="$threads"
            BEST_BARE_METRICS="$metrics"
        fi
        sleep "$COOLDOWN_SEC"
    done

    BEST_BARE_QPS="$best_qps"
}

append_perf_report() {
    local title="$1"
    local data_file="$2"
    local report

    append ""
    append "### $title: perf top samples"
    append '```text'
    if report="$(perf report -i "$data_file" --stdio --children --sort=overhead,symbol 2>&1)"; then
        printf '%s\n' "$report" | sed -n '1,15p' >> "$REPORT_PATH"
    else
        printf '%s\n' "$report" >> "$REPORT_PATH"
    fi
    append '```'
}

generate_flamegraph() {
    local name="$1"
    local data_file="$2"
    local perf_script="$PERF_ARTIFACT_DIR/$name.perf"
    local folded="$PERF_ARTIFACT_DIR/$name.folded"
    local svg="$PERF_ARTIFACT_DIR/flamegraph-$name.svg"

    if [[ ! -f "$FLAMEGRAPH_DIR/stackcollapse-perf.pl" || ! -f "$FLAMEGRAPH_DIR/flamegraph.pl" ]]; then
        append "- FlameGraph tools not found at \`$FLAMEGRAPH_DIR\`; retained \`$data_file\` for manual analysis."
        return
    fi

    if perf script -i "$data_file" > "$perf_script" \
        && "$FLAMEGRAPH_DIR/stackcollapse-perf.pl" "$perf_script" > "$folded" \
        && "$FLAMEGRAPH_DIR/flamegraph.pl" "$folded" > "$svg"; then
        rm -f "$perf_script" "$folded"
        append "- Flame graph: \`$svg\`"
    else
        append "- Flame graph generation failed; retained \`$data_file\` and intermediate files in \`$PERF_ARTIFACT_DIR\`."
    fi
}

run_perf_cases() {
    append ""
    append "## Best-point perf Sampling"

    if (( ! PERF_ENABLED )); then
        append "perf was skipped: cpu-clock is unavailable or RUN_PERF=0."
        return
    fi

    mkdir -p "$PERF_ARTIFACT_DIR"
    append "- perf artifacts: \`$PERF_ARTIFACT_DIR\`"

    local grpc_data="$PERF_ARTIFACT_DIR/perf-grpc.data"
    local bare_data="$PERF_ARTIFACT_DIR/perf-bare.data"
    local output metrics

    printf '\n=== perf gRPC: concurrency=%s, connections=%s ===\n' \
        "$BEST_GRPC_CONCURRENCY" "$BEST_GRPC_CONNECTIONS"
    perf record -e cpu-clock -F 99 --call-graph fp -o "$grpc_data" \
        -p "$SERVER_PID" -- sleep "$((PERF_DURATION_SEC + 3))" &
    local perf_pid=$!
    sleep 1
    if output="$(run_ghz "$BEST_GRPC_CONNECTIONS" "$BEST_GRPC_CONCURRENCY" \
        "--duration=${PERF_DURATION_SEC}s" --skipFirst=1000 2>&1)"; then
        metrics="$(printf '%s\n' "$output" | parse_ghz)"
        print_grpc_result "$BEST_GRPC_CONCURRENCY" "$BEST_GRPC_CONNECTIONS" "$metrics" 0
        append ""
        append "### gRPC best point under perf"
        append "| Concurrency | Connections | Requests/sec | Average | p50 | p95 | p99 | Count | Status |"
        append "|---:|---:|---:|---:|---:|---:|---:|---:|---|"
        append_grpc_row "$BEST_GRPC_CONCURRENCY" "$BEST_GRPC_CONNECTIONS" "$metrics"
    else
        printf '%s\n' "$output" >&2
        append "gRPC perf workload failed."
    fi
    wait "$perf_pid" || append "gRPC perf record failed."
    if [[ -f "$grpc_data" ]]; then
        append_perf_report "gRPC best point" "$grpc_data"
        generate_flamegraph "grpc" "$grpc_data"
    fi

    printf '\n=== perf Bare: threads=%s ===\n' "$BEST_BARE_THREADS"
    if output="$(perf record -e cpu-clock -F 99 --call-graph fp -o "$bare_data" -- \
        ./bin/bench_cache --threads="$BEST_BARE_THREADS" --duration_sec="$PERF_DURATION_SEC" --capacity_mb=64 2>&1)"; then
        metrics="$(printf '%s\n' "$output" | parse_bare)"
        print_bare_result "$BEST_BARE_THREADS" "$metrics" 0
        append ""
        append "### KCache bare best point under perf"
        append "| Threads | Average QPS | Total operations | Elapsed |"
        append "|---:|---:|---:|---:|"
        append_bare_row "$BEST_BARE_THREADS" "$metrics"
    else
        printf '%s\n' "$output" >&2
        append "Bare perf workload failed."
    fi
    if [[ -f "$bare_data" ]]; then
        append_perf_report "Bare best point" "$bare_data"
        generate_flamegraph "bare" "$bare_data"
    fi
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi

require_command ghz
require_command awk
require_command curl
[[ -x ./bin/node_server ]] || die "missing executable: ./bin/node_server"
[[ -x ./bin/bench_cache ]] || die "missing executable: ./bin/bench_cache"
[[ -f "$PROTO" ]] || die "proto file not found: $PROTO"
[[ "$MAX_CONNECTIONS" =~ ^[1-9][0-9]*$ ]] || die "MAX_CONNECTIONS must be a positive integer"
[[ "$COOLDOWN_SEC" =~ ^[0-9]+$ ]] || die "COOLDOWN_SEC must be a non-negative integer"
[[ "$BARE_DURATION_SEC" =~ ^[1-9][0-9]*$ ]] || die "BARE_DURATION_SEC must be an integer number of seconds"
[[ "$PERF_DURATION_SEC" =~ ^[1-9][0-9]*$ ]] || die "PERF_DURATION_SEC must be an integer number of seconds"
[[ "$MODE" == "all" || "$MODE" == "gradient" || "$MODE" == "perf" ]] \
    || die "MODE must be all, gradient, or perf"
[[ "$GRPC_PERF_CONCURRENCY" =~ ^[1-9][0-9]*$ ]] || die "GRPC_PERF_CONCURRENCY must be a positive integer"
[[ "$BARE_PERF_THREADS" =~ ^[1-9][0-9]*$ ]] || die "BARE_PERF_THREADS must be a positive integer"

if [[ "$MODE" == "perf" ]]; then
    command -v perf >/dev/null 2>&1 || die "MODE=perf requires perf"
    perf stat -e cpu-clock true >/dev/null 2>&1 || die "MODE=perf requires usable cpu-clock"
    if [[ -r /proc/sys/kernel/kptr_restrict ]] && (( $(< /proc/sys/kernel/kptr_restrict) > 0 )); then
        die "MODE=perf requires kernel.kptr_restrict=0 for readable kernel hotspots"
    fi
fi

mkdir -p "$REPORT_DIR"
{
    printf '# KCache Benchmark Summary\n\n'
    printf -- '- Generated: %s\n' "$(date '+%F %T %z')"
    printf -- '- Host mode: single-VM loopback gRPC\n'
    printf -- '- Script mode: `%s`\n' "$MODE"
    printf -- '- gRPC target: `%s`\n' "$TARGET"
    printf -- '- gRPC workload: `Get(%s/%s)` after warm-up\n' "$GROUP" "$KEY"
    printf -- '- Gradient: `%s`\n' "${LEVELS[*]}"
    printf -- '- Runs per level: `1`\n'
    printf -- '- Cooldown between levels: `%ss`\n' "$COOLDOWN_SEC"
    printf -- '- CPU count: `%s`\n' "$(nproc)"
} > "$REPORT_PATH"

if [[ "$START_SERVER" == "1" ]]; then
    curl -fsS "$ETCD_ENDPOINT/health" >/dev/null || die "etcd is not healthy at $ETCD_ENDPOINT"
    ip -4 -o addr show | awk '$4 !~ /^127\./ { found = 1 } END { exit !found }' \
        || die "node_server needs a non-loopback IPv4 address for etcd registration"

    printf 'Starting node_server ...\n'
    ./bin/node_server --port=8001 --node=A --log_level=warn > "$TMP_DIR/node_server.log" 2>&1 &
    SERVER_PID=$!
    STARTED_SERVER=1
    sleep 6
    kill -0 "$SERVER_PID" 2>/dev/null || {
        cat "$TMP_DIR/node_server.log" >&2
        die "node_server exited during startup"
    }
else
    SERVER_PID="$(pgrep -n node_server 2>/dev/null || true)"
    [[ -n "$SERVER_PID" ]] || die "START_SERVER=0 requires a running node_server"
fi

if [[ "$RUN_PERF" == "1" ]] && command -v perf >/dev/null 2>&1 && perf stat -e cpu-clock true >/dev/null 2>&1; then
    PERF_ENABLED=1
    append '- perf: `cpu-clock` enabled'
    if [[ -r /proc/sys/kernel/kptr_restrict ]] && (( $(< /proc/sys/kernel/kptr_restrict) > 0 )); then
        append '- perf symbols: kernel addresses are restricted (`kptr_restrict > 0`); user-space samples remain available.'
    fi
else
    append "- perf: skipped (set RUN_PERF=0 intentionally, or enable cpu-clock)"
fi

printf 'Validating gRPC service ...\n'
if ! validation_output="$(run_ghz 1 1 --total=1 2>&1)"; then
    printf '%s\n' "$validation_output" >&2
    die "gRPC validation request failed"
fi
printf '%s\n' "$validation_output" | grep -Eq '\[OK\][[:space:]]+1 responses' \
    || die "gRPC validation did not return one OK response"

printf 'Warming the local-hit path ...\n'
if ! warmup_output="$(run_ghz "$MAX_CONNECTIONS" "$MAX_CONNECTIONS" --total=1000 2>&1)"; then
    printf '%s\n' "$warmup_output" >&2
    die "gRPC warm-up failed"
fi

if [[ "$MODE" == "gradient" || "$MODE" == "all" ]]; then
    run_grpc_gradient
    run_bare_gradient

    append ""
    append "## Best-concurrency Benchmarks (No perf)"
    append "### gRPC Full-Stack Best Point"
    append "| Concurrency | Connections | Requests/sec | Average | p50 | p95 | p99 | Count | Status |"
    append "|---:|---:|---:|---:|---:|---:|---:|---:|---|"
    append_grpc_row "$BEST_GRPC_CONCURRENCY" "$BEST_GRPC_CONNECTIONS" "$BEST_GRPC_METRICS"
    append ""
    append "### KCache Bare Best Point"
    append "| Threads | Average QPS | Total operations | Elapsed |"
    append "|---:|---:|---:|---:|"
    append_bare_row "$BEST_BARE_THREADS" "$BEST_BARE_METRICS"
fi

if [[ "$MODE" == "perf" ]]; then
    BEST_GRPC_CONCURRENCY="$GRPC_PERF_CONCURRENCY"
    BEST_GRPC_CONNECTIONS="$GRPC_PERF_CONCURRENCY"
    if (( BEST_GRPC_CONNECTIONS > MAX_CONNECTIONS )); then
        BEST_GRPC_CONNECTIONS="$MAX_CONNECTIONS"
    fi
    BEST_BARE_THREADS="$BARE_PERF_THREADS"
fi

if [[ "$MODE" == "perf" || "$MODE" == "all" ]]; then
    run_perf_cases
fi

printf '\nBenchmark suite complete. Compact summary: %s\n' "$REPORT_PATH"
