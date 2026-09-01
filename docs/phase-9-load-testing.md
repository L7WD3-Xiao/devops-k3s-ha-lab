# Phase 9：高并发压测与容量评估（k6 方案）

> 日期：2026-08-31
> 状态：⏳ 计划中 — 方案已定稿，压测执行后回填实测数据
> 前置文档：[phase-3-data-layer.md](phase-3-data-layer.md)（数据层）、[phase-4-app-deploy.md](phase-4-app-deploy.md)（应用部署）
> 关联文档：[project-resume-star-interview.md](project-resume-star-interview.md) Q25（容量估算口径，压测后升级为实测）

---

## 1. 概述

### 1.1 目标

在 3 节点（2C4G）K3s 集群上对短链服务做**高并发压测**，回答三个问题：

1. 集群能抗多少 QPS？（读 / 写 / 混合三种口径）
2. 饱和点在哪个组件？（应用 Pod CPU limit / MySQL 单主 / ProxySQL 连接池 / Redis）
3. P99 是多少？（k6 客户端压测直接输出精确 p(99)，无需近似；配合 K3s 内置 metrics-server 观察资源）

### 1.2 原则

- **最小工具集**：k6（单二进制，JS 脚本驱动）+ metrics-server（K3s 内置），不装 Prometheus/Grafana，保持 Phase 8 之前“无监控体系”的现状，但依然能出量化数据。
- **先口径后实测**：先用硬件 + 架构反推估算基线（第 3 节），压测用于**校准**而不是从零探索，避免盲打浪费时间。
- **不压垮自己**：压测从 node-01 内网发起（不占 EIP 公网带宽），避开备份窗口（MySQL 02:00 / Velero 02:30），全程可回滚。

---

## 2. 压测拓扑

```
压测机 = node-01（运维节点，内网发起，避免 EIP 带宽成为瓶颈）
   │
   │ k6 run --vus 100 script-read.js    （读路径，预置短码 + 缓存命中）
   │ k6 run --vus 50  script-shorten.js  （写路径，动态 body）
   ▼
Traefik Ingress :80 ──► shortlink Service :8080（app-layer，2 副本，HPA 2~6）
                              │
              ┌───────────────┴────────────────┐
              ▼                                ▼
      ProxySQL:6033 (data-layer)        Sentinel:26379 → Redis Master
      读写分离：SELECT → Slave          缓存命中直接返回（读路径主路）
      INSERT/UPDATE → Master           缓存未命中才回源 MySQL
```

**观测点：**

| 观测对象 | 命令 / 入口 | 关注指标 |
|---------|------------|---------|
| shortlink Pod | `kubectl top pod -n app-layer` | CPU 是否顶到 200m limit（饱和信号） |
| HPA | `kubectl get hpa -n app-layer` | 是否扩容、当前副本数、CPU 利用率 |
| 节点 | `kubectl top node` | 控制面 / Traefik / 应用争抢情况 |
| MySQL Master | `SHOW GLOBAL STATUS LIKE 'Threads_connected'` 等 | 连接数、Com_insert 差值 = 写 TPS |
| ProxySQL | Admin 6032：`stats_mysql_connection_pool` | 连接池饱和、后端延迟 |
| Redis | `redis-cli INFO stats` | ops/s、命中率（`keyspace_hits/misses`） |

---

## 3. 估算口径（压测前基线）

> 无监控体系、未实测，以下为基于硬件 + 架构反推的工程估算（误差可能 3~5 倍），压测结果用于校准本表。

| 场景 | 估算 QPS | 并发（VUS） | 主瓶颈 |
|------|---------|-------------|--------|
| 读路径 `GET /:code`（Redis 命中 ≥90%） | 2,000~4,000（2 副本）；峰值 5,000~8,000（HPA 扩至 6 副本） | 30~80（峰值乐观 100+） | 应用 Pod CPU limit 200m，不是 Redis |
| 写路径 `POST /api/shorten` | 500~1,500 | 10~50 | MySQL 单主（每请求 2 笔写） |
| 混合流量（约 9:1 读写） | ~2,000~3,000 | 90 读 + 10 写 | 同上 |

**推导要点（简版）：**

- **Little's law**：并发 ≈ QPS × 平均 RT。2,000 QPS × 5ms ≈ 10 个在途；到瓶颈附近 RT 上涨，在途会堆到几十上百。
- **应用层**：单 Pod `limits.cpu=200m`，Go + Gin 处理一次 Redis 命中的 GET 约 100~200µs CPU → 单 Pod 1~2k QPS；2 副本 = 0.4 核，HPA 最大 6 副本 = 1.2 核。
- **写路径**：`POST /api/shorten` = INSERT → 自增 ID → Base62 → UPDATE（2 次写）+ Redis SET；2C4G MySQL 单主 autocommit 小表单条写 ~1~3k TPS → shorten QPS 取其一半。
- **可用资源**：3 节点全跑控制面 + 数据层 Pod，每节点留给应用约 1~1.5 核 / 1.5~2GB；若 node-01 实际 2C2G，整体打 8~9 折。

