# KCache 压测执行手册

本项目的性能测试分为两条不可混淆的路径：

1. **gRPC 全栈**：`ghz -> gRPC/HTTP2/protobuf -> node_server -> KCacheGroup::Get()`。
2. **KCache 裸调**：`bench_cache -> KCacheGroup::Get()`，不包含 RPC、协议栈和网络。

两条路径只能在各自内部比较，不能用两者 QPS 的比值推导某个组件的固定开销。

本文提供两种执行方式：使用脚本一次完成一类测试，或用命令行逐项手动执行。

## 1. 前置条件

### 1.1 构建与依赖

```sh
cmake --build --preset conan-release -j --target node_server bench_cache
ghz --version
perf stat -e cpu-clock true
```

需要 `ghz`、`perf`、`curl`、`awk`。虚拟机未提供硬件 PMU 时，本文使用 `cpu-clock` 软件事件，不依赖 vPMU。

若 `perf stat` 提示 `perf_event_paranoid` 权限不足：

```sh
sudo sysctl -w kernel.perf_event_paranoid=1
perf stat -e cpu-clock true
```

### 1.2 etcd 与网络

`node_server` 必须向 etcd 注册，并且当前实现要求虚拟机存在非回环 IPv4。

```sh
curl -fsS http://127.0.0.1:2379/health
ip -4 -o addr show
```

健康检查应返回 `{"health":"true"}`，网卡列表中应存在不是 `127.0.0.1` 的地址。若 etcd Docker 容器已创建但未运行：

```sh
docker start etcd
```

## 2. 脚本执行

脚本默认采用单 VMware 虚拟机 loopback 口径：ghz 和 `node_server` 共享 CPU、调度器与本机 TCP/IP 协议栈。它表示该 VM 的端到端能力，不是独立压测机驱动下的纯服务端上限。

### 2.1 梯度并发与裸测

```sh
./scripts/run_gradient_benchmarks.sh
```

脚本会自行启动和停止 `node_server`，因此运行前不要手动占用 `8001` 端口。它会执行：

- gRPC 并发：`1, 2, 4, 8, 16, 32, 64, 128, 256`，连接数为 `min(并发, 8)`。
- KCache 裸测线程：`1, 2, 4, 8, 16, 32, 64, 128, 256`。
- 每档只运行 1 次；gRPC 默认 60 秒，裸测默认 30 秒，档位间隔默认 2 秒。

结果写入唯一的精简文档：

```text
results/gradient-summary-<时间>.md
```

该文档只保留 gRPC 梯度的并发/连接/QPS/p99/非 OK 数、裸测梯度的线程/QPS，以及两个场景的最佳点完整数据。

可选参数：

```sh
COOLDOWN_SEC=0 ./scripts/run_gradient_benchmarks.sh
GRPC_DURATION=30s BARE_DURATION_SEC=15 ./scripts/run_gradient_benchmarks.sh
```

### 2.2 perf CPU 热点分析

先从梯度结果选择待分析点。gRPC 默认分析推荐并发 128；裸测默认分析 64 线程的高竞争档。裸测 1 线程仅用于无竞争吞吐基线，不能用于定位并发锁竞争。

perf 的函数级内核热点需要可读内核符号：

```sh
sudo sysctl -w kernel.kptr_restrict=0
./scripts/run_perf_hotspots.sh
```

默认采样 gRPC `128` 并发与裸测 `64` 线程。要分析 gRPC 峰值吞吐点：

```sh
GRPC_PERF_CONCURRENCY=256 ./scripts/run_perf_hotspots.sh
```

需要观察更强的裸测过载竞争时：

```sh
BARE_PERF_THREADS=128 ./scripts/run_perf_hotspots.sh
```

结果写入：

```text
results/perf-hotspot-summary-<时间>.md
results/perf-artifacts-<时间>/perf-grpc.data
results/perf-artifacts-<时间>/perf-bare.data
results/perf-artifacts-<时间>/flamegraph-grpc.svg
results/perf-artifacts-<时间>/flamegraph-bare.svg
```

