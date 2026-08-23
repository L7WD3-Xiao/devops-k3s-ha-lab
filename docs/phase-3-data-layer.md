# Phase 3: 数据层部署 — MySQL 主从 + Redis Sentinel HA

> 日期：2026-07-21
> 状态：✅ 全部完成（MySQL 主从 + Redis Sentinel HA + Orchestrator + ProxySQL）
> 前置文档：[phase-2-k3s-deploy.md](phase-2-k3s-deploy.md)（K3s 集群部署）

---

## 1. 概述

### 1.1 目标

在 Phase 2 部署的 K3s 集群及其底层 ECS 上，部署短链服务的**数据层**：
- **MySQL 8.0 物理机主从复制**（node-02 Master + node-03 Slave，GTID 模式）
- **Redis Sentinel HA**（3 Redis + 3 Sentinel，K8s StatefulSet，自动故障切换）
- **Orchestrator + ProxySQL**（MySQL 拓扑管理 + 自动故障切换 + 读写分离代理）

### 1.2 架构

```
                         ┌──────────────────────────────────────────────────────┐
                         │                   数据层架构                           │
                         │                                                      │
    MySQL 物理机          │  node-02 (Master)  ──GTID复制──►  node-03 (Slave)     │
    (非容器化)            │  192.168.1.230     read_only=ON   .229               │
                         │  MySQL 8.0.46                     MySQL 8.0.46       │
                         │      ↑                               ↑               │
                         │      │      ProxySQL (K8s)           │               │
    Orchestrator+        │      │   ┌───────────────────┐       │               │
    ProxySQL             │      └───┤ HG1 (writer) → .230├───────┘              │
    (K8s 容器化)          │          │ HG2 (reader) → .229│                      │
                         │          │ :6033 (MySQL)     │                       │
                         │          └───────────────────┘                       │
                         │  Orchestrator (K8s) → 监控拓扑 + 自动故障切换           │
                         │                                                      │
    Redis Sentinel       │  ┌── K8s StatefulSet (data-layer) ────┐              │
    (K8s 容器化)          │  │ redis-0 (node-03)  Master/Slave    │              │
                         │  │ redis-1 (node-02)  Master/Slave    │              │
                         │  │ redis-2 (node-01)  Slave           │              │
                         │  │ sentinel-0/1/2     3 节点分布       │              │
                         │  └────────────────────────────────────┘              │
                         └──────────────────────────────────────────────────────┘
```

### 1.3 技术选型

| 组件 | 选型 | 理由 |
|------|------|------|
| MySQL | 物理机主从 + GTID | 简历项目展示传统 DBA 运维能力 |
| MySQL HA | Orchestrator + ProxySQL | 故障切换 + 读写分离 |
| Redis | Sentinel 模式 StatefulSet | 比 Cluster 模式简单，适合 3 节点 |
| Redis 持久化 | RDB + AOF | 双保险 |
| StorageClass | local-path (K3s 内置) | 本地存储，无需额外 CSI |

---

## 2. MySQL 8.0 物理机主从

### 部署架构

| 角色 | 节点 | IP | 版本 | 配置 |
|------|------|-----|------|------|
| Master | node-02 | 192.168.1.230 | MySQL 8.0.46 | buffer_pool=256M |
| Slave | node-03 | 192.168.1.229 | MySQL 8.0.46 | buffer_pool=256M |

> 执行顺序：先配 Inventory 和变量，再分别部署 Master/Slave，然后建立复制，最后验证。

```
Step 1: Inventory+变量 ──► ansible 分组(mysql_master/slave) + all.yml 变量
    │
    ▼
Step 2: Master 部署 ────► RPM install → my.cnf → init-db → 启动
    │
    ▼
Step 3: Slave 部署 ─────► RPM install → my.cnf → 启动
    │
    ▼
Step 4: 主从复制 ──────► CHANGE REPLICATION → IO/SQL Running
    │
    ▼
Step 5: 验证 ──────────► 数据插入 → Slave 同步 → GTID 一致
```

---

### 实施步骤（5 步）

#### Step 1: 配置 Ansible Inventory 与变量

**目标**：在 Ansible 中新增 MySQL 主机分组，配置 MySQL 变量（密码、复制用户、应用数据库）。

**涉及文件**：

| 文件 | 操作 | 说明 |
|------|------|------|
| `ansible/inventory.ini` | 编辑 | 新增 `[mysql_master]` / `[mysql_slave]` 分组 |
| `ansible/group_vars/all.yml` | 编辑 | MySQL root 密码、复制用户密码、shortlink 数据库密码 |
| `ansible/playbooks/02-deploy-mysql.yml` | 新建 | 3 个 Play：安装 RPM → 配置 Master → 配置 Slave |

**Inventory 分组示例**：

```ini
[mysql_master]
node-02 ansible_host=192.168.1.230

[mysql_slave]
node-03 ansible_host=192.168.1.229

[mysql:children]
mysql_master
mysql_slave
```

**all.yml 变量**（已脱敏，真实值填入 `.gitignore` 保护的 `all.yml`）：

```yaml
mysql_root_password: "<root-password>"
mysql_repl_password: "<repl-password>"
mysql_app_password: "<app-password>"
mysql_app_database: "shortlink"
```