**前提假设**：短链表小且有索引、缓存命中率 ≥90%、无慢 SQL、请求体小；压测环境与生产一致（同一集群，2 副本起步）。

---

## 4. 涉及文件（规划）

```
scripts/loadtest/
  script-read.js      读路径 k6 脚本（GET /:code，缓存命中，301 判定）
  script-shorten.js   写路径 k6 脚本（POST /api/shorten，__VU/__ITER 唯一 body）
  script-mixed.js     混合 9:1 k6 脚本（scenarios 双场景：读 90 VUS + 写 10 VUS）
  run-read.sh         读路径梯度封装（--vus 10/50/100/200 循环）
  run-write.sh        写路径梯度封装（--vus 10/25/50 循环）
  results/            压测结果（--summary-export JSON + 记录表）
docs/phase-9-load-testing.md  本文档（方案 + 结果回填）
docs/project-resume-star-interview.md  Q25 口径更新
```

---

## 5. 实施步骤（6 步）

> 执行顺序：装 k6 → 预置数据 → 读路径基线 → 写路径 → 混合 + HPA → 记录回填。

```
Step 1: 安装 k6 ─────────► node-01 部署 k6 二进制，确认可连服务
    ▼
Step 2: 预置测试数据 ────► 灌入 10,000 条短链 + 预热缓存（命中率口径）
    ▼
Step 3: 读路径基线 ────► --vus 10→50→100→200 梯度，每档 60s，记录 QPS/P99/错误率
    ▼
Step 4: 写路径压测 ────► script-shorten.js + --vus 10→25→50，同步观测 MySQL 主库
    ▼
Step 5: 混合 + HPA ────► script-mixed.js（9:1 读写），观察 2→6 副本扩容与容量增量
    ▼
Step 6: 记录回填 ──────► 填第 6 节模板 → 回填 Q25 → 本文档状态改“已完成”
```

---

### Step 1: 安装 k6（node-01）

**目标**：node-01 具备 k6 压测能力，验证压测入口连通。

**操作**：

```bash
# 方案 A：GitHub Releases 二进制（node-01 有公网；慢可走代理/镜像）
# 版本号以 https://github.com/grafana/k6/releases 最新 release 为准（示例 v2.1.0）
K6_VER=v2.1.0
curl -L -o /tmp/k6.tar.gz https://github.com/grafana/k6/releases/download/${K6_VER}/k6-${K6_VER}-linux-amd64.tar.gz
tar xzf /tmp/k6.tar.gz -C /tmp
sudo cp /tmp/k6-${K6_VER}-linux-amd64/k6 /usr/local/bin/
k6 version

# 方案 B：Go 工具链直接安装（node-01 有 Go 时）
go install go.k6.io/k6@latest

# 无公网时：在能联网的机器下载后 scp 分发到 node-01（沿用 busybox 镜像分发先例）

# 连通性验证（走 Ingress 内网地址）
curl -s http://127.0.0.1:8080/health   # {"status":"ok",...}
```

**验证指标**：

| 检查项 | 预期结果 |
|--------|---------|
| k6 可执行 | `k6 version` 输出版本号 |
| 压测入口连通 | /health 返回 200 |

---

### Step 2: 预置测试数据

**目标**：准备读路径压测所需的短码，并控制缓存命中率口径（≥90%）。

**操作**：

```bash
# 1. 通过 API 灌入 10,000 条短链（写路径本身也是热身）
for i in $(seq 1 10000); do
  curl -s -X POST http://127.0.0.1:8080/api/shorten \
    -H 'Content-Type: application/json' \
    -d "{\"url\":\"https://example.com/$i\"}" > /dev/null
done

# 2. 预热缓存：抽 100 个高频短码各 GET 一次（热点集中模拟）
for i in $(seq 1 100); do
  curl -s -o /dev/null http://127.0.0.1:8080/shortcode-$i
done

# 3. 可选：另取 10 个未预热短码，单独做“缓存未命中”读压测
```

**验证指标**：

| 检查项 | 预期结果 |
|--------|---------|
| 数据量 | 10,000 条短链入库（url_mapping 行数） |
| 缓存命中率 | Redis `keyspace_hits/(hits+misses)` ≥ 90% |

---

### Step 3: 读路径基线（缓存命中）

**目标**：测 `GET /:code` 的 QPS / RT / P99 / 饱和点，验证“瓶颈在应用 CPU limit”的假设。

**操作**：

`scripts/loadtest/script-read.js`：

