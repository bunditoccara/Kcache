# KCache

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/kerolt/kcache)

KCache 是一个类 Memcached 的分布式缓存系统，采用 C/S 架构。客户端通过一致性哈希路由请求，缓存节点之间使用 gRPC 通信，并借助 etcd 做服务注册与发现。

## 特性

- **分布式路由**：一致性哈希与虚拟节点降低节点增减时的映射变更范围，并支持基于访问计数的后台重平衡实验。
- **防缓存击穿**：SingleFlight 合并同 key 的并发回源请求。
- **熔断降级**：Closed、Open、HalfOpen 三态熔断；回源失败时返回 Fallback 或过期缓存。
- **TTL 与淘汰**：写入时可指定 TTL，Get 时惰性删除；容量受限时使用 LRU 淘汰。
- **资源保护**：gRPC 超时、连接池复用、KeepAlive 与并发流限制。
- **可观测性**：Prometheus 指标端点暴露命中率、回源耗时、熔断状态和缓存容量。
- **最终一致性**：Set 通过 Invalidate 通知其他节点，Delete 广播到所有存活节点；TTL 作为广播失败时的兜底。

## 快速开始

### 环境与依赖

- Ubuntu 22.04 或兼容 Linux 环境
- GCC 11.4，C++17
- CMake 3.22+
- Conan 2.x
- Docker（运行 etcd 或完整 compose 集群时需要）

| 库 | 版本 | 用途 |
|---|---:|---|
| gflags | 2.2.2 | 命令行参数 |
| gtest | 1.16.0 | 单元测试 |
| protobuf | 3.21.12 | 序列化 |
| grpc | 1.54.3 | RPC 通信 |
| etcd-cpp-apiv3 | 0.15.4 | etcd 客户端 |
| fmt | 11.1.3 | 字符串格式化 |
| spdlog | 1.15.1 | 日志 |
| cpp-httplib | 0.20.1 | HTTP 服务 |
| nlohmann_json | 3.12.0 | JSON 解析 |

> `etcd-cpp-apiv3` 依赖 `libsystemd/255`。高版本内核（> 6.8）存在已知兼容问题，推荐在 Docker 或内核 <= 6.8 的环境构建。

### 构建

```sh
conan install . --build=missing -s build_type=Release
cmake --preset conan-release
cmake --build --preset conan-release -j
```

若 CMake 版本低于 3.23，无法使用 preset：

```sh
cmake -DCMAKE_TOOLCHAIN_FILE=build/Release/generators/conan_toolchain.cmake \
      -DCMAKE_BUILD_TYPE=Release -S . -B build -G Ninja
cmake --build build -j
```

主要产物位于 `bin/`：

| 二进制 | 说明 |
|---|---|
| `node_server` | 缓存节点 |
| `http_gateway` | HTTP REST 网关示例 |
| `bench_cache` | 绕过 gRPC 的 KCache 核心路径 benchmark |
| `test_*` | 单元测试 |

### 启动单节点

先启动 etcd：

```sh
docker run -d --name etcd \
  -p 2379:2379 \
  quay.io/coreos/etcd:v3.5.0 \
  etcd --advertise-client-urls http://0.0.0.0:2379 \
       --listen-client-urls http://0.0.0.0:2379
```

启动缓存节点：

```sh
./bin/node_server --port=8001 --node=A
```

可选启动 HTTP 网关：

```sh
./bin/http_gateway --http_port=9000
```

`node_server` 注册 etcd 时会选择本机的非回环 IPv4。虚拟机仅有 `127.0.0.1` 时会注册失败；启动前可用 `ip -4 -o addr show` 检查网卡地址。

## 架构与请求流程