**验证**：

```bash
# 确认 Ansible 能连通所有 MySQL 节点
ansible mysql -i inventory.ini -m ping -o
```

---

#### Step 2: 部署 MySQL Master（node-02）

**目标**：在 node-02 上安装 MySQL 8.0，配置 GTID 主从参数，初始化应用数据库。

**涉及文件**：

| 文件 | 操作 | 说明 |
|------|------|------|
| `ansible/playbooks/templates/my.cnf.j2` | 新建 | MySQL 配置模板（GTID、binlog、utf8mb4） |
| `ansible/playbooks/templates/init-db.sql.j2` | 新建 | 数据库初始化 SQL（shortlink 库 + 用户） |

**my.cnf 核心参数**（Master/Slave 共享，`server-id` 变量化通过 Ansible 渲染）：

```ini
[mysqld]
server-id={{ mysql_server_id }}
gtid_mode=ON
enforce_gtid_consistency=ON
binlog_format=ROW
binlog_row_image=FULL
innodb_buffer_pool_size=256M
slow_query_log=ON
log_error=/var/log/mysql/error.log
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci

{% if mysql_role == 'master' %}
# Master 专属配置
skip_slave_start=ON
{% endif %}

{% if mysql_role == 'slave' %}
# Slave 专属配置
read_only=ON
super_read_only=ON
skip_slave_start=ON
relay_log=relay-bin
{% endif %}
```

**Playbook 执行流程（Master）**：

1. **安装 MySQL 8.0 RPM**（从 `repo.mysql.com` 下载）
2. **分发 my.cnf**（`server-id=1`，`mysql_role='master'`）
3. **启动 MySQL 服务**（`systemctl start mysqld`）
4. **获取临时 root 密码**（从 `/var/log/mysql/error.log` 提取）
5. **设置 root 密码**（`ALTER USER root@localhost IDENTIFIED BY '...'`）
6. **初始化数据库**（执行 `init-db.sql.j2` 渲染的 SQL）

**数据库初始化 SQL**：

```sql
CREATE DATABASE IF NOT EXISTS shortlink CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'shortlink'@'192.168.1.%' IDENTIFIED BY '...';
GRANT ALL PRIVILEGES ON shortlink.* TO 'shortlink'@'192.168.1.%';
FLUSH PRIVILEGES;
```

> ⚠️ **踩坑**：`dev.mysql.com` 已下线，RPM 下载 404。改用 `repo.mysql.com` 作为 YUM 源：
> ```bash
> rpm -Uvh https://repo.mysql.com/mysql80-community-release-el8-1.noarch.rpm
> ```

**验证**：

```bash
# 从 node-01 检查 Master 连接
ssh k3s-node-01 "mysql -h 192.168.1.230 -u root -p -e 'SHOW VARIABLES LIKE \"server_id\"; SHOW VARIABLES LIKE \"gtid_mode\";'"

# 预期输出
# server_id: 1
# gtid_mode: ON
```

---

#### Step 3: 部署 MySQL Slave（node-03）

**目标**：在 node-03 上安装 MySQL 8.0，配置 Slave 专属参数（read_only + relay_log）。

**操作**：在同个 Playbook（`02-deploy-mysql.yml`）的第二个 Play 中完成。

**与 Master 的差异**：

| 配置项 | Master | Slave |
|--------|--------|-------|
| server-id | 1 | 2 |
| read_only | OFF（默认） | ON |
| super_read_only | OFF（默认） | ON |
| relay_log | 无 | relay-bin |

**涉及文件**：

同上 Step 2，Ansible 通过 `mysql_role` 变量区分 Master/Slave 配置。

**踩坑：Ansible `command` 模块不支持 shell glob**

```yaml
# ❌ 错误
- name: Remove MySQL packages
  command: rpm -e $(rpm -qa | grep mysql)

# ✅ 正确
- name: Remove MySQL packages
  shell: rpm -e $(rpm -qa | grep mysql)
```

**验证**：

```bash
# 检查 Slave 启动状态
ssh k3s-node-01 "mysql -h 192.168.1.229 -u root -p -e 'SHOW VARIABLES LIKE \"server_id\"; SELECT @@read_only;'"

# 预期输出
# server_id: 2
# @@read_only: 1
```

---

#### Step 4: 建立主从复制（GTID 模式）

**目标**：在 Slave 上配置 CHANGE REPLICATION，使 Slave 从 Master 同步数据。

**前置条件**：Master 上已创建复制用户。

**复制用户**（在 Master 上执行）：

```sql
CREATE USER 'repl'@'192.168.1.%' IDENTIFIED WITH caching_sha2_password BY '<repl-password>';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'192.168.1.%';
```

**在 Slave 上执行 CHANGE REPLICATION**：

```sql
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='192.168.1.230',
  SOURCE_PORT=3306,
  SOURCE_USER='repl',
  SOURCE_PASSWORD='<repl-password>',
  SOURCE_AUTO_POSITION=1,
  GET_SOURCE_PUBLIC_KEY=1;   -- MySQL 8.0 caching_sha2_password 需要

START REPLICA;
```