perf 脚本会保留两份 `perf.data`，并在 `$HOME/FlameGraph` 存在 `stackcollapse-perf.pl` 与 `flamegraph.pl` 时自动生成两个 SVG 火焰图。中间的 `.perf` 与 `.folded` 文件会自动删除；需要自定义 FlameGraph 路径时设置 `FLAMEGRAPH_DIR=/path/to/FlameGraph`。脚本会在 `cpu-clock` 不可用或 `kptr_restrict > 0` 时直接退出，不生成无法归因的地址热点报告。`kptr_restrict=0` 会降低内核地址保护，只应在受控测试 VM 使用。

## 3. 命令行执行

命令行方式不自动保存 JSON 或日志。直接从终端记录 `Requests/sec`、`Average`、p50/p95/p99、`Count` 和状态码即可。

### 3.1 启动与预热 gRPC 服务

终端 A：

```sh
./bin/node_server --port=8001 --node=A --log_level=warn
```

终端 B，等待至少 6 秒后验证并预热：

```sh
ghz --insecure \
  --proto ./src/proto/kcache.proto \
  --call kcache.pb.KCache/Get \
  --data '{"group":"default","key":"Tom"}' \
  --connections=1 --total=1 \
  localhost:8001

ghz --insecure \
  --proto ./src/proto/kcache.proto \
  --call kcache.pb.KCache/Get \
  --data '{"group":"default","key":"Tom"}' \
  --connections=8 --concurrency=8 --total=1000 \
  localhost:8001
```

验证请求必须返回 `OK`。终端 A 保持服务运行，后续命令在终端 B 执行。

### 3.2 gRPC 梯度并发

以下循环只运行 1 轮，每档输出明确的并发标签。低并发时自动降低连接数，避免 ghz 的 `connections > concurrency` 错误。

```sh
LEVELS=(1 2 4 8 16 32 64 128 256)

for c in "${LEVELS[@]}"; do
  connections="$c"
  if [ "$connections" -gt 8 ]; then
    connections=8
  fi

  printf '\n=== gRPC: concurrency=%s, connections=%s ===\n' "$c" "$connections"
  ghz --insecure \
    --proto ./src/proto/kcache.proto \
    --call kcache.pb.KCache/Get \
    --data '{"group":"default","key":"Tom"}' \
    --connections="$connections" \
    --concurrency="$c" \
    --duration=60s \
    --skipFirst=1000 \
    localhost:8001
  sleep 2
done
```

### 3.3 KCache 裸测梯度

```sh
LEVELS=(1 2 4 8 16 32 64 128 256)

for t in "${LEVELS[@]}"; do
  printf '\n=== Bare: threads=%s ===\n' "$t"
  ./bin/bench_cache --threads="$t" --duration_sec=30 --capacity_mb=64
  sleep 2
done
```

### 3.4 手动 perf：gRPC 全栈

在梯度中选定目标并发后，例如 128：

```sh
SERVER_PID="$(pgrep -n node_server)"

perf record -e cpu-clock -F 99 --call-graph fp \
  -o perf-grpc.data -p "$SERVER_PID" -- sleep 63 &
PERF_PID=$!

sleep 1
ghz --insecure \
  --proto ./src/proto/kcache.proto \
  --call kcache.pb.KCache/Get \
  --data '{"group":"default","key":"Tom"}' \
  --connections=8 --concurrency=128 \
  --duration=60s --skipFirst=1000 \
  localhost:8001

wait "$PERF_PID"
perf report -i perf-grpc.data --stdio --children --sort=overhead,symbol
rm perf-grpc.data
```

### 3.5 手动 perf：KCache 裸调

在梯度中选定高竞争目标线程后，例如 64：

```sh
perf record -e cpu-clock -F 99 --call-graph fp \
  -o perf-bare.data \
  -- ./bin/bench_cache --threads=64 --duration_sec=60 --capacity_mb=64

perf report -i perf-bare.data --stdio --children --sort=overhead,symbol
rm perf-bare.data
```

## 4. 结果判读

- **峰值吞吐并发**：无 perf 梯度中 QPS 最大的档位。
- **推荐并发**：下一档 QPS 增益很小、但 p99 明显升高时，取前一档。
- **perf 数据**：只用于 CPU 热点归因；perf 下的 QPS 不替代无 perf 的吞吐口径。
- **非 OK 状态**：保留并统计。若包含 ghz 测试结束时关闭 client connection 的错误文本，也不能无证据地直接剔除。
