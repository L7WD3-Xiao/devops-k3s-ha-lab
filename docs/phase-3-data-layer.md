# Phase 3: 数据层部署 — MySQL 主从 + Redis Sentinel HA

> 日期：2026-07-21
> 状态：MySQL 主从已完成 / Redis Sentinel HA 已完成 / Orchestrator+ProxySQL 待实施
> 前置文档：[phase-2-k3s-deploy.md](phase-2-k3s-deploy.md)（K3s 集群部署）

---

## 1. 概述

### 1.1 目标

在 Phase 2 部署的 K3s 集群及其底层 ECS 上，部署短链服务的**数据层**：
- **MySQL 8.0 物理机主从复制**（node-02 Master + node-03 Slave，GTID 模式）
- **Redis Sentinel HA**（3 Redis + 3 Sentinel，K8s StatefulSet，自动故障切换）

### 1.2 架构

```
                         ┌─────────────────────────────────────────────┐
                         │              数据层架构                       │
                         │                                             │
    MySQL 物理机          │  node-02 (Master)  ──GTID复制──►  node-03   │
    (非容器化)            │  192.168.1.230                    .229     │
                         │  MySQL 8.0.46                     MySQL    │
                         │                                             │
    Redis Sentinel       │  ┌── K8s StatefulSet (data-layer) ────┐    │
    (K8s 容器化)          │  │ redis-0 (node-03)  Master/Slave    │    │
                         │  │ redis-1 (node-02)  Master/Slave    │    │
                         │  │ redis-2 (node-01)  Slave           │    │
                         │  │ sentinel-0/1/2     3 节点分布       │    │
                         │  └────────────────────────────────────┘    │
                         └─────────────────────────────────────────────┘
```

### 1.3 技术选型

| 组件 | 选型 | 理由 |
|------|------|------|
| MySQL | 物理机主从 + GTID | 简历项目展示传统 DBA 运维能力 |
| MySQL HA | Orchestrator + ProxySQL（待实施） | 故障切换 + 读写分离 |
| Redis | Sentinel 模式 StatefulSet | 比 Cluster 模式简单，适合 3 节点 |
| Redis 持久化 | RDB + AOF | 双保险 |
| StorageClass | local-path (K3s 内置) | 本地存储，无需额外 CSI |

---

## 2. MySQL 8.0 物理机主从

### 2.1 部署架构

| 角色 | 节点 | IP | 版本 | 配置 |
|------|------|-----|------|------|
| Master | node-02 | 192.168.1.230 | MySQL 8.0.46 | buffer_pool=256M |
| Slave | node-03 | 192.168.1.229 | MySQL 8.0.46 | buffer_pool=256M |

### 2.2 Ansible 自动化

| 文件 | 说明 |
|------|------|
| `ansible/inventory.ini` | 新增 `[mysql_master]` / `[mysql_slave]` 分组 |
| `ansible/group_vars/all.yml` | MySQL 变量（root密码、复制用户、app库等） |
| `ansible/playbooks/templates/my.cnf.j2` | MySQL 配置模板（GTID、binlog Row、utf8mb4） |
| `ansible/playbooks/templates/init-db.sql.j2` | 数据库初始化 SQL |
| `ansible/playbooks/02-deploy-mysql.yml` | 3 Play：安装 RPM → 配置 Master → 配置 Slave |

### 2.3 关键配置

**my.cnf 核心参数（Master/Slave 共享，server-id 变量化）：**
```ini
gtid_mode=ON
enforce_gtid_consistency=ON
binlog_format=ROW
binlog_row_image=FULL
innodb_buffer_pool_size=256M
slow_query_log=ON
```

**复制用户权限：**
```sql
CREATE USER 'repl'@'192.168.1.%' IDENTIFIED WITH caching_sha2_password BY '...';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'192.168.1.%';
```

### 2.4 踩坑记录

| # | 问题 | 原因 | 修复 |
|---|------|------|------|
| 1 | RPM glob 不展开 | Ansible `command` 模块不支持 shell glob | 改用 `shell` 模块 |
| 2 | `warn` 参数报错 | 新版 Ansible 移除了 `shell` 模块的 `warn` 参数 | 去掉 `args: warn: false` |
| 3 | Slave IO 线程连接失败 (2061) | MySQL 8.0 `caching_sha2_password` 要求安全连接 | `CHANGE REPLICATION SOURCE TO GET_SOURCE_PUBLIC_KEY=1` |
| 4 | RPM 下载 404 | dev.mysql.com 已下线 | 改用 `repo.mysql.com` |

### 2.5 验证结果

- Master 插入 `test01` 记录 → Slave 2 秒内同步成功
- `SHOW REPLICA STATUS`：IO/SQL 线程均 Running，GTID 已同步

---

## 3. Redis Sentinel HA

### 3.1 部署架构

| 组件 | 副本数 | 分布 | 持久化 |
|------|--------|------|--------|
| Redis StatefulSet | 3 (1M+2S) | 每节点 1 个（podAntiAffinity） | PVC 512Mi (local-path) |
| Sentinel StatefulSet | 3 | 每节点 1 个（podAntiAffinity） | emptyDir (配置可写) |

**Sentinel 参数：**
- quorum: 2（3 Sentinel 中 2 个同意即可触发切换）
- down-after-milliseconds: 5000（5 秒无响应判定下线）
- failover-timeout: 30000（30 秒切换超时）
- parallel-syncs: 1（每次只同步 1 个 slave）

### 3.2 K8s 资源清单