> ⚠️ **踩坑——Slave IO 线程 2061 错误**：
> MySQL 8.0 默认使用 `caching_sha2_password` 认证插件，该插件要求 SSL/TLS 安全连接，否则返回错误 2061（`Authentication plugin 'caching_sha2_password' cannot be loaded`）。
>
> **修复**：在 `CHANGE REPLICATION` 中添加 `GET_SOURCE_PUBLIC_KEY=1`，或改用 `mysql_native_password` 插件创建复制用户：
> ```sql
> CREATE USER 'repl'@'192.168.1.%' IDENTIFIED WITH mysql_native_password BY '...';
> ```

**验证**：

```bash
# 检查复制状态
ssh k3s-node-01 "mysql -h 192.168.1.229 -u root -p -e 'SHOW REPLICA STATUS\G'" | grep -E "IO_Running|SQL_Running|Seconds_Behind|Retrieved_Gtid|Auto_Position"

# 预期输出
# Slave_IO_Running: Yes
# Slave_SQL_Running: Yes
# Seconds_Behind_Master: 0
```

---

#### Step 5: 验证主从同步

**目标**：确认主从复制正常工作——Master 写入数据，Slave 实时同步。

**验证步骤**：

```bash
# 1. Master 插入测试数据
ssh k3s-node-01 "mysql -h 192.168.1.230 -u root -p -e '
  CREATE DATABASE IF NOT EXISTS test_repl;
  CREATE TABLE test_repl.sync_test (id INT PRIMARY KEY, msg VARCHAR(50));
  INSERT INTO test_repl.sync_test VALUES (1, \"hello from master\");
'"

# 2. Slave 查询同步数据（等待 2 秒）
ssh k3s-node-01 "mysql -h 192.168.1.229 -u root -p -e 'SELECT * FROM test_repl.sync_test'"

# 预期：返回 1行——"hello from master"

# 3. 清理测试库
ssh k3s-node-01 "mysql -h 192.168.1.230 -u root -p -e 'DROP DATABASE test_repl'"

# 4. 监控 GTID 同步进度
ssh k3s-node-01 "mysql -h 192.168.1.229 -u root -p -e 'SHOW REPLICA STATUS\G'" | grep -i gtid
```

**验证指标**：

| 检查项 | 预期结果 | 验证方式 |
|--------|---------|---------|
| Slave_IO_Running | Yes | `SHOW REPLICA STATUS` |
| Slave_SQL_Running | Yes | `SHOW REPLICA STATUS` |
| Seconds_Behind_Master | 0 | `SHOW REPLICA STATUS` |
| GTID 一致性 | Retrieved_Gtid_Set = Executed_Gtid_Set | `SHOW REPLICA STATUS` |
| Master 写入 → Slave 同步 | < 2 秒 | 数据测试 |

---

## 3. Redis Sentinel HA

### 部署架构

| 组件 | 副本数 | 分布 | 持久化 |
|------|--------|------|--------|
| Redis StatefulSet | 3 (1M+2S) | 每节点 1 个（podAntiAffinity） | PVC 512Mi (local-path) |
| Sentinel StatefulSet | 3 | 每节点 1 个（podAntiAffinity） | emptyDir (配置可写) |

**Sentinel 参数：**
- quorum: 2（3 Sentinel 中 2 个同意即可触发切换）
- down-after-milliseconds: 5000（5 秒无响应判定下线）
- failover-timeout: 30000（30 秒切换超时）
- parallel-syncs: 1（每次只同步 1 个 slave）

> 执行顺序：先配 ConfigMap，再部署 Redis（等待 redis-0 Ready），然后部署 Sentinel，最后验证。

```
Step 1: Namespace+ConfigMap ──► data-layer ns + redis.conf + sentinel.conf + start-redis.sh
    │
    ▼
Step 2: Redis StatefulSet ──► 3 副本 StatefulSet → 等待 redis-0 Ready
    │                         podAntiAffinity 每节点 1 个
    │                         ⚠️ 踩坑: busybox 镜像缺失
    ▼
Step 3: Sentinel StatefulSet ──► 3 副本 + init container DNS 解析修复
    │                            ⚠️ musl getaddrinfo 问题
    ▼
Step 4: 验证 ────────────────► 主从复制 → Sentinel 状态 → 故障切换测试
```

---

### 实施步骤（4 步）

#### Step 1: 创建 Namespace 与配置

**目标**：创建 `data-layer` namespace，准备 Redis 和 Sentinel 的配置文件。

**涉及文件**：

| 文件 | 操作 | 说明 |
|------|------|------|
| `k8s/data-layer/namespace.yaml` | 新建 | data-layer namespace |
| `k8s/data-layer/redis-configmap.yaml` | 新建 | redis.conf + sentinel.conf + start-redis.sh |

**部署 namespace**：

```bash
ssh k3s-node-01 "sudo /usr/local/bin/k3s kubectl apply -f -" < k8s/data-layer/namespace.yaml
```

**ConfigMap 内容**：

`redis.conf`：
```
bind 0.0.0.0
port 6379
appendonly yes
appendfsync everysec
save 900 1
save 300 10
save 60 10000
```

`sentinel.conf`：
```
bind 0.0.0.0
port 26379
sentinel monitor mymaster redis-0.redis-headless.data-layer.svc.cluster.local 6379 2
sentinel down-after-milliseconds 5000
sentinel failover-timeout 30000
sentinel parallel-syncs 1
```