```text
┌──────────┐     ┌──────────┐     ┌──────────┐
│ 客户端 1 │     │ 客户端 2 │     │ HTTP 网关 │
│  (SDK)  │     │  (SDK)  │     │  (SDK)  │
└────┬─────┘     └────┬─────┘     └────┬─────┘
     │                 │                 │
     └─────────────────┼─────────────────┘
                       │ 一致性哈希路由
                       │
     ┌─────────────────┼─────────────────┐
     │                 │                 │
┌────▼────┐       ┌────▼────┐       ┌────▼────┐
│ Node A  │◄──────┤  etcd   ├──────►│ Node C  │
│ (gRPC)  │       │ 注册中心 │       │ (gRPC)  │
└────┬────┘       └────┬────┘       └────┬────┘
     │                 │                 │
     └─────────────────┴─────────────────┘
                    Node B (gRPC)
```

### Get

```text
请求
  -> 客户端一致性哈希定位节点
  -> gRPC Get
  -> 节点本地 LRU 命中则返回
  -> 未命中时 SingleFlight 合并同 key 回源
  -> 熔断检查、getter 回源、写入缓存
  -> 返回结果
```

### Set 与 Delete

```text
Set:    写入目标节点 -> 向其他可用节点广播 Invalidate -> 汇总结果
Delete: 向所有存活节点广播 Delete -> 汇总结果
```

广播失败不会回滚成功写入或删除，缓存 TTL 用于限制最终不一致的持续时间。

## 使用方式

### Docker 部署

构建镜像：

```sh
docker build -t kcache:latest .
```

单节点：

```sh
docker run -d \
  --name kcache-node \
  --network host \
  kcache:latest \
  /app/bin/node_server --port=8001 --node=A
```

完整集群：

```sh
docker compose up -d
docker compose ps
docker compose logs -f
```

compose 会启动 `kcache-etcd`、三个缓存节点和 HTTP 网关。停止并清理容器：

```sh
docker compose down
```

### HTTP API

网关监听 `0.0.0.0:9000`。

```sh
# Get
curl http://localhost:9000/api/cache/default/Tom

# Set
curl -X POST http://localhost:9000/api/cache/default/Kerolt \
  -d '{"value":"1219"}'

# Delete
curl -X DELETE http://localhost:9000/api/cache/default/Kerolt
```

### C++ SDK

```cpp
#include "kcache/client.h"

CircuitBreakerConfig cb_cfg;
cb_cfg.failure_threshold = 5;
cb_cfg.recovery_timeout_ms = 5000;

KCacheClient client(
    "http://127.0.0.1:2379",
    "kcache",
    cb_cfg,
    std::chrono::milliseconds{200},
    256);

auto value = client.Get("default", "Tom");
client.Set("default", "Tom", "value");
client.Delete("default", "Tom");
```

### 命令行参数

#### node_server

| 参数 | 默认值 | 说明 |
|---|---|---|
| `--port` | 8001 | 节点 gRPC 端口 |
| `--node` | A | 节点标识符 |
| `--group` | default | 缓存组名称 |
| `--etcd_endpoints` | `http://127.0.0.1:2379` | etcd 地址 |
| `--getter_timeout_ms` | 3000 | getter 超时（ms），0 表示不超时 |
| `--metrics_port` | 0 | Prometheus 端口，0 表示禁用 |
| `--cache_ttl_ms` | 0 | 缓存 TTL（ms），0 表示永不过期 |
| `--log_level` | info | 日志级别 |

#### http_gateway

| 参数 | 默认值 | 说明 |
|---|---|---|
| `--http_port` | 9000 | HTTP 监听端口 |
| `--etcd_endpoints` | `http://127.0.0.1:2379` | etcd 地址 |
| `--service_name` | kcache | 服务名 |

## 核心机制

### 熔断与降级

熔断器有三态：

- **Closed**：正常请求；滑动窗口内失败达到 `failure_threshold` 后进入 Open。
- **Open**：拒绝请求，等待 `recovery_timeout_ms` 后进入 HalfOpen。
- **HalfOpen**：最多放行 `half_open_max_calls` 个探测请求；连续成功 `success_threshold` 次后恢复 Closed，任一失败重新 Open。