```js
// scripts/loadtest/script-read.js —— 读路径（缓存命中）
import http from 'k6/http';
import { check } from 'k6';

export const options = {
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)'],
};

export default function () {
  const res = http.get('http://127.0.0.1:8080/abc123');
  // 读路径正常响应是 301 跳转，不算错误
  check(res, { '3xx 跳转': (r) => r.status >= 300 && r.status < 400 });
}
```

```bash
# 并发梯度：--vus 10 → 50 → 100 → 200，每档 60s；CLI 参数覆盖脚本内默认
k6 run --vus 100 --duration 60s \
  --summary-export results/read-c100.json \
  script-read.js

# 输出关注 http_req_duration 的 avg / p(90) / p(95) / p(99)
```

**判定标准**：

| 信号 | 含义 |
|------|------|
| QPS 不再随 VUS 上升，RT 线性上涨 | 已达饱和，停止加并发（再加只堆 RT） |
| shortlink Pod CPU 顶满 200m | 应用层是瓶颈，符合估算 |
| 错误率 > 0.1%（不含 301） | 有问题，停下排查 |
| 301 是正常响应 | 读路径压的是跳转，301 不算错误 |

---

### Step 4: 写路径压测（MySQL 单主瓶颈验证）

**目标**：测 `POST /api/shorten` 的 QPS / P99，验证“MySQL 单主两笔写”是瓶颈。

**操作**：

`scripts/loadtest/script-shorten.js`：

```js
// scripts/loadtest/script-shorten.js —— 写路径
import http from 'k6/http';
import { check } from 'k6';

export const options = {
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)'],
};

// __VU + __ITER 组合保证每次迭代 URL 唯一，避免重复短链/主键冲突
export default function () {
  const payload = JSON.stringify({
    url: `https://example.com/load-${__VU}-${__ITER}`,
  });
  const res = http.post('http://127.0.0.1:8080/api/shorten', payload, {
    headers: { 'Content-Type': 'application/json' },
  });
  check(res, { 'status 200': (r) => r.status === 200 });
}
```

```bash
# 并发梯度：--vus 10 → 25 → 50，每档 60s
k6 run --vus 50 --duration 60s \
  --summary-export results/write-c50.json \
  script-shorten.js
```

压测同时观测 MySQL Master（node-02）：

```sql
SHOW GLOBAL STATUS LIKE 'Threads_connected';
SHOW GLOBAL STATUS LIKE 'Com_insert';    -- 两次采样差值 ÷ 秒数 = 写 TPS
SHOW GLOBAL STATUS LIKE 'Com_update';
```

**判定标准**：

| 信号 | 含义 |
|------|------|
| Threads_connected 逼近 max_connections | ProxySQL/MySQL 连接层饱和 |
| Com_insert + Com_update 不再随 VUS 上升 | MySQL 单主写瓶颈 |
| shortlink Pod CPU 未顶满 | 证明写瓶颈在数据层不在应用层 |

---

### Step 5: 混合负载 + HPA 验证

**目标**：模拟真实 9:1（读:写）流量（与 Q25 结论口径一致），验证 HPA 扩容后容量是否线性增长。

**操作**：

`scripts/loadtest/script-mixed.js`（k6 scenarios 双场景，读 90 VUS + 写 10 VUS）：

```js
// scripts/loadtest/script-mixed.js —— 混合 9:1（读 90 + 写 10）
import http from 'k6/http';
import { check } from 'k6';

export const options = {
  scenarios: {
    read:  { executor: 'constant-vus', vus: 90, duration: '120s', exec: 'read' },
    write: { executor: 'constant-vus', vus: 10, duration: '120s', exec: 'write' },
  },
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)'],
};

export function read() {
  const res = http.get('http://127.0.0.1:8080/abc123');
  check(res, { '3xx 跳转': (r) => r.status >= 300 && r.status < 400 });
}

export function write() {
  const payload = JSON.stringify({
    url: `https://example.com/mixed-${__VU}-${__ITER}`,
  });
  const res = http.post('http://127.0.0.1:8080/api/shorten', payload, {
    headers: { 'Content-Type': 'application/json' },
  });
  check(res, { 'status 200': (r) => r.status === 200 });
}
```

```bash
k6 run --summary-export results/mixed-90-10.json script-mixed.js