`start-redis.sh`：判断 Pod 索引，redis-0 以 master 启动，其余以 slave 启动（通过 `SLAVEOF` 指向 redis-0）。

**验证**：

```bash
ssh k3s-node-01 "sudo /usr/local/bin/k3s kubectl get namespace data-layer && sudo /usr/local/bin/k3s kubectl get configmap -n data-layer redis-config"
```

---

#### Step 2: 部署 Redis StatefulSet

**目标**：部署 3 副本 Redis StatefulSet，每节点分布 1 个 Pod。

**涉及文件**：

| 文件 | 操作 | 说明 |
|------|------|------|
| `k8s/data-layer/redis-statefulset.yaml` | 新建 | StatefulSet + Headless Service (`redis-headless`) + ClusterIP Service (`redis`) |

**关键设计**：

- **3 副本** redis-0/redis-1/redis-2，通过 `podAntiAffinity` 确保每节点 1 个
- **Headless Service** `redis-headless`：StatefulSet DNS 记录（`redis-0.redis-headless.data-layer.svc.cluster.local`）
- **ClusterIP Service** `redis`：应用统一入口
- **PVC** 512Mi，storageClass `local-path`（K3s 内置）
- **start-redis.sh** 入口脚本根据 hostname 后缀 `-0` 判断 master/slave

**部署命令**：

```bash
ssh k3s-node-01 "sudo /usr/local/bin/k3s kubectl apply -f -" < k8s/data-layer/redis-statefulset.yaml

# 等待 redis-0 Running（Sentinel 依赖 redis-0 的 DNS 记录）
ssh k3s-node-01 "sudo /usr/local/bin/k3s kubectl rollout status sts/redis -n data-layer --timeout=120s"
```

> ⚠️ **踩坑——busybox 镜像缺失导致 PVC Pending**
>
> **现象**：Redis Pod 持续 Pending，PVC `redis-data-redis-0` 状态 `ExternalProvisioning`。
>
> **根因**：`local-path-provisioner` 创建 helper pod 时需要 `rancher/mirrored-library-busybox:1.37.0` 镜像。K3s airgap 安装未包含此镜像，node-02/03 无公网 IP 无法拉取。
>
> **修复**——离线分发 busybox 镜像：
> ```bash
> # node-01 拉取（通过 SSH 代理隧道）
> sudo /usr/local/bin/k3s ctr image pull docker.io/rancher/mirrored-library-busybox:1.37.0
> # 导出
> sudo /usr/local/bin/k3s ctr image export /tmp/busybox.tar docker.io/rancher/mirrored-library-busybox:1.37.0
> # 分发到 node-02/03
> scp /tmp/busybox.tar 192.168.1.230:/tmp/
> scp /tmp/busybox.tar 192.168.1.229:/tmp/
> # 导入
> ssh 192.168.1.230 "sudo /usr/local/bin/k3s ctr image import /tmp/busybox.tar"
> ssh 192.168.1.229 "sudo /usr/local/bin/k3s ctr image import /tmp/busybox.tar"
> ```

**验证**：

```bash
# 确认 3 个 Redis Pod Running 且分布在不同节点
ssh k3s-node-01 "sudo /usr/local/bin/k3s kubectl get pods -n data-layer -o wide | grep redis"

# 确认 PVC 已绑定
ssh k3s-node-01 "sudo /usr/local/bin/k3s kubectl get pvc -n data-layer"

# 确认 redis-0 为 Master
ssh k3s-node-01 "sudo /usr/local/bin/k3s kubectl exec -n data-layer redis-0 -- redis-cli ROLE"
# → 输出第一行应为 "master"
```

---

#### Step 3: 部署 Sentinel StatefulSet

**目标**：部署 3 副本 Sentinel StatefulSet，自动监控 Redis 主从并处理故障切换。

**涉及文件**：

| 文件 | 操作 | 说明 |
|------|------|------|
| `k8s/data-layer/sentinel-statefulset.yaml` | 新建 | StatefulSet + Headless/ClusterIP Service |

> ⚠️ **部署顺序**：必须在 Redis StatefulSet 部署完成且 redis-0 Ready 之后部署。Sentinel 启动时需要解析 `redis-0.redis-headless.data-layer.svc.cluster.local` 的 DNS A 记录，如果 redis-0 未就绪则该 DNS 不存在，Sentinel 启动失败。

**关键设计**：

```yaml
# sentinel-statefulset.yaml 核心片段——init container DNS 修复
initContainers:
  - name: init-sentinel
    image: redis:7-alpine
    command:
      - /bin/sh
      - -c
      - |
        # 用 nslookup 解析，绕过 musl getaddrinfo 问题
        MASTER_IP=$(nslookup redis-0.redis-headless.data-layer.svc.cluster.local \
          | awk '/^Address: / && !/10.43.0.10/ {print $2}' | head -1)
        # 替换 hostname 为 IP
        sed "s/redis-0.redis-headless.data-layer.svc.cluster.local/$MASTER_IP/g" \
          /etc/redis-config/sentinel.conf > /sentinel-data/sentinel.conf
```