回源失败时按以下优先级降级：过期缓存、用户 Fallback、空结果。

### SingleFlight

同一 key 的并发未命中只允许一个先锋请求实际执行回源，其他请求等待并复用结果。实现支持等待超时和失败冷却，避免异常 key 反复创建回源任务。

### 一致性哈希

- CRC32 IEEE 哈希函数，兼容 Go `crc32.ChecksumIEEE`。
- 虚拟节点可降低节点增减带来的路由变更范围。
- 后台线程可依据访问计数调整虚拟节点数；该能力为实验性，会改变路由映射。

## 可观测性

以 `--metrics_port=8080` 启动节点后，访问 `http://localhost:8080/metrics`：

| 指标 | 类型 | 说明 |
|---|---|---|
| `kcache_local_hits` / `kcache_local_misses` | Counter | 本地缓存命中与未命中 |
| `kcache_loader_hits` / `kcache_loader_errors` | Counter | getter 回源成功与失败 |
| `kcache_circuit_breaks` | Counter | 熔断触发次数 |
| `kcache_fallback_hits` | Counter | Fallback 命中次数 |
| `kcache_getter_timeouts` | Counter | getter 超时次数 |
| `kcache_hit_ratio` | Gauge | 本地命中率 |
| `kcache_avg_load_duration_ms` | Gauge | 平均回源耗时 |
| `kcache_circuit_breaker_state` | Gauge | 1=Closed，2=Open，3=HalfOpen |
| `kcache_cache_bytes` / `kcache_cache_max_bytes` | Gauge | 当前与最大缓存容量 |
| `kcache_cache_count` | Gauge | 缓存条目数 |

## 压测

压测分为 gRPC 全栈和绕过 gRPC 的 KCache 裸调两条路径。梯度吞吐用于容量与延迟判断，perf 仅用于 CPU 热点归因；两种 QPS 不应相除并解释为某个组件的固定成本。

推荐使用本地脚本：

```sh
# gRPC 与裸调的无 perf 梯度；结果写入被忽略的 results/ 目录
./scripts/run_gradient_benchmarks.sh

# perf 热点与火焰图；需先允许内核符号解析
sudo sysctl -w kernel.kptr_restrict=0
./scripts/run_perf_hotspots.sh
```

脚本会保留必要的 `perf.data` 与 SVG 火焰图到本地 `results/`，该目录不会提交到 Git。手动命令、虚拟机权限要求、梯度口径与 perf 复现方式见 [压测执行手册](docs/benchmark-guide.md)。

## 项目结构

```text
.
├── include/kcache/              # SDK 公共头文件
├── src/
│   ├── cache/                   # LRU、TTL
│   ├── client/                  # 客户端 SDK
│   ├── consistent_hash/          # 一致性哈希
│   ├── group/                   # Get/Set/Delete、SingleFlight、Fallback
│   ├── registry/                # etcd 注册与续约
│   ├── server/                  # gRPC 服务与 Prometheus 指标
│   ├── proto/kcache.proto       # gRPC 协议
│   └── main.cpp                 # 节点入口
├── example/
│   ├── bench_cache/             # 核心路径 benchmark
│   └── http_gateway/            # HTTP 网关示例
├── test/                        # 单元测试
├── scripts/                     # 本地压测脚本
├── docs/benchmark-guide.md      # 压测执行手册
├── Dockerfile
├── docker-compose.yml
└── CMakeLists.txt
```

## 设计借鉴

- [Memcached](https://memcached.org/)：C/S 架构、客户端 SDK。
- [GroupCache](https://github.com/golang/groupcache)：Group 概念、SingleFlight。
- [7days-golang](https://github.com/geektutu/7days-golang)：分布式缓存教程。
- [KamaCache-Go](https://github.com/youngyangyang04/KamaCache-Go)：本项目 Go 语言参考实现。

## 许可证

MIT License，详见 [LICENSE](LICENSE)。