| 文件 | 说明 |
|------|------|
| `k8s/data-layer/namespace.yaml` | data-layer namespace |
| `k8s/data-layer/redis-configmap.yaml` | redis.conf + sentinel.conf + start-redis.sh |
| `k8s/data-layer/redis-statefulset.yaml` | Redis StatefulSet + Headless/ClusterIP Service |
| `k8s/data-layer/sentinel-statefulset.yaml` | Sentinel StatefulSet + Headless/ClusterIP Service |

### 3.3 踩坑记录

#### 问题 1：busybox 镜像缺失 → PVC Pending

**现象：** Redis Pod 持续 Pending，PVC `redis-data-redis-0` 状态 ExternalProvisioning。

**根因：** local-path-provisioner 创建 helper pod 时需要 `rancher/mirrored-library-busybox:1.37.0` 镜像。K3s airgap 安装未包含此镜像，node-02/03 无公网 IP 无法拉取。

**修复：** 离线镜像分发（与 Redis 镜像同方法）：
```bash
# node-01 拉取（通过 SSH 代理隧道）
sudo /usr/local/bin/k3s ctr image pull docker.io/rancher/mirrored-library-busybox:1.37.0
# 导出
sudo /usr/local/bin/k3s ctr image export /tmp/busybox.tar docker.io/rancher/mirrored-library-busybox:1.37.0
# 分发到 node-02/03
scp /tmp/busybox.tar 192.168.1.230:/tmp/
scp /tmp/busybox.tar 192.168.1.229:/tmp/
# 导入
sudo /usr/local/bin/k3s ctr image import /tmp/busybox.tar
```

#### 问题 2：Sentinel DNS 解析失败

**现象：** Sentinel Pod 启动时报 `Failed to resolve hostname 'redis-0.redis-headless.data-layer.svc.cluster.local'`，FATAL CONFIG FILE ERROR。

**根因：** Redis Sentinel 在解析配置文件时调用 `getaddrinfo()` 解析 hostname。Alpine Linux 使用 musl libc，其 `getaddrinfo()` 实现与 glibc 存在差异，在 Sentinel config parse 阶段解析 K8s 内部 DNS 失败。`nslookup`（BusyBox 自带）可以正常解析，但 Sentinel 的 C 库调用不行。

**修复：** init container 中用 `nslookup` 解析 redis-0 的 IP，用 `sed` 替换 sentinel.conf 中的 hostname 为 IP：
```yaml
initContainers:
  - name: init-sentinel
    command:
      - /bin/sh
      - -c
      - |
        # 用 nslookup 解析（绕过 musl getaddrinfo 问题）
        MASTER_IP=$(nslookup redis-0.redis-headless.data-layer.svc.cluster.local \
          | awk '/^Address: / && !/10.43.0.10/ {print $2}' | head -1)
        # 替换 hostname 为 IP
        sed "s/redis-0.redis-headless.data-layer.svc.cluster.local/$MASTER_IP/g" \
          /etc/redis-config/sentinel.conf > /sentinel-data/sentinel.conf
```

#### 问题 3：部署顺序依赖

**现象：** Redis 和 Sentinel 同时部署时，Sentinel 启动时 redis-0 还未运行，DNS 无 A 记录。

**修复：** 分步部署：
1. 先部署 Redis StatefulSet → 等待 redis-0 Running
2. 再部署 Sentinel StatefulSet

### 3.4 验证结果

#### Redis 主从复制
```
redis-0 (Master): SET phase3-test "sentinel-ha-ok" → OK
redis-1 (Slave):  GET phase3-test → "sentinel-ha-ok"  ✓
redis-2 (Slave):  GET phase3-test → "sentinel-ha-ok"  ✓
```

#### Sentinel 集群状态
```
SENTINEL master mymaster:
  ip: 10.42.2.7, port: 6379
  num-slaves: 2, num-other-sentinels: 2
  quorum: 2, status: master
```

#### 故障切换测试
```
触发: SENTINEL failover mymaster

切换前:
  redis-0 (10.42.2.7)  → master
  redis-1 (10.42.1.10) → slave
  redis-2 (10.42.0.37) → slave

切换后 (<10 秒):
  redis-0 (10.42.2.7)  → slave (master_host: 10.42.1.10)
  redis-1 (10.42.1.10) → master (新选举)
  redis-2 (10.42.0.37) → slave (master_host: 10.42.1.10)

数据完整性: phase3-test key 在新 master 和 slave 上均可读  ✓
```

### 3.5 Pod 分布

| Pod | 节点 | Pod IP | 角色 |
|-----|------|--------|------|
| redis-0 | node-03 | 10.42.2.7 | Redis（初始 master） |
| redis-1 | node-02 | 10.42.1.10 | Redis（failover 后 master） |
| redis-2 | node-01 | 10.42.0.37 | Redis slave |
| sentinel-0 | node-02 | 10.42.1.12 | Sentinel |
| sentinel-1 | node-03 | 10.42.2.10 | Sentinel |
| sentinel-2 | node-01 | 10.42.0.38 | Sentinel |

---

## 4. 待实施

| 组件 | 说明 | 优先级 |
|------|------|--------|
| Orchestrator | MySQL 故障切换 + 拓扑管理 | 中 |
| ProxySQL | MySQL 读写分离 + 连接池 | 中 |
| 阿里云 ACR | 镜像仓库（替代 Harbor） | 高（Phase 4 前置） |
| FluxCD | GitOps CD（替代 ArgoCD） | 高（Phase 5） |