> ⚠️ **踩坑——Sentinel DNS 解析失败（musl getaddrinfo）**
>
> **现象**：Sentinel Pod 启动时报 `FATAL CONFIG FILE ERROR`，无法解析 `redis-0.redis-headless...`。
>
> **根因**：Alpine Linux 使用 musl libc，其 `getaddrinfo()` 在 Sentinel config parse 阶段解析 K8s 内部 DNS 失败。而 `nslookup`（BusyBox 自带）可以正常解析——这说明 DNS 本身没问题，是 Sentinel 的 C 库调用层面出问题。
>
> **修复**：init container 用 `nslookup` 解析 redis-0 的 IP，`sed` 替换配置文件中的 hostname 为 IP 地址。

**部署命令**：

```bash
ssh k3s-node-01 "sudo /usr/local/bin/k3s kubectl apply -f -" < k8s/data-layer/sentinel-statefulset.yaml

# 等待全部 Sentinel 就绪
ssh k3s-node-01 "sudo /usr/local/bin/k3s kubectl rollout status sts/sentinel -n data-layer --timeout=120s"
```

**验证**：

```bash
# 确认 3 个 Sentinel Pod Running
ssh k3s-node-01 "sudo /usr/local/bin/k3s kubectl get pods -n data-layer -o wide | grep sentinel"

# 查看 Sentinel 监控状态
ssh k3s-node-01 "sudo /usr/local/bin/k3s kubectl exec -n data-layer sentinel-0 -- redis-cli -p 26379 SENTINEL master mymaster"

# 预期输出包含 ip、port、num-slaves、num-other-sentinels、status
```

---

#### Step 4: 验证 Redis HA

**目标**：验证 Redis 主从复制和 Sentinel 自动故障切换功能。

**验证 1 主从复制**

```bash
# 确认 redis-0 是 master
kubectl exec -n data-layer redis-0 -- redis-cli ROLE
# → master

# redis-0 写入测试 key
kubectl exec -n data-layer redis-0 -- redis-cli SET phase3-test "sentinel-ha-ok"

# redis-1 和 redis-2 应自动同步
kubectl exec -n data-layer redis-1 -- redis-cli GET phase3-test
kubectl exec -n data-layer redis-2 -- redis-cli GET phase3-test
# → "sentinel-ha-ok" ✓ 两行均为预期的值
```

**验证 2 Sentinel 集群状态**

```bash
# 查看 Sentinel 视角的 master 信息
kubectl exec -n data-layer sentinel-0 -- redis-cli -p 26379 SENTINEL master mymaster

# 查看所有已知 Sentinel
kubectl exec -n data-layer sentinel-0 -- redis-cli -p 26379 SENTINEL sentinels mymaster

# 预期：3 个 Sentinel 互相发现，quorum=2
```

**验证 3 故障切换测试**

```bash
# 触发手动切换
kubectl exec -n data-layer sentinel-0 -- redis-cli -p 26379 SENTINEL failover mymaster

# 等待切换完成（<10 秒）
sleep 10

# 查看新的 master
kubectl exec -n data-layer sentinel-0 -- redis-cli -p 26379 SENTINEL master mymaster | grep -E "ip|port|status"

# 测试数据完整性（phase3-test 应在新的 master 上可读）
kubectl exec -n data-layer redis-1 -- redis-cli GET phase3-test
# → "sentinel-ha-ok"
```

**验证指标**：

| 检查项 | 预期结果 | 验证方式 |
|--------|---------|---------|
| Redis 主从复制 | 3 副本 ROLE 正确 | `redis-cli ROLE` |
| 数据同步 | Slave 可读 Master 写入的值 | `GET phase3-test` |
| Sentinel 数量 | 3 个互相发现 | `SENTINEL sentinels mymaster` |
| 故障切换 | < 10 秒完成，新 master 选举 | `SENTINEL failover` + `SENTINEL master` |
| 数据一致性 | Failover 后数据不丢失 | 切换前后 key 均存在 |

### 最终 Pod 分布

| Pod | 节点 | Pod IP | 角色 |
|-----|------|--------|------|
| redis-0 | node-03 | 10.42.2.7 | Redis（初始 master/failover 后可能变 slave） |
| redis-1 | node-02 | 10.42.1.10 | Redis slave（failover 后可能变 master） |
| redis-2 | node-01 | 10.42.0.37 | Redis slave |
| sentinel-0 | node-02 | 10.42.1.12 | Sentinel |
| sentinel-1 | node-03 | 10.42.2.10 | Sentinel |
| sentinel-2 | node-01 | 10.42.0.38 | Sentinel |

---

## 4. MySQL HA + 读写分离

### 部署架构

| 组件 | 镜像 | 节点 | 端口 | 说明 |
|------|------|------|------|------|
| Orchestrator | `openarkcode/orchestrator:latest` | node-01 | 3000 (Web/API) | MySQL 拓扑管理 + 自动故障切换 |
| ProxySQL | `proxysql/proxysql:2.7.2` | node-01 | 6033 (MySQL) / 6032 (Admin) | 读写分离代理 + 连接池 |

**数据流：**
```
应用 ──► ProxySQL:6033 ──┬─► HG1 (writer) → 192.168.1.230 (Master node-02)
                        └─► HG2 (reader) → 192.168.1.229 (Slave  node-03)

Orchestrator:3000 ──► 监控 MySQL 拓扑 ──► Master 故障时自动提升 Slave
                                    └──► 通知 ProxySQL 切换路由
```