# 同时观察 HPA
kubectl get hpa -n app-layer -w
```

**判定标准**：

| 信号 | 含义 |
|------|------|
| CPU > 70% 后 HPA 2→3→…→6 扩容 | HPA 生效 |
| 扩容后读 QPS 近似线性增长 | 容量模型正确，直至 MySQL/ProxySQL 瓶颈 |
| 扩容后 QPS 不涨 | 瓶颈已转移到数据层，记录该值为当前上限 |

> **口径说明**：9:1 与 Q25 结论口径一致（短链读多写少、缓存命中 ≥90% 的典型形态）。若想额外压写路径强度，可把 write 场景 VUS 调到 20/30 复跑对比。

---

### Step 6: 结果记录与回填

**目标**：把实测数据沉淀为简历口径，形成可复现的容量基线。

**操作**：

1. 按第 6 节模板记录所有档位数据（`--summary-export` 的 JSON + 观测点采样）。
2. 回填 [project-resume-star-interview.md](project-resume-star-interview.md) Q25 表格，标注“实测”与测试条件。
3. 本文档状态改为“✅ 已完成”，日期改为实测日期。

---

## 6. 结果记录模板

| 场景 | 并发(VUS) | QPS | Avg RT | P99 | 错误率 | 副本数 | 瓶颈组件 | 备注 |
|------|-----------|-----|--------|-----|--------|--------|---------|------|
| 读·缓存命中 | 10 | | | | | 2 | | |
| 读·缓存命中 | 50 | | | | | 2 | | |
| 读·缓存命中 | 100 | | | | | 2 | | |
| 读·缓存命中 | 200 | | | | | 2~6 | | |
| 写 | 10 | | | | | 2 | | |
| 写 | 25 | | | | | 2 | | |
| 写 | 50 | | | | | 2 | | |
| 混合 9:1 | 90+10 | | | | | 2~6 | | |

> 记录要素：k6 版本、`--vus/--duration` 参数、脚本版本、预置数据量、Redis 命中率、是否触发 HPA 扩容、压测时间（避开备份窗口）。P99 取 summary 中 `http_req_duration` 的 p(99)。

---

## 7. 注意事项（压测纪律）

1. **内网打，别走公网**：EIP 带宽（通常 1~5Mbps）远小于集群能力，从公网压测得到的是“带宽上限”不是“集群上限”。从 node-01 打 Ingress/Service 内网地址。
2. **避开备份窗口**：MySQL 全量备份 02:00、Velero 02:30，压测 IO 竞争会让数据失真，也影响备份成功率。
3. **别把控制面打挂**：Traefik 是 hostNetwork 跑在 node-01，Traefik CPU 被打满会影响 API Server；VUS 从低到高梯度加，每档看一眼节点 CPU。
4. **k6 自身开销**：k6 是单进程 JS 运行时，2C4G 的 node-01 上一般能打出几千 RPS，对本集群量级（估算 2~8k）够用；若打不满目标或 k6 CPU 先满，拆多个 k6 实例用 `--execution-segment` 分摊，或放到独立压测机。
5. **P99 是精确百分位**：k6 summary 基于完整样本输出 p(90)/p(95)/p(99)，不需要近似；样本量越大百分位越稳，单档建议迭代数 ≥ 5,000（60s + 足够 VUS 通常满足）。要留原始数据加 `--out json=results/xxx.raw.json`。
6. **数据可复现**：记录 k6 版本、VUS/duration、脚本版本、预置数据量；两次压测之间清 Redis 缓存重来，避免命中率口径漂移。
7. **301 不算错误**：读路径正常响应是 301 跳转，错误率只看 4xx/5xx/超时。
8. **压测即变更**：压测前后 `kubectl get pods -A` 留基线快照，异常时能快速确认是否影响业务。

---

## 8. 结果回填与后续优化

**判定逻辑：**

- 实测与估算同量级（±3 倍内）→ 回填 Q25，数字从“估算”升级为“实测”，面试可信度大增。
- 实测远低于估算 → 按瓶颈顺序排查：shortlink CPU limit → ProxySQL 连接池 / MySQL 慢查询 → Redis（见第 3 节观测点）。
- 实测远高于估算 → 检查是否压测入口绕过了真实链路（如直连 Service 而非 Ingress），口径要对齐。

**后续优化路径（按序，每步都要重新压测验证）：**

1. 放开 shortlink CPU limit（200m → 500m~1C），Gin 是 CPU 密集，这是性价比最高的第一步；
2. 写路径合并为单条 INSERT（先算好 Base62 再插入，省一次 UPDATE），直接提升写 QPS 近一倍；
3. MySQL 开并行复制（`replica_parallel_workers`）+ ProxySQL 调连接池上限；
4. 再往上不是这台集群的活了：拆 Redis Cluster / 上 RDS / 水平扩容。

---

## 9. 拓展阅读

- [k6 官方文档（脚本 / scenarios / summary）](https://grafana.com/docs/k6/latest/)
- [grafana/k6 GitHub Releases（下载二进制）](https://github.com/grafana/k6/releases)
- [k6 脚本示例（HTTP 请求 / check / 场景）](https://grafana.com/docs/k6/latest/examples/)
- [MySQL Performance / Benchmarking 官方文档](https://dev.mysql.com/doc/refman/8.0/en/optimize-benchmarking.html)