> 执行顺序：先创建 MySQL 用户，再部署 Orchestrator 发现拓扑，接着部署 ProxySQL 配置读写分离，最后验证。

```
Step 1: MySQL 用户 ──────► orchestrator 拓扑管理 + monitor 监控 + shortlink 应用
    │
    ▼
Step 2: Orchestrator ────► ConfigMap(密码 init container) → Deployment → discover 拓扑
    │
    ▼
Step 3: ProxySQL ────────► ConfigMap(init container 密码注入) → Deployment
    │                      ⚠️ read_only 配置校验
    ▼
Step 4: 验证 ────────────► 读写分离(read→Slave/write→Master) → 拓扑发现 → 复制状态
```

---

### 实施步骤（4 步）

#### Step 1: 创建 MySQL 用户与初始化数据库

**目标**：在 MySQL Master 上创建 Orchestrator 拓扑管理用户、ProxySQL 监控用户，确保应用数据库 `shortlink` 已就绪。

**操作**（在 Master 192.168.1.230 上执行）：

```sql
-- Orchestrator 拓扑管理用户（SUPER + REPLICATION 权限）
CREATE USER 'orchestrator'@'%' IDENTIFIED BY 'Orchestrator@2026!';
GRANT SUPER, PROCESS, REPLICATION SLAVE, REPLICATION CLIENT, RELOAD ON *.* TO 'orchestrator'@'%';
GRANT ALL PRIVILEGES ON orchestrator.* TO 'orchestrator'@'%';

-- ProxySQL 监控用户
CREATE USER 'monitor'@'%' IDENTIFIED BY 'Monitor@2026!';
GRANT USAGE, REPLICATION CLIENT ON *.* TO 'monitor'@'%';

-- 应用用户（shortlink 服务使用）
CREATE USER 'shortlink'@'192.168.1.%' IDENTIFIED BY '...';
GRANT ALL PRIVILEGES ON shortlink.* TO 'shortlink'@'192.168.1.%';
FLUSH PRIVILEGES;
```

**涉及 SQL 文件**：

| 文件 | 说明 |
|------|------|
| `ansible/playbooks/templates/init-db.sql.j2` | 数据库初始化 SQL（含上述用户） |

> ⚠️ 这些用户存在于 MySQL 物理机上，不在 K8s 集群中。密码通过 Ansible `all.yml` 变量注入。

**验证**：

```bash
# 确认 3 个用户均可登录
mysql -h 192.168.1.230 -u orchestrator -p -e "SELECT 1"
mysql -h 192.168.1.230 -u monitor -p -e "SELECT 1"
mysql -h 192.168.1.230 -u shortlink -p -e "SELECT 1"
```

---

#### Step 2: 部署 Orchestrator

**目标**：部署 Orchestrator 监控 MySQL 主从拓扑，当 Master 故障时自动提升 Slave 为新 Master。

**涉及文件**：

| 文件 | 操作 | 说明 |
|------|------|------|
| `k8s/data-layer/orchestrator.yaml` | 新建 | ConfigMap + Service + Deployment |

**关键配置**：

```yaml
# orchestrator.json（通过 ConfigMap 挂载）
{
  "ListenAddress": ":3000",
  "MySQLOrchestratorHost": "192.168.1.230",
  "MySQLOrchestratorPort": 3306,
  "MySQLOrchestratorDatabase": "orchestrator",
  "MySQLOrchestratorUser": "orchestrator",
  "MySQLOrchestratorPassword": "Orchestrator@2026!",
  "DiscoverByShowSlaveHosts": false,
  "HostnameResolveMethod": "none",
  "InstancePollSeconds": 5,
  "Autorecovery": true,
  "RecoveryPeriodBlockSeconds": 300,
  "OnFailureDetectionProcesses": [],
  "PostMasterFailoverProcesses": []
}
```

**参数说明**：

| 参数 | 值 | 说明 |
|------|-----|------|
| `DiscoverByShowSlaveHosts` | false | 通过 `SHOW PROCESSLIST` 发现 slave（而非 `SHOW SLAVE HOSTS`） |
| `HostnameResolveMethod` | none | 不进行 DNS 反解，直接用 IP 地址 |
| `Autorecovery` | true | 启用自动故障恢复 |
| 后端存储 | 复用 MySQL Master 的 `orchestrator` 库 | 不单独部署 MySQL 容器 |

> ⚠️ 后端存储复用现有 MySQL Master，无需单独部署容器化的 MySQL。

**部署命令**：

```bash
# 部署（ConfigMap + Service + Deployment 在同一个 yaml 中）
ssh k3s-node-01 "sudo /usr/local/bin/k3s kubectl apply -f -" < k8s/data-layer/orchestrator.yaml

# 等待就绪
ssh k3s-node-01 "sudo /usr/local/bin/k3s kubectl rollout status deploy/orchestrator -n data-layer"
```

**触发拓扑发现**（Orchestrator 不会自动发现，需手动触发或配置周期性发现）：

```bash
# 通过 HTTP API 触发拓扑发现
kubectl exec -n data-layer deploy/orchestrator -- curl -s http://localhost:3000/api/discover/192.168.1.230/3306
```

**验证**：

```bash
# 确认拓扑已发现
kubectl exec -n data-layer deploy/orchestrator -- curl -s http://localhost:3000/api/topology/192.168.1.230/3306 | python3 -m json.tool

# 预期输出包含 Master + Replica 信息
# Master: k3s-node-02:3306 (ServerID:1, ReadOnly:false, GTID:ON)
# Replica: 192.168.1.229:3306 (ServerID:2)
```

---

#### Step 3: 部署 ProxySQL

**目标**：部署 ProxySQL 实现读写分离——SELECT 走 Slave（HG2），INSERT/UPDATE/DELETE 走 Master（HG1）。

**涉及文件**：

| 文件 | 操作 | 说明 |
|------|------|------|
| `k8s/data-layer/proxysql.yaml` | 新建 | ConfigMap + Service + Deployment |

**关键设计**：

- **ConfigMap** 存储 `proxysql.cnf`，其中密码部分使用 `__PLACEHOLDER__` 占位
- **init container** 读取 Secret 中的真实密码，`sed` 替换占位符后写入持久化数据目录
- **主容器** ProxySQL 从持久化数据目录加载配置

**ConfigMap 核心配置**（`proxysql.cnf`）：

```sql
-- mysql_replication_hostgroups：ProxySQL 根据 read_only 自动路由
INSERT INTO mysql_replication_hostgroups (writer_hostgroup, reader_hostgroup, comment)
VALUES (1, 2, 'shortlink-cluster');

-- 后端 MySQL 实例（密码用 __PLACEHOLDER__ 占位）
INSERT INTO mysql_servers (hostgroup_id, hostname, port, weight)
VALUES (1, '192.168.1.230', 3306, 1);   -- HG1: Master (writer)
INSERT INTO mysql_servers (hostgroup_id, hostname, port, weight)
VALUES (2, '192.168.1.229', 3306, 1);   -- HG2: Slave (reader)

-- 查询规则（区分读写）
INSERT INTO mysql_query_rules (rule_id, active, match_pattern, destination_hostgroup, apply)
VALUES (1, 1, '^SELECT.*FOR UPDATE', 1, 1);      -- FOR UPDATE → writer
VALUES (2, 1, '^SELECT',              2, 1);      -- SELECT    → reader
VALUES (3, 1, '^(INSERT|UPDATE|DELETE|CREATE|ALTER|DROP|TRUNCATE|REPLACE)', 1, 1);  -- 写操作 → writer
```

**部署命令**：

```bash
# 创建 MySQL 密码 Secret
ssh k3s-node-01 "sudo /usr/local/bin/k3s kubectl create secret generic mysql-credentials -n data-layer \
  --from-literal=monitor-password='Monitor@2026!' \
  --from-literal=shortlink-password='...'"

# 部署 ProxySQL
ssh k3s-node-01 "sudo /usr/local/bin/k3s kubectl apply -f -" < k8s/data-layer/proxysql.yaml

# 等待就绪
ssh k3s-node-01 "sudo /usr/local/bin/k3s kubectl rollout status deploy/proxysql -n data-layer"
```

> ⚠️ **踩坑——ProxySQL libconfig 语法**
>
> ProxySQL 的配置文件使用 libconfig 格式，常见语法错误：
> - 字符串值必须加引号：`datadir="/var/lib/proxysql"`
> - 字段名不能用简写：`hostname` 不是有效字段，用 `address`
> - `:` 分隔符改为 `=`
>
> 错误示例（导致 CrashLoopBackOff，Parse error at line 1）：
> ```
> datadir=/var/lib/proxysql       # ❌ 缺少引号
> hostname=192.168.1.230          # ❌ hostname 不是有效字段
> ```

**验证**：

```bash
# 确认 ProxySQL 运行
kubectl get pods -n data-layer | grep proxysql

# 通过 ProxySQL 管理接口查看主机分组
kubectl exec -n data-layer deploy/proxysql -- mysql -h 127.0.0.1 -P 6032 -u admin -padmin -e \
  "SELECT hostgroup_id, hostname, port, status FROM mysql_servers"

# 预期：
# HG1 (writer): 192.168.1.230 ONLINE
# HG2 (reader): 192.168.1.229 ONLINE
```

---

#### Step 4: 验证 MySQL HA + 读写分离

**目标**：验证 ProxySQL 读写分离路由正确、Orchestrator 拓扑发现完整，确认复制状态正常。

**验证 1 ProxySQL 读写分离**

```bash
# 通过 ProxySQL:6033 执行查询，确认读走 Slave
kubectl exec -n data-layer deploy/proxysql -- mysql -h 127.0.0.1 -P 6033 -u shortlink -p... \
  -e "SELECT @@hostname"

# 期望：返回 k3s-node-03（Slave，192.168.1.229）

# 写入测试
kubectl exec -n data-layer deploy/proxysql -- mysql -h 127.0.0.1 -P 6033 -u shortlink -p... \
  -e "INSERT INTO shortlink.url_mapping (original_url) VALUES ('https://test-rw.com')"

# 确认写入后数据可读（2 秒等待复制延迟）
sleep 2
kubectl exec -n data-layer deploy/proxysql -- mysql -h 127.0.0.1 -P 6033 -u shortlink -p... \
  -e "SELECT * FROM shortlink.url_mapping ORDER BY id DESC LIMIT 1"

# 期望：返回刚插入的数据
```

**验证 2 Orchestrator 拓扑**

```bash
# 查看完整拓扑
kubectl exec -n data-layer deploy/orchestrator -- curl -s http://localhost:3000/api/topology/192.168.1.230/3306 | python3 -m json.tool

# 检查故障恢复状态
kubectl exec -n data-layer deploy/orchestrator -- curl -s http://localhost:3000/api/recovery | python3 -m json.tool
```

**验证 3 MySQL 复制状态**

```bash
# 从 Slave（192.168.1.229）确认复制正常
mysql -h 192.168.1.229 -u root -p -e "SHOW REPLICA STATUS\G" | grep -E "IO_Running|SQL_Running|Seconds_Behind"

# 预期：
# Slave_IO_Running: Yes
# Slave_SQL_Running: Yes
# Seconds_Behind_Master: 0
```

**验证 4 ProxySQL 运行时主机分组**

```bash
kubectl exec -n data-layer deploy/proxysql -- mysql -h 127.0.0.1 -P 6032 -u admin -padmin -e \
  "SELECT * FROM monitor.mysql_server_connect_log ORDER BY time_start_us DESC LIMIT 5"

kubectl exec -n data-layer deploy/proxysql -- mysql -h 127.0.0.1 -P 6032 -u admin -padmin -e \
  "SELECT * FROM stats.stats_mysql_query_rules"
```

**验证指标**：

| 检查项 | 预期结果 | 验证方式 |
|--------|---------|---------|
| 读路由 | `@@hostname` 返回 Slave（node-03） | 通过 ProxySQL:6033 SELECT |
| 写路由 | INSERT 成功，数据持久化到 Master | `INSERT` + `SELECT` 验证 |
| 复制延迟 | `Seconds_Behind_Master: 0` | `SHOW REPLICA STATUS` |
| 拓扑发现 | Master + Slave 完整展示 | Orchestrator API `/api/topology` |
| 主机分组 | HG1 = 192.168.1.230(writer), HG2 = 192.168.1.229(reader) | ProxySQL Admin: `mysql_servers` |

#### 踩坑：Slave read_only 配置

> ⚠️ **根因分析**：ProxySQL 的 `mysql_replication_hostgroups` 依赖 `read_only` 变量区分 Master/Slave。Slave 未配置 `read_only=ON` 时，ProxySQL 将 Slave 同时放入 HG1(writer) 和 HG2(reader)，导致写操作可能路由到 Slave，破坏复制一致性。
>
> **现象**：Slave 同时出现在 HG1 和 HG2；复制中断报 `Duplicate entry for PRIMARY key`。
>
> **修复步骤**：
> 1. Slave 上执行临时设置：
>    ```sql
>    SET GLOBAL read_only=ON;
>    SET GLOBAL super_read_only=ON;
>    ```
> 2. 持久化到 my.cnf（`{% if mysql_role == 'slave' %}` 条件渲染）
> 3. 清理 Slave 上的误写入数据（需临时关闭 super_read_only）
> 4. 重启复制线程：
>    ```sql
>    STOP REPLICA;
>    START REPLICA;
>    ```
> 5. 等待 `Seconds_Behind_Source: 0`

#### 踩坑：k3s ctr image pull 401

> ⚠️ `k3s ctr image pull` 不继承 K3s service 的代理环境变量，拉取 Orchestrator/ProxySQL 镜像时可能 401 认证失败。
>
> **修复**：显式传递代理环境变量：
> ```bash
> sudo HTTP_PROXY=http://... HTTPS_PROXY=http://... NO_PROXY=... /usr/local/bin/k3s ctr image pull openarkcode/orchestrator:latest
> ```

---

### 最终 Pod 分布

| Pod | 节点 | Pod IP | 角色 |
|-----|------|--------|------|
| orchestrator | node-01 | 10.42.0.40 | MySQL 拓扑管理 |
| proxysql | node-01 | 10.42.0.44 | 读写分离代理 |
| redis-0 | node-03 | 10.42.2.7 | Redis（初始 master） |
| redis-1 | node-02 | 10.42.1.10 | Redis（failover 后 master） |
| redis-2 | node-01 | 10.42.0.37 | Redis slave |
| sentinel-0 | node-02 | 10.42.1.12 | Sentinel |
| sentinel-1 | node-03 | 10.42.2.10 | Sentinel |
| sentinel-2 | node-01 | 10.42.0.38 | Sentinel |

## 5. 拓展阅读

- [幂等性是什么？一文读懂高并发下的幂等性实现方案！ - 知乎](https://zhuanlan.zhihu.com/p/721671925)
- [深入解析MySQL GTID主从复制的原理、部署与核心避坑策略 - wgwyanfs - 博客园](https://www.cnblogs.com/wgwyanfs/p/19808265)
- [深入理解Redis哨兵（Sentinel）原理：高可用架构的核心守护者-腾讯云开发者社区-腾讯云](https://cloud.tencent.com/developer/article/2628989)
- 