# Phase 7：备份容灾

## 1. 概述

为 K3s HA 集群建立完整的备份与灾难恢复体系，覆盖"集群级"和"数据级"两个维度：

- **MySQL（物理机级）**：Percona XtraBackup 全量备份，流式压缩，推送阿里云 OSS
- **K8s 资源 + Redis PVC（集群级）**：Velero + File System Backup (kopia)，后端 OSS (S3 兼容)
- **恢复演练**：MySQL (xtrabackup --copy-back via Ansible) + K8s (Velero restore)

**状态：已实施**

| 配置项 | 值 |
|--------|-----|
| 存储后端 | 阿里云 OSS (cn-hangzhou, S3 兼容) |
| 保留策略 | 7 天（OSS Lifecycle Rule 自动清理） |
| MySQL 备份时间 | 每日 02:00 (Asia/Shanghai) |
| K8s 备份时间 | 每日 02:30 (Asia/Shanghai, xtrabackup 之后) |
| 预估月费用 | ~¥0.84（标准存储 LRS ¥0.12/GB/月, 7 天总量 ~7GB） |

### 实施验证摘要

| 组件 | 状态 | 说明 |
|------|------|------|
| OSS Bucket | ✅ 已创建 | `k3s-backup-velero`, Lifecycle rule 7 天 |
| xtrabackup 手动测试 | ✅ 通过 | 771M 数据 → 4.5M gzip, `completed OK!` |
| xtrabackup cron | ⏳ 待设置 | 每日 02:00, 由 Ansible playbook 04 部署 |
| Velero Pod | ✅ Running (1/1) | node-02, 全参数验证通过 |
| node-agent DaemonSet | ✅ Running (1/1) | node-01 仅（nodeSelector 限制） |
| BSL (OSS) | ✅ Available | `s3ForcePathStyle=false`, `checksumAlgorithm=""` |
| Velero 测试备份 | ✅ Completed | 55 items, 0 errors |
| 恢复演练 (MySQL) | ✅ 通过 | 2026-07-27 端到端验证，9 个 Play 全部通过 |
| 恢复演练 (K8s) | ✅ 通过 | 2026-07-27 端到端验证，备份→删除→恢复→数据验证完整链路 |
| node-agent 标签修复 | ✅ 已修复 | DaemonSet label 改为 `name=node-agent` (Velero v1.15 硬编码) |
| node-agent 全节点部署 | ✅ 已修复 | 移除 nodeSelector，所有 3 节点运行 node-agent |
| OOM 问题 | ⚠️ 已缓解 | FluxCD 缩到 0 释放内存，长期需升级 node-01 或拆分负载 |
| containerd mirror (node-02/03) | ⚠️ 已修复 | 移除 docker.io mirror，避免缓存镜像被忽略 |
| Redis AOF 持久化 | ✅ 已确认 | 备份前需 `BGREWRITEAOF` 确保数据刷盘 |
| Sentinel 状态 | ⚠️ 已知限制 | Pod 重建后 Sentinel 持有旧 IP，需重置 PVC |

## 2. 备份架构

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         备份容灾架构                                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌───────────────┐     xtrabackup --stream=xbstream     ┌────────────────┐  │
│  │   node-03     │ ─────────────────────────────────────►│  阿里云 OSS    │  │
│  │  MySQL Slave  │  每日 02:00, gzip 压缩, 推送           │  Bucket:       │  │
│  │  (备份源)     │                                      │  k3s-backup-   │  │
│  │  super_read_  │                                      │  velero        │  │
│  │  only=ON      │                                      │                │  │
│  └───────────────┘                                      │  /mysql-backups│  │
│                                                         │  /velero-backups│ │
│  ┌───────────────┐   Velero FSB (kopia)                 │                │  │
│  │  K8s cluster  │ ─────────────────────────────────────►│  保留: 7 天    │  │
│  │  velero ns    │  每日 02:30, xtrabackup 之后          │  (~7GB 总量)   │  │
│  │  node-agent   │  data-layer + app-layer               │  Lifecycle Rule│  │
│  │  (DaemonSet)  │  Redis 3 PVC via FSB                  └───────┬────────┘  │
│  └───────────────┘                                              │           │
│                                                                 │           │
│  恢复路径:                                                      │           │
│    MySQL:  OSS → 下载 → xtrabackup --prepare → --copy-back     │           │
│            → chown → 启动 mysqld → GTID 自动接续复制             │           │
│                                                                 │           │
│    K8s:    velero restore create → 重建 PVC → node-agent       │           │
│            从 OSS 下载 kopia 快照 → 恢复 Redis 数据              │           │
└─────────────────────────────────────────────────────────────────┘           │
                                                                              │
  节点分布:                                                                    │
  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐                       │
  │  node-01     │  │  node-02     │  │  node-03     │                       │
  │  2C2G        │  │  2C4G        │  │  2C4G        │                       │
  │  FluxCD      │  │  MySQL M     │  │  MySQL S     │                       │
  │  互联网出口    │  │  Velero Srv  │  │  xtrabackup  │                       │
  │              │  │              │  │  (备份源)     │                       │
  │  node-agent  │  │  node-agent  │  │  node-agent  │                       │
│  └──────────────┘  └──────────────┘  └──────────────┘                       │
└─────────────────────────────────────────────────────────────────────────────┘
```

**双备份策略**：

| 维度 | 工具 | 部署方式 | 覆盖范围 | 恢复方式 |
|------|------|---------|---------|---------|
| 集群级 | Velero v1.15.0 | K8s Pod (GitOps 管理) | K8s 资源 + Redis 3 PVC (FSB/kopia) | velero restore create |
| 数据级 | Percona XtraBackup 8.0 | 物理机 cron (node-03) | MySQL 数据文件 (全量) | xtrabackup --copy-back (Ansible) |

## 3. 关键技术约束

以下约束直接决定了 Phase 7 的技术选型：

| 约束 | 影响 | 应对方案 |
|------|------|---------|
| local-path-provisioner 无 CSI 快照支持 | VolumeSnapshotClass CRD 不存在，Velero 不能用 snapshot 方式 | 使用 FSB (File System Backup / kopia) |
| MySQL 在物理机而非 K8s | Velero 无法覆盖 MySQL | xtrabackup 物理机脚本 + cron，与 Velero 分离 |
| 仅 3 个 PVC (Redis) | ProxySQL/Orchestrator/Sentinel 均用 emptyDir | Velero FSB 实际只需备份 redis-data-redis-0/1/2 |
| node-01 资源最小 (2C2G) | k3s server ~756MB + Velero server + node-agent kopia (~200MB) + data-layer pods → 峰值 ~1.4GB/2GB | Velero server/node-agent 钉住 node-01（唯一有公网拉取 ghcr.io/Docker Hub 镜像）；备份前缩 FluxCD 到 0 释放 ~400MB |
| node-02/03 无公网 | RPM 下载需经 node-01 中转；镜像拉取失败（即使本地已缓存） | 同 Phase 3 airgap 模式；移除 registries.yaml 中 docker.io mirror |
| Velero v1.15 label 硬编码 | `IsRunningInNode()` 用 `name=node-agent` 查找 Pod | DaemonSet label 必须匹配，不可用 `app=node-agent` |
| Redis AOF 持久化延迟 | `SET` 后数据在内存，备份前未刷盘导致恢复后数据丢失 | 备份前对所有 Pod 执行 `BGREWRITEAOF` |
| Sentinel 持有旧 Pod IP | Pod 重建后 IP 变更，Sentinel 读取旧 PVC 数据指向旧 IP → master s_down | 恢复前需重置 Sentinel PVC，或 Sentinel 缩到 0 |
| PV ReclaimPolicy=Delete | 删除 PVC 即删数据 | 备份是数据安全的最后兜底 |

## 4. 实施步骤（7 步）

### Step 1：OSS 基础设施搭建

**类型**：手动操作（用户）+ Ansible 变量更新
**依赖**：无

#### 1.1 手动：创建 OSS Bucket

1. 阿里云控制台 → OSS → 创建 Bucket
   - Bucket 名：`k3s-backup-velero`
   - 地域：`cn-hangzhou`（与 ECS 同地域，VPC 内网传输免费）
   - 存储类型：标准存储（LRS）
   - 读写权限：私有
   - 加密：OSS 托管加密 (SSE-OSS)

2. 配置生命周期规则（7 天自动删除）：
   - 规则名：`delete-after-7-days`
   - 前缀：`/`（整个 Bucket）
   - 操作：7 天后删除对象

#### 1.2 手动：创建 RAM 子账号 + AK/SK

1. RAM 控制台 → 用户 → 创建用户
   - 用户名：`k3s-backup`
   - 访问方式：OpenAPI 调用（生成 AK/SK）

2. 授权：
   - 策略：`AliyunOSSFullAccess`（或自定义仅读写 `k3s-backup-velero` Bucket）

3. 保存 AK/SK — ossutil 和 Velero 都需要

#### 1.3 更新 Ansible 变量

**文件**：`ansible/group_vars/all.yml`（gitignored）— 末尾追加：

```yaml
# ── OSS Backup Configuration ───────────────────────────────
oss_bucket: "k3s-backup-velero"
oss_endpoint: "oss-cn-hangzhou-internal.aliyuncs.com"
oss_region: "cn-hangzhou"
oss_access_key_id: "<real-ak>"
oss_access_key_secret: "<real-sk>"
oss_mysql_backup_prefix: "mysql-backups"
oss_velero_backup_prefix: "velero-backups"
```

**文件**：`ansible/group_vars/all.yml.example`（入库）— 末尾追加脱敏模板：

```yaml
# ── OSS Backup Configuration ───────────────────────────────
oss_bucket: "k3s-backup-velero"
oss_endpoint: "oss-cn-hangzhou-internal.aliyuncs.com"
oss_region: "cn-hangzhou"
oss_access_key_id: "CHANGE_ME"             # <- RAM AK
oss_access_key_secret: "CHANGE_ME"         # <- RAM SK
oss_mysql_backup_prefix: "mysql-backups"
oss_velero_backup_prefix: "velero-backups"
```

#### 1.4 验证

```bash
# 从 node-01 测试 OSS 连通性（有公网出口）
ossutil ls oss://k3s-backup-velero \
  -e oss-cn-hangzhou-internal.aliyuncs.com \
  -i <AK> -k <SK>
# 预期：空列表（Bucket 存在，无对象）
```

#### 1.5 注意事项

- **内网 vs 公网端点**：使用 `oss-cn-hangzhou-internal.aliyuncs.com`（VPC 内网免费）；公网端点 `oss-cn-hangzhou.aliyuncs.com` 也可用但产生流量费
- **Bucket 命名**：OSS Bucket 名全局唯一，如 `k3s-backup-velero` 被占用则加随机后缀
- **Lifecycle Rule**：必须配置，否则备份数据会无限增长

---

### Step 2：xtrabackup 安装 + 备份脚本

**类型**：Ansible Playbook + Shell 脚本 + cron
**依赖**：Step 1（OSS 凭证）

#### 2.1 设计决策：从 Slave (node-03) 备份

| 考量 | 从 Master (node-02) | 从 Slave (node-03) ✓ |
|------|--------------------|--------------------|
| Master 写入性能影响 | 有（xtrabackup 占用 IO） | 无 |
| 数据一致性 | 直接一致 | 复制延迟 <1s（771M 数据集） |
| `super_read_only` | 无 | `ON` — xtrabackup 读取不受影响 |
| 恢复安全性 | 恢复到 Master 有停机风险 | 恢复到 Slave，Master 继续服务 |

**结论**：从 node-03 (Slave) 备份，使用 `--no-lock`（Slave 只读安全）+ `--slave-info`（记录 relay log 位置）。

#### 2.2 Ansible Playbook

`ansible/playbooks/04-setup-backup-tools.yml`

**用途**：在 node-03 安装 percona-xtrabackup-80 + ossutil，部署备份脚本 + cron

**结构**（遵循现有 playbook 约定：`become: true`，`changed_when`/`when` 守卫，分节注释）：

```yaml
---
# 04-setup-backup-tools.yml
# 在 MySQL Slave (node-03) 安装备份工具:
#   - percona-xtrabackup-80 (MySQL 物理备份)
#   - ossutil (阿里云 OSS CLI)
# 部署 xtrabackup-backup.sh 脚本 + cron (每日 02:00)
#
# 前提:
#   - group_vars/all.yml 已填写 oss_access_key_id/secret
#   - OSS bucket k3s-backup-velero 已创建
#
# 运行: ansible-playbook -i inventory.ini playbooks/04-setup-backup-tools.yml
```

**Play 1：校验 OSS 凭证** (hosts: localhost, connection: local)
- Assert `oss_access_key_id` 和 `oss_access_key_secret` 非空
- 模式参照 `03-configure-acr.yml` Play 1

**Play 2：在 node-01 下载 RPM** (hosts: node-01, become: true)
- node-01 有公网出口 (EIP)
- 下载 Percona XtraBackup RPM：
  - 来源：`https://repo.percona.com/yum/release/8/RPMS/x86_64/`
  - 包含：`percona-xtrabackup-80` + `qpress` 依赖
- 下载 ossutil 二进制：
  - `https://gosspublic.alicdn.com/ossutil/v1/ossutil64`
- 存放 `/tmp/backup-tools/`
- `changed_when`：检查文件是否存在再下载

**Play 3：在 node-03 安装工具** (hosts: node-03, become: true)
- 创建 `/tmp/backup-tools/` 目录
- 从 node-01 同步 RPM（`synchronize` 模块或 `command: scp`）
- 安装：`dnf localinstall -y /tmp/backup-tools/percona-xtrabackup-*.rpm`
- 验证：`xtrabackup --version`
- 安装 ossutil：`cp ossutil64 /usr/local/bin/ossutil && chmod +x`
- 验证：`ossutil version`

**Play 4：配置 ossutil + 部署脚本** (hosts: node-03, become: true)
- 渲染 ossutil 配置（模板 `ossutil-config.j2`）到 `/root/.ossutilconfig`
- 创建备份目录：`/data/backups/mysql/`
- 部署 `xtrabackup-backup.sh` 到 `/usr/local/bin/`（mode 0755）
- 部署 cron：`/etc/cron.d/xtrabackup-backup`
  ```cron
  # MySQL xtrabackup -- 每日 02:00 全量备份
  # Managed by Ansible -- do not edit manually
  0 2 * * * root /usr/local/bin/xtrabackup-backup.sh >> /var/log/xtrabackup-backup.log 2>&1
  ```
- 测试 OSS 连通性：`ossutil ls oss://{{ oss_bucket }} -e {{ oss_endpoint }}`

**Play 5：汇总** (hosts: node-03)
- 显示已安装版本 + cron 计划 + 下次运行时间

#### 2.3 模板

`ansible/playbooks/templates/ossutil-config.j2`

```ini
# /root/.ossutilconfig
# Managed by Ansible -- do not edit manually
# Node: {{ inventory_hostname }}
[Credentials]
provider = oss
accessKeyId = {{ oss_access_key_id }}
accessKeySecret = {{ oss_access_key_secret }}

[Config]
endpoint = {{ oss_endpoint }}
```

#### 2.4 脚本

`scripts/xtrabackup-backup.sh`

**用途**：xtrabackup 全量备份 → gzip 压缩 → 推送 OSS → 清理旧备份

**风格约定**（参照 `build-push.sh`）：

- `#!/usr/bin/env bash` + `set -euo pipefail`
- `──` 分节注释
- `${VAR:-default}` 环境变量默认值
- 末尾汇总输出

**注意事项**：

- 依赖 `/root/.my.cnf` 认证（不传 `--user`/`--password` 以防默认值覆盖 my.cnf）
- 添加 `--safe-slave-backup` 暂停 SQL 线程确保 binlog 位置一致
- `MYSQL_PASSWORD` 默认值改为 `""`（原 `CHANGE_ME` 会覆盖 my.cnf）

```bash
#!/usr/bin/env bash
# xtrabackup-backup.sh -- MySQL 全量备份 via Percona XtraBackup, 推送 OSS
#
# 在 node-03 (MySQL Slave) 运行, 避免 Master 负载。
# 流式压缩备份, 上传 OSS, 清理旧本地副本。
#
# 用法:
#   /usr/local/bin/xtrabackup-backup.sh           # 全量备份 + 上传
#   /usr/local/bin/xtrabackup-backup.sh --dry-run # 仅展示
#
# Cron: 0 2 * * * /usr/local/bin/xtrabackup-backup.sh >> /var/log/xtrabackup-backup.log 2>&1

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────
MYSQL_USER="${MYSQL_USER:-root}"
# 密码由 /root/.my.cnf [client] 提供 (host=127.0.0.1 user=root password=XXX)
# 脚本不传 --password 以防覆盖 my.cnf 配置
MYSQL_PASSWORD="${MYSQL_PASSWORD:-}"
BACKUP_DIR="${BACKUP_DIR:-/data/backups/mysql}"
OSS_BUCKET="${OSS_BUCKET:-k3s-backup-velero}"
OSS_PREFIX="${OSS_PREFIX:-mysql-backups}"
OSSUTIL_BIN="${OSSUTIL_BIN:-/usr/local/bin/ossutil}"
OSS_ENDPOINT="${OSS_ENDPOINT:-oss-cn-hangzhou-internal.aliyuncs.com}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
DATE="$(date +%Y%m%d-%H%M%S)"
BACKUP_NAME="mysql-full-${DATE}"
BACKUP_FILE="${BACKUP_DIR}/${BACKUP_NAME}.xbstream.gz"

# ── Dry-run ────────────────────────────────────────────────────
if [ "${1:-}" = "--dry-run" ]; then
    echo "[DRY-RUN] xtrabackup-backup.sh"
    echo "  MYSQL_USER=${MYSQL_USER}"
    echo "  BACKUP_DIR=${BACKUP_DIR}"
    echo "  OSS_BUCKET=${OSS_BUCKET}"
    echo "  OSS_PREFIX=${OSS_PREFIX}"
    echo "  OSS_ENDPOINT=${OSS_ENDPOINT}"
    echo "  RETENTION_DAYS=${RETENTION_DAYS}"
    echo "  BACKUP_FILE=${BACKUP_FILE}"
    echo ""
    echo "  Would run: xtrabackup --backup --stream=xbstream ... | gzip > ${BACKUP_FILE}"
    echo "  Would push: ossutil cp ${BACKUP_FILE} oss://${OSS_BUCKET}/${OSS_PREFIX}/"
    echo "  Would clean: find ${BACKUP_DIR} -name 'mysql-full-*.xbstream.gz' -mtime +${RETENTION_DAYS} -delete"
    exit 0
fi

# ── Pre-flight checks ────────────────────────────────────────
if ! command -v xtrabackup &>/dev/null; then
    echo "FATAL: xtrabackup not found. Install percona-xtrabackup-80 first."
    exit 1
fi

if ! command -v "${OSSUTIL_BIN}" &>/dev/null; then
    echo "FATAL: ossutil not found at ${OSSUTIL_BIN}. Install ossutil first."
    exit 1
fi

if ! mysqladmin ping --silent 2>/dev/null; then
    echo "WARNING: MySQL not reachable. Check /root/.my.cnf credentials."
    exit 1
fi

mkdir -p "${BACKUP_DIR}"

# Check available disk space (warn if < 5G)
AVAIL_KB=$(df "${BACKUP_DIR}" | tail -1 | awk '{print $4}')
if [ "${AVAIL_KB}" -lt 5242880 ]; then
    echo "WARNING: Low disk space in ${BACKUP_DIR}: $((AVAIL_KB / 1024))M available"
fi

# ── Backup ─────────────────────────────────────────────────────
# 流式备份直接写入压缩文件 (无中间暂存)
# --slave-info: 记录 relay log 位置 (replica 备份)
# --no-lock: Slave 只读 (super_read_only=ON), 安全无需锁
# --safe-slave-backup: 暂停 SQL 线程确保 binlog 位置与备份一致
# 密码通过 /root/.my.cnf [client] user=root password=XXX 提供

echo "--- Starting xtrabackup: ${BACKUP_NAME} ---"
# 密码由 /root/.my.cnf [client] host=127.0.0.1 user=root password=XXX 提供
# 不传 --user/--password 以防覆盖 my.cnf 配置
xtrabackup --backup \
  --stream=xbstream \
  --slave-info \
  --no-lock \
  --safe-slave-backup \
  | gzip > "${BACKUP_FILE}"

# ── Verify backup ─────────────────────────────────────────────
BACKUP_SIZE=$(stat -c%s "${BACKUP_FILE}" 2>/dev/null || stat -f%z "${BACKUP_FILE}" 2>/dev/null || echo "0")
if [ "${BACKUP_SIZE}" -eq 0 ]; then
    echo "FATAL: Backup file is empty: ${BACKUP_FILE}"
    rm -f "${BACKUP_FILE}"
    exit 1
fi
echo "Backup file size: $(du -h "${BACKUP_FILE}" | cut -f1)"

# ── Push to OSS ───────────────────────────────────────────────
echo "--- Uploading to OSS: ${OSS_BUCKET}/${OSS_PREFIX}/ ---"
"${OSSUTIL_BIN}" cp "${BACKUP_FILE}" \
  "oss://${OSS_BUCKET}/${OSS_PREFIX}/$(basename "${BACKUP_FILE}")" \
  -e "${OSS_ENDPOINT}"

# ── Cleanup old local backups ─────────────────────────────────
# 保留本地最近 2 份 (快速恢复), OSS Lifecycle Rule 处理远端 7 天清理
echo "--- Cleaning up local backups older than ${RETENTION_DAYS} days ---"
find "${BACKUP_DIR}" -name "mysql-full-*.xbstream.gz" -mtime +${RETENTION_DAYS} -delete

# ── Summary ───────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " MySQL backup complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo " Backup name:    ${BACKUP_NAME}"
echo " Local file:     ${BACKUP_FILE}"
echo " Local size:     $(du -h "${BACKUP_FILE}" | cut -f1)"
echo " OSS location:   oss://${OSS_BUCKET}/${OSS_PREFIX}/$(basename "${BACKUP_FILE}")"
echo " Retention:      ${RETENTION_DAYS} days (OSS lifecycle rule)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
```

#### 2.5 验证

```bash
# ssh node-03
ssh -J k3s-node-01 ops@192.168.1.229

# 手动运行备份
sudo /usr/local/bin/xtrabackup-backup.sh

# 检查本地备份文件
ls -lh /data/backups/mysql/

# 检查 OSS 上传
sudo /usr/local/bin/ossutil ls oss://k3s-backup-velero/mysql-backups/ -e oss-cn-hangzhou-internal.aliyuncs.com

# 验证备份完整性 (prepare 测试)
# 使用 ls -t 取最新 .xbstream.gz, 避免通配符匹配多个文件导致 gunzip 报错
sudo bash -c \
  'rm -rf /tmp/xbtest && mkdir -p /tmp/xbtest && \
   LATEST=\$(ls -t /data/backups/mysql/mysql-full-*.xbstream.gz | head -1) && \
   echo \"Preparing: \$LATEST\" && \
   gunzip -c \"\$LATEST\" | xbstream -x -C /tmp/xbtest && \
   xtrabackup --prepare --target-dir=/tmp/xbtest && \
   rm -rf /tmp/xbtest'
```

#### 2.6 注意事项

1. **xtrabackup 版本兼容**：PXB 8.0.35+ 支持 MySQL 8.0.46，安装后验证 `xtrabackup --version`
2. **node-03 无公网**：RPM 经 node-01 下载后 scp 传输，同 Phase 3 airgap 模式
3. **`--no-lock` 安全性**：Slave 有 `super_read_only=ON` 防止写入，`--no-lock` 安全；Master 上则不可用
4. **磁盘空间**：771M 数据压缩后约 100-200M，`/data/backups/mysql/` 需 ~1G（保留 2 份）
5. **cron 用户**：以 `root` 运行（xtrabackup 需 root 读取 MySQL 数据文件）
6. **ossutil 配置**：必须在 `/root/.ossutilconfig`（root cron job 读取位置）
7. **`/root/.my.cnf` 认证**：xtrabackup 通过 DBI（TCP）连接 MySQL，`root@localhost` 使用 `caching_sha2_password` 仅能通过 Unix socket 认证。需创建 `root@127.0.0.1` 并指定 `mysql_native_password`，同时在 `/root/.my.cnf` 设置 `host=127.0.0.1`
8. **`--user`/`--password` 陷阱**：脚本中如果传 `--password=CHANGE_ME`（默认值）会覆盖 `/root/.my.cnf`，导致认证失败。脚本应完全依赖 my.cnf，不传密码参数

---

### Step 3：Velero via FluxCD GitOps

**类型**：K8s Manifests + FluxCD Kustomization CR + 手动 CRD/Secret 创建
**依赖**：Step 1（OSS 凭证）

#### 3.1 设计决策：原始 YAML（非 Helm）

项目使用 flat Kustomize（无 Helm），Velero manifests 从 `velero install --dry-run -o yaml` 生成后提交为原始 YAML。

| 配置项 | 值 |
|--------|-----|
| Velero 版本 | v1.15.0（或实施时最新稳定版） |
| AWS 插件 | velero-plugin-for-aws:v1.11.0 |
| 镜像来源 | ACR VPC (`crpi-*.personal.cr.aliyuncs.com`) 推送 + node-01 Docker Hub 拉取 |
| 备份模式 | FSB (File System Backup / kopia) |
| 调度节点 | **node-01** (唯一有公网拉取 ghcr.io/Docker Hub 镜像；2C2G 需缩 FluxCD 防 OOM) |

#### 3.2 前置：手动安装 Velero CRD

Velero CRD 是集群级资源，必须在 FluxCD 管理 Velero CR (BSL, Schedule) 之前存在。

```bash
# 在 node-01 执行（有公网）
# 下载 Velero CRD bundle
curl -sL https://github.com/vmware-tanzu/velero/releases/download/v1.15.0/velero-v1.15.0-linux-amd64.tar.gz | \
  tar xz -C /tmp/
sudo /usr/local/bin/k3s kubectl apply -f /tmp/velero-v1.15.0-linux-amd64/crds/
```

**验证**：
```bash
sudo /usr/local/bin/k3s kubectl get crd | grep velero.io
# 预期: backups.velero.io, backupstoragelocations.velero.io, schedules.velero.io,
#       serverstatusrequests.velero.io, etc.
```

> **注意**：
> - v1.15.0 新增 `serverstatusrequests.velero.io` CRD，如果 CRD 不完整 velero Pod 会报错 `custom resource ServerStatusRequest not found`。从 release tarball 的 `crds/` 目录确保包含该 CRD
> - CRD 不纳入 GitOps 是 Velero 标准实践 — CRD 很少更新，放入 Kustomize 会增加 ~2000 行 YAML

#### 3.3 前置：手动创建 cloud-credentials Secret

Velero AWS 插件需要一个名为 `cloud-credentials` 的 Secret，key 为 `cloud`，内容为 AWS 风格凭证。

```bash
# 在 node-01 创建凭证文件
cat > /tmp/cloud-credentials <<'EOF'
[default]
aws_access_key_id = <oss_access_key_id>
aws_secret_access_key = <oss_access_key_secret>
EOF

# 创建 K8s Secret
sudo /usr/local/bin/k3s kubectl create namespace velero
sudo /usr/local/bin/k3s kubectl create secret generic cloud-credentials \
  --namespace velero \
  --from-file=cloud=/tmp/cloud-credentials

# 清理
rm /tmp/cloud-credentials
```

#### 3.4 新建文件清单

##### `k8s/velero/namespace.yaml`

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: velero
  labels:
    app.kubernetes.io/part-of: backup-system
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: velero-quota
  namespace: velero
spec:
  hard:
    pods: "10"
    requests.cpu: "2"
    requests.memory: 2Gi
    limits.cpu: "4"
    limits.memory: 4Gi
```

> PSS = `privileged`：node-agent DaemonSet 需要 hostPath + `runAsUser: 0` + SELinux 上下文，`baseline` 会拒绝。`audit`/`warn` 设为 `restricted` 以追踪偏差。

##### `k8s/velero/rbac.yaml`

```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: velero
  namespace: velero
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: velero
  labels:
    app.kubernetes.io/part-of: backup-system
subjects:
  - kind: ServiceAccount
    name: velero
    namespace: velero
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
```

> Velero 需要 cluster-admin 权限来备份/恢复所有资源类型 — 这是 Velero 的标准配置。

##### `k8s/velero/deployment.yaml`

关键字段：

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: velero
  namespace: velero
spec:
  replicas: 1
  template:
    spec:
      serviceAccountName: velero
      nodeSelector:
        kubernetes.io/hostname: node-01    # node-01 唯一有公网拉取 ghcr.io/Docker Hub 镜像
      initContainers:
        - name: velero-plugin-for-aws      # 拷贝 S3 插件到 /target
          image: velero/velero-plugin-for-aws:v1.11.0
          volumeMounts:
            - name: plugins
              mountPath: /target
      containers:
        - name: velero
          image: velero/velero:v1.15.0
          command: ["/velero"]              # 镜像无 ENTRYPOINT, 需显式指定
          args:
            - server
            - --default-volumes-to-fs-backup
            - --uploader-type=kopia
          env:
            - name: AWS_SHARED_CREDENTIALS_FILE
              value: /credentials/cloud
          volumeMounts:
            - name: cloud-credentials
              mountPath: /credentials
            - name: plugins
              mountPath: /plugins
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits:   { cpu: 500m, memory: 512Mi }
      volumes:
        - name: cloud-credentials
          secret:
            secretName: cloud-credentials
        - name: plugins
          emptyDir: {}
```

##### `k8s/velero/node-agent-daemonset.yaml`

**最关键的组件** — FSB (kopia) 的执行者，必须在所有节点运行：

```yaml
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-agent
  namespace: velero
spec:
  selector:
    matchLabels:
      name: node-agent                     # ⚠️ Velero v1.15 硬编码 "name=node-agent"
  template:
    metadata:
      labels:
        name: node-agent                   # ⚠️ 必须匹配，不能用 app=node-agent
    spec:
      serviceAccountName: velero
      securityContext:
        runAsUser: 0
      containers:
        - name: node-agent
          image: crpi-vvz6iv4av6k8awep-vpc.cn-hangzhou.personal.cr.aliyuncs.com/shortlink123/velero-node-agent:v1.15.0
          imagePullPolicy: IfNotPresent
          command: ["/velero"]
          args: ["node-agent", "server", "--log-level=info"]
          env:
            - name: NODE_NAME
              valueFrom: { fieldRef: { fieldPath: spec.nodeName } }
            - name: VELERO_NAMESPACE
              valueFrom: { fieldRef: { fieldPath: metadata.namespace } }
          volumeMounts:
            - name: host-pods
              mountPath: /host_pods
              mountPropagation: HostToContainer
            - name: host-storage
              mountPath: /var/lib/rancher/k3s/storage
              mountPropagation: HostToContainer
            - name: scratch
              mountPath: /scratch
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits:   { cpu: 200m, memory: 256Mi }
      volumes:
        - name: host-pods
          hostPath: { path: /var/lib/kubelet/pods, type: Directory }
        - name: host-storage
          hostPath: { path: /var/lib/rancher/k3s/storage, type: DirectoryOrCreate }
        - name: scratch
          emptyDir: {}
```

**关键说明**：
- **`name=node-agent` label 必须精确匹配**：Velero v1.15 的 `IsRunningInNode()` 函数（`pkg/nodeagent/node_agent.go:111`）使用 `labels.Parse(fmt.Sprintf("name=%s", daemonSet))` 查找 node-agent Pod（daemonSet 常量 = `"node-agent"`）。如果 DaemonSet 用 `app=node-agent`，Velero 找不到 Pod，所有 FSB 卷备份失败。
- `/var/lib/rancher/k3s/storage` 是 K3s local-path-provisioner 存储 PV 数据的路径
- `mountPath: /host_pods` 是 node-agent 二进制硬编码的路径（不是 `/var/lib/kubelet/pods`）
- `mountPropagation: HostToContainer` 确保 node-agent 能看到 kubelet 运行时挂载的卷
- **nodeSelector 已移除**：原配置仅 node-01 运行 node-agent——原因是 node-02/03 无公网无法拉取 `velero/velero:v1.15.0`。**解决方案**：将镜像推送到 ACR VPC 域名（`crpi-vvz6iv4av6k8awep-vpc.cn-hangzhou.personal.cr.aliyuncs.com`），3 节点均可通过 VPC 内网拉取。
- **镜像**：使用 ACR VPC 域名而非 Docker Hub，确保 node-02/03 可拉取

##### `k8s/velero/bsl-oss.yaml`

```yaml
---
apiVersion: velero.io/v1
kind: BackupStorageLocation
metadata:
  name: default
  namespace: velero
spec:
  provider: aws
  default: true
  credential:
    name: cloud-credentials
    key: cloud
  objectStorage:
    bucket: k3s-backup-velero
    prefix: velero-backups
  config:
    region: cn-hangzhou
    s3ForcePathStyle: "false"            # OSS 不支持 path-style 访问
    checksumAlgorithm: ""                # 禁用 AWS 无符号 Payload chunked encoding
    s3Url: "https://oss-cn-hangzhou-internal.aliyuncs.com"
```

##### `k8s/velero/schedule.yaml`

```yaml
---
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: daily-backup
  namespace: velero
  labels:
    app.kubernetes.io/part-of: backup-system
  annotations:
    velero.io/timezone: Asia/Shanghai    # 使用北京时间
spec:
  schedule: "30 2 * * *"                  # 每日 02:30 (xtrabackup 02:00 之后)
  template:
    includedNamespaces:
      - data-layer
      - app-layer
    defaultVolumesToFsBackup: true        # FSB 备份所有 PVC (redis-data)
    ttl: 168h0m0s                         # 7 天 = 7 × 24h
    storageLocation: default
```

> **时区陷阱**：Velero Schedule 默认使用 UTC。`30 2 * * *` 在 UTC 下 = 北京时间 10:30。必须在 `metadata.annotations` 添加 `velero.io/timezone: Asia/Shanghai`。注意 `spec.template.metadata.annotations` 未被 Schedule CRD 支持，不能使用。

##### `k8s/velero/cloud-credentials.example`

```ini
# cloud-credentials -- AWS 风格凭证 (Velero AWS S3 插件)
# 用于认证阿里云 OSS (S3 兼容)
#
# 此文件 gitignored。复制为 cloud-credentials 并填入真实值。
# 然后手动创建 K8s Secret:
#   kubectl create secret generic cloud-credentials -n velero \
#     --from-file=cloud=cloud-credentials

[default]
aws_access_key_id = CHANGE_ME
aws_secret_access_key = CHANGE_ME
```

##### `k8s/velero/kustomization.yaml`

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: velero
resources:
  - namespace.yaml
  - rbac.yaml
  - deployment.yaml
  - node-agent-daemonset.yaml
  - bsl-oss.yaml
  - schedule.yaml
```

> `cloud-credentials` 不在 resources 列表中（gitignored，手动创建）。Secret 必须在 FluxCD reconcile 之前存在，否则 Deployment 挂载失败。

##### `clusters/production/velero.yaml` (FluxCD Kustomization CR)

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: velero
  namespace: flux-system
spec:
  interval: 5m
  retryInterval: 1m
  timeout: 5m
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./k8s/velero
  prune: true
  wait: true
  force: false
  healthChecks:
    - apiVersion: apps/v1
      kind: Deployment
      name: velero
      namespace: velero
```

#### 3.5 修改：Redis StatefulSet 注解

**文件**：`k8s/data-layer/redis-statefulset.yaml`

在 `spec.template.metadata` 添加注解：

```yaml
spec:
  template:
    metadata:
      labels:
        app: redis
      annotations:
        # Velero FSB -- 备份 redis-data PVC
        backup.velero.io/backup-volumes: redis-data
```

注解值 `redis-data` 是 `volumeClaimTemplates[0].metadata.name` 的精确名称。

> 与 Schedule 的 `defaultVolumesToFsBackup: true` 技术上重复，但显式声明意图。

#### 3.6 修改：`.gitignore`

末尾追加：
```
# Velero OSS credentials (gitignored, .example template committed)
k8s/velero/cloud-credentials
```

#### 3.7 验证

```bash
# 0. 前置：安装 ServerStatusRequest CRD (v1.15.0 新增)
# 从 Velero release tarball 获取：
# curl -sL https://github.com/vmware-tanzu/velero/releases/download/v1.15.0/velero-v1.15.0-linux-amd64.tar.gz | tar xz -C /tmp/
# sudo /usr/local/bin/k3s kubectl apply -f /tmp/velero-v1.15.0-linux-amd64/crds/
# 注意：只下载 crds/ 目录也可, 但需确保 serverstatusrequests.velero.io 在其中

# FluxCD reconcile 状态
ssh k3s-node-01 "sudo /usr/local/bin/k3s kubectl get kustomization -n flux-system velero"

# Velero Pod 状态
ssh k3s-node-01 "sudo /usr/local/bin/k3s kubectl get pods -n velero -o wide"
# 预期: velero-xxx (1/1 Running on node-02), node-agent-xxx (每节点 1/1)

# BSL 状态
ssh k3s-node-01 "sudo /usr/local/bin/k3s kubectl get bsl -n velero"
# 预期: default -- available -- aws -- k3s-backup-velero

# 触发手动备份测试
ssh k3s-node-01 "sudo /usr/local/bin/k3s kubectl apply -f - <<'EOF'
apiVersion: velero.io/v1
kind: Backup
metadata: { name: test-backup, namespace: velero }
spec:
  includedNamespaces: [data-layer, app-layer]
  defaultVolumesToFsBackup: true
  ttl: 1h
EOF"

# 检查备份状态
ssh k3s-node-01 "sudo /usr/local/bin/k3s kubectl get backup -n velero test-backup"
# 预期: Completed

# 检查 OSS 中的备份对象 (ossutil在192.168.1.229上)
ssh -J k3s-node-01 ops@192.168.1.229 "sudo /usr/local/bin/ossutil ls oss://k3s-backup-velero/velero-backups/ -e oss-cn-hangzhou-internal.aliyuncs.com"
```

**实际验证结果**：

| 验证项 | 结果 |
|--------|------|
| CRD ServerStatusRequest | ✅ 手动安装 |
| velero Pod (node-01) | ✅ 1/1 Running |
| node-agent (3 节点) | ✅ 每节点 1/1 Running |
| BSL default | ✅ Available (`s3ForcePathStyle=false`, `checksumAlgorithm=""`) |
| 测试备份 `test-backup-2` | ✅ Completed, 55 items, 0 errors, 0 warnings |
| OSS 备份对象 | ✅ velero-backups/ 中存在备份数据 |

#### 3.8 注意事项

1. **Velero 镜像拉取**：`velero/velero:v1.15.0` 在 Docker Hub，registries.yaml 已镜像 `docker.io` → `docker.m.daocloud.io`，所有节点应能拉取。如 daocloud 未镜像，走 airgap：node-01 拉取 → 导出 tarball → scp → K3s 自动导入
2. **node-agent hostPath**：`/var/lib/rancher/k3s/storage` 是 K3s 特有路径，如 K3s 数据目录不同需调整。验证：`ssh node-03 'ls /var/lib/rancher/k3s/storage/'`
3. **Velero server 在 node-01**：node-01 是唯一有公网的节点，FluxCD 控制器依赖 ghcr.io 镜像也必须在此节点。备份期间内存峰值：k3s ~756MB + Velero server ~100-200MB + node-agent kopia ~200MB + data-layer pods ~150MB = **~1.3-1.4GB**（2GB 总量）。备份前必须缩 FluxCD 到 0 释放 ~400MB
4. **CRD 不在 Git**：CRD 手动安装，打破纯 GitOps 模型，但这是 Velero 标准实践
5. **Schedule 时区**：默认 UTC，在 `metadata.annotations` 添加 `velero.io/timezone: Asia/Shanghai`。`spec.template.metadata.annotations` 不被 Schedule CRD 支持
6. **defaultVolumesToFsBackup vs 注解**：Schedule 设 `true`（备份所有 PVC via FSB），StatefulSet 注解显式声明意图，两者保留
7. **`command: ["/velero"]` 必填**：`velero/velero` 镜像有 `CMD server` 但无 `ENTRYPOINT`，不填则 kubelet 无法找到可执行文件，Pod 进入 `CrashLoopBackOff`
8. **`--uploader-type=kopia`**：v1.15.0 默认 uploader 是 kopia，但显式指定可避免未来默认值变更的影响。有效 uploader: `kopia` | `restic`
9. **OSS S3 兼容性**：阿里云 OSS 不支持 `s3ForcePathStyle=true`（必须 `"false"`），不支持 AWS 无符号 Payload chunked encoding（必须 `checksumAlgorithm: ""` 禁用）
10. **Velero server args 限制**：`--use-volume-snapshots`、`--bucket`、`--prefix`、`--backup-location-config` 等是 `velero install` CLI 参数，不是 `velero server` 参数。BSL CRD 管理这些配置
11. **ServerStatusRequest CRD**：v1.15.0 新增 `serverstatusrequests.velero.io` CRD，需要手动从 Velero 发布 tarball 下载并 apply，否则 velero Pod 无法启动

---

### Step 4：MySQL 恢复 Playbook

**类型**：Ansible Playbook
**依赖**：Step 2（xtrabackup 已安装，OSS 中有备份）

#### 4.1 设计决策：恢复到 Slave (node-03)

1. Master (node-02) 恢复期间继续服务
2. 在 Slave 上验证恢复数据
3. GTID auto-positioning 自动重建复制
4. 如验证通过，可选择故障切换到 node-03 作为新 Master

#### 4.2 新建文件

`ansible/playbooks/05-restore-mysql.yml`

```yaml
---
# 05-restore-mysql.yml
# 从 OSS 中的 xtrabackup 备份恢复 MySQL
#
# 目标: node-03 (MySQL Slave) — 最安全的恢复目标
# 来源: OSS 中最新备份 (或指定 backup_name)
#
# 流程:
#   1. 从 OSS 下载备份
#   2. 停止目标节点 mysqld
#   3. 清空 datadir (重命名旧数据, 不删除)
#   4. xtrabackup --prepare (准备备份)
#   5. xtrabackup --copy-back (恢复到 datadir)
#   6. chown mysql:mysql datadir
#   7. 启动 mysqld
#   8. 重建复制 (GTID auto-positioning)
#   9. 验证: SHOW REPLICA STATUS, 测试查询
#
# 用法:
#   ansible-playbook -i inventory.ini playbooks/05-restore-mysql.yml
#   ansible-playbook -i inventory.ini playbooks/05-restore-mysql.yml \
#     -e backup_name=mysql-full-20260725-020000
```

**Play 1：校验前提** (hosts: localhost, connection: local)
- Assert `mysql_root_password` 已设置
- Assert OSS 变量已设置

**Play 2：列出可用备份** (hosts: node-03, become: true)
- 运行 `ossutil ls oss://k3s-backup-velero/mysql-backups/`
- 注册输出，显示按日期排序的备份列表
- 如未指定 `backup_name`，自动选择最新的

**Play 3：下载 + 准备备份** (hosts: node-03, become: true)
- 创建恢复目录（含 cleanup 步骤，`xbstream` 不覆盖已存在文件）
- 下载：`ossutil cp -f oss://.../{backup_name}.xbstream.gz /tmp/mysql-restore/`（`-f` 防止文件已存在时交互式询问覆盖导致非 TTY 挂起）
- 解压：`gunzip -c ... | xbstream -x -C /tmp/mysql-restore/backup/`
- 准备：`xtrabackup --prepare --target-dir=/tmp/mysql-restore/backup/`
- 验证：`assert` 模块同时检查 stdout **和 stderr**（xtrabackup 的输出在 stderr）

**Play 4：停 MySQL + 清空 datadir** (hosts: node-03, become: true, serial: 1)
- 停止：`systemctl stop mysqld`
- 等待 3306 端口关闭
- **重命名**（不删除）旧数据：`mv /var/lib/mysql /var/lib/mysql.pre-restore.$(date +%s)`
- 创建空目录：`mkdir -p /var/lib/mysql && chown mysql:mysql /var/lib/mysql`

**Play 5：恢复备份** (hosts: node-03, become: true)
- 运行：`xtrabackup --copy-back --target-dir=/tmp/mysql-restore/backup/ --datadir=/var/lib/mysql`（必须显式传入 `--datadir`，`/etc/my.cnf` 无此配置时 xtrabackup 报错退出）
- 验证：同时检查 stdout 和 stderr（`completed OK!` 在 stderr）
- 设置权限：`chown -R mysql:mysql /var/lib/mysql/`

**Play 6：启动 MySQL + 验证** (hosts: node-03, become: true)
- 启动：`systemctl start mysqld`
- 等待 3306 就绪（timeout 60s）
- 验证 root 登录：`SELECT VERSION();`
- 检查数据库：`SHOW DATABASES;`
- 检查短链数据：`SELECT COUNT(*) FROM shortlink.urls;`

**Play 7：重建复制** (hosts: node-03, become: true)
- 检查当前复制状态：`SHOW REPLICA STATUS\G`
- 如未运行，配置（顺序严格）：
  ```sql
  STOP REPLICA;
  RESET REPLICA ALL;            -- 清空备份自带的旧复制元数据（mysql.slave_* 表）
  CHANGE REPLICATION SOURCE TO
    SOURCE_HOST='{{ mysql_master_ip }}',
    SOURCE_USER='{{ mysql_repl_user }}',
    SOURCE_PASSWORD='{{ mysql_repl_password }}',
    SOURCE_AUTO_POSITION=1,
    GET_SOURCE_PUBLIC_KEY=1;
  START REPLICA;
  ```
- 等待 5s，验证 `Replica_IO_Running: Yes` + `Replica_SQL_Running: Yes`

**Play 8：汇总** (hosts: node-03)
- 显示 MySQL 版本、数据库列表、复制状态、记录数

#### 4.3 关键设计点

1. **GTID auto-positioning**：`SOURCE_AUTO_POSITION=1` 使 Slave 自动从 Master 请求正确的 binlog 位置，无需手动定位
2. **备份当前 datadir**：重命名而非删除 `/var/lib/mysql/`，提供恢复失败时的回滚路径
3. **xtrabackup --prepare**：必须在 `--copy-back` 前执行，应用 redo log 使备份一致
4. **serial: 1**：一次只恢复一个节点（本例仅 node-03，但模式与现有 playbook 一致）
5. **RESET REPLICA ALL 必须在 CHANGE 前**：xtrabackup 备份包含 `mysql.slave_master_info` 和 `mysql.slave_relay_log_info` 表，直接 `START REPLICA` 会报 `ERROR 1872 — Replica failed to initialize applier metadata`。必须先 `RESET REPLICA ALL` 清空旧的复制元数据，再重新配置
6. **xtrabackup 输出在 stderr**：`completed OK!` 和进度日志全部输出到标准错误流。Ansible 的 `command` 模块的 `register` 变量同时捕获 stdout 和 stderr，验证条件必须检查 `prepare_result.stdout + prepare_result.stderr`

#### 4.4 注意事项

1. **node-03 停机时间**：恢复期间 MySQL Slave 停机约 5-10 分钟（771M 数据），ProxySQL 将读请求路由到 Master
2. **从 Slave 备份恢复到 Slave**：备份包含 Slave 的 GTID 已执行集，恢复后新 Slave 用 `SOURCE_AUTO_POSITION=1` 连接 Master 自动同步
3. **复制延迟**：恢复后 Slave 需追上备份后的所有变更，使用最新备份可最小化延迟
4. **`--copy-back` vs `--move-back`**：使用 `--copy-back`（保留已准备的备份以便重试）
5. **`ossutil cp -f` 必须**：目标文件已存在时 ossutil 交互式询问 `overwrite? (y or N)?`，Ansible 无 TTY 导致永久挂起。必须加 `-f` 强制覆盖
6. **`xbstream` 不覆盖已存在文件**：如果 backup/ 目录有上一轮残留文件，xbstream 报 `Can't create/write to file '(File exists)'`。每次解压前需清空目标目录（`rm -rf /tmp/mysql-restore/backup/` → 重建）
7. **`--datadir` 参数必须显式传入**：`xtrabackup --copy-back` 读取 my.cnf 确定 datadir。如果 `/etc/my.cnf` 未显式写 `datadir`，报 `datadir must be specified`。虽然 MySQL 默认是 `/var/lib/mysql`，xtrabackup 不会用默认值，必须传 `--datadir=/var/lib/mysql`
8. **Ansible `command` 模块不支持 Shell 重定向**：`mysql ... 2>/dev/null` 中的 `2>/dev/null` 被当作数据库名参数传给 mysql（`Unknown database '2>/dev/null'`）。应去掉 Shell 重定向，改用 `failed_when: false` 处理连接失败
9. **`gather_facts: true` 才能在 `command` 参数中用 `ansible_date_time`**：`ansible_date_time` 是 Ansible facts 变量，`gather_facts: false` 时不可用（`'ansible_date_time' is undefined`）。生成时间戳的场景须开启 fact 收集或用 `lookup('pipe', 'date +%s')`

---

### Step 5：K8s 恢复 (Velero Restore)

**类型**：文档 + kubectl 命令（无新文件）
**依赖**：Step 3（Velero 已安装，有备份）

#### 5.1 参考恢复命令

> 验证见 Step 6

```bash
# 1. 列出可用备份
kubectl get backups -n velero

# 2. 从指定备份创建恢复
kubectl apply -f - <<'EOF'
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: restore-drill
  namespace: velero
spec:
  backupName: daily-backup-20260725
  includedNamespaces:
    - data-layer
    - app-layer
EOF

# 3. 检查恢复状态
kubectl get restore -n velero restore-drill
# 预期: Completed

# 4. 验证恢复的资源
kubectl get pods -n data-layer
kubectl get pods -n app-layer
kubectl get pvc -n data-layer

# 5. 验证 Redis 数据
kubectl exec -n data-layer redis-0 -- redis-cli GET drill:test
# 预期: 备份前设置的值
```

#### 5.2 Redis PVC FSB 恢复流程

1. Velero 重建 PVC（使用 local-path storage class）
2. node-agent 从 OSS 下载 kopia 快照
3. node-agent 恢复卷数据到 PVC
4. Redis StatefulSet Pod 用恢复的数据重建

#### 5.3 注意事项

1. **恢复到同 namespace**：Velero 默认恢复到原 namespace。如资源仍存在，Velero 跳过已存在的资源（除非设 `--existing-resource-policy=update`）
2. **PVC 重建**：删除 `ReclaimPolicy=Delete` 的 PVC 会同时删除 PV 数据 — 这正是演练的目的（测试 Velero 能从 FSB 快照恢复）
3. **local-path PV 调度**：Velero 重建 PVC 时，local-path-provisioner 在剩余空间最大的节点调度。Redis 数据是复制的，节点变化不影响
4. **FSB 恢复时间**：512Mi PVC 的 FSB 恢复 <1 分钟/卷，总时间取决于 OSS 网络速度

---

### Step 6：恢复演练

**类型**：文档（记录在 `docs/phase-7-backup-dr.md` 中）
**依赖**：Step 4 + Step 5

#### 6.1 MySQL 恢复演练

执行

```bash
ssh k3s-node-01
cd /home/ops/ansible
ansible-playbook -i inventory.ini playbooks/05-restore-mysql.yml
```

预期结果：
- MySQL 在 node-03 成功启动
- 所有数据库和表存在
- `shortlink.urls` 表行数与备份前一致
- 复制状态：`Replica_IO_Running: Yes`, `Replica_SQL_Running: Yes`

失败回滚：
```bash
ssh -J k3s-node-01 ops@192.168.1.229

# 清理远程备份的下载/解压文件
sudo rm -rf /tmp/mysql-restore/*
sudo systemctl status mysqld --no-pager

# 本地备份文件恢复
systemctl stop mysqld
mv /var/lib/mysql.pre-restore.<ts> /var/lib/mysql
systemctl start mysqld
```

#### 6.2 K8s 恢复演练

集群操作，通过 node-01 SSH 执行（`kubectl` 不在本地安装）。

**⚠️ 前置条件**：

1. **（node-01为2C4G可忽略此步，2C2G内存不够则做此步）**
   **FluxCD 已缩到 0**：node-01 仅 2GB RAM，备份期间 Velero node-agent 的 kopia 会上传数据到 OSS，内存使用增加 ~100MB，可能触发 OOM Killer。
   
   ```bash
kubectl scale deploy -n flux-system --replicas=0 --all
   ```
   
2. **Redis 备份注解已就位**：`k8s/data-layer/redis-statefulset.yaml` 的 `spec.template.metadata.annotations` 必须包含：

   ```yaml
   annotations:
     backup.velero.io/backup-volumes: redis-data
   ```

3. **Sentinel 已暂停**（可选，恢复时避免 replication 覆盖）：
   ```bash
   kubectl scale sts sentinel -n data-layer --replicas=0
   ```

**Step 1：设置测试数据 + 持久化**：

```bash
# 设置测试数据
kubectl exec -n data-layer redis-0 -- redis-cli SET drill:test "backup-verify-$(date +%s)"
kubectl exec -n data-layer redis-0 -- redis-cli GET drill:test

# ⚠️ 关键：对 ALL Redis Pod 执行 BGREWRITEAOF
# Redis 使用 AOF 持久化（appendonly yes），SET 的数据在内存中，
# 如果不强制刷盘，备份可能捕获到空的 AOF base RDB (88字节)
for pod in redis-0 redis-1 redis-2; do
  kubectl exec -n data-layer $pod -- redis-cli BGREWRITEAOF
done
sleep 3  # 等待 AOF rewrite 完成

# 验证持久化：所有 pod 的 base.rdb 应 > 88 字节（含数据）
for pod in redis-0 redis-1 redis-2; do
  kubectl exec -n data-layer $pod -- ls -la /data/appendonlydir/
done
```

**Step 2：触发备份**：

```bash
kubectl apply -f - <<'EOF'
apiVersion: velero.io/v1
kind: Backup
metadata: { name: drill-backup, namespace: velero }
spec:
  includedNamespaces: [data-layer]
  defaultVolumesToFsBackup: true
  ttl: 1h
EOF

# 等待 Completed（~30s，如果 stuck 超过 2 分钟则重启 Velero pod）
kubectl get backup drill-backup -n velero -w
```

**Step 3：模拟灾难**：删除 Redis StatefulSet + PVC

```bash
kubectl delete statefulset redis -n data-layer --cascade=orphan
kubectl delete pod -n data-layer -l app=redis --force --grace-period=0
kubectl patch pvc -n data-layer -l app=redis -p '{"metadata":{"finalizers":null}}'
kubectl delete pvc -n data-layer -l app=redis
```

**Step 4：恢复**：

```bash
kubectl apply -f - <<'EOF'
apiVersion: velero.io/v1
kind: Restore
metadata: { name: drill-restore, namespace: velero }
spec:
  backupName: drill-backup
  includedNamespaces: [data-layer]
EOF

# ⚠️ 如果 restore controller 卡住（Phase 长时间为空），重启 Velero：
kubectl delete pod -n velero -l app=velero

sleep 15

# ⚠️ 关键：立即缩 Redis STS 到 0，阻止 Pod 启动
# 原因是 Redis 启动时会尝试连接 master（replication），
# 空 master 会覆盖恢复的 AOF 数据
kubectl scale sts redis -n data-layer --replicas=0

# 等待 PodVolumeRestore 完成（至少 1 个 Completed）
kubectl get podvolumerestore -n velero -l velero.io/restore-name=drill-restore -w
```

**Step 5：验证数据（绕过 Redis replication）**：

```bash
# 创建 debug pod 挂载已恢复的 PVC
PVC=$(kubectl get pvc -n data-layer -l app=redis -o name | head -1)
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata: { name: pvc-verify, namespace: data-layer }
spec:
  containers:
  - name: check
    image: busybox
    command: ['sleep', '300']
    securityContext:
      allowPrivilegeEscalation: false
      capabilities: {drop: [ALL]}
      runAsNonRoot: true
      runAsUser: 1000
      seccompProfile: {type: RuntimeDefault}
    volumeMounts:
    - name: data
      mountPath: /mnt
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: $(echo $PVC | cut -d/ -f2)
  restartPolicy: Never
EOF

sleep 8
# 检查 AOF base RDB 文件中的键
kubectl exec -n data-layer pvc-verify -- strings /mnt/appendonlydir/appendonly.aof.*.base.rdb | grep -E 'drill|redis'
# 预期: 应显示 drill:test 和 backup-verify 相关信息

# 清理
kubectl delete pod pvc-verify -n data-layer --force --grace-period=0
```

**Step 6：恢复服务**：

```bash
# 缩回 3 副本
kubectl scale sts redis -n data-layer --replicas=3
# 恢复 Sentinel
kubectl scale sts sentinel -n data-layer --replicas=3
# 恢复 FluxCD
kubectl scale deploy -n flux-system --replicas=1 --all
```

**⚠️ 恢复后注意**：如果 Pod 处于 `Init:ImagePullBackOff`（node-02/03），需删除卡住的 Pod 让 kubelet 重用本地缓存镜像：
```bash
kubectl delete pod -n data-layer -l app=redis --field-selector=status.phase!=Running
```

**Step 7：清理**：

```bash
kubectl exec -n data-layer redis-0 -- redis-cli DEL drill:test 2>/dev/null
kubectl delete backup drill-backup -n velero
kubectl delete restore drill-restore -n velero
```

#### 6.3 2026-07-27 实际演练结果

以下记录了今天演练中发现的**所有陷阱**和最终成功的验证链路。

**环境状态**：
- node-01 2GB RAM，k3s server 756MB + FluxCD ×6 + data-layer pods → 可用 ~200MB
- node-02/03 无公网，containerd 配置 docker.io mirror → daocloud

**发现并修复的问题**：

| # | 问题 | 症状 | 修复 |
|---|------|------|------|
| 1 | **node-agent label 不匹配** | FSB 卷备份全部失败（8 errors） | DaemonSet label 改为 `name=node-agent`（Velero v1.15 硬编码 `labels.Parse("name=node-agent")`） |
| 2 | **node-agent 仅 node-01** | node-02/03 的 PVC 无法备份 | 移除 nodeSelector，ACR 推送镜像使所有节点可拉取 |
| 3 | **Node-01 OOM** | Velero 进程被杀 5 次，backup Failed | FluxCD 缩到 0 释放 ~400MB |
| 4 | **containerd docker.io mirror** | node-02/03 即使镜像已缓存仍尝试拉取 → ImagePullBackOff | 修改 registries.yaml 移除 docker.io mirror，重启 k3s |
| 5 | **Redis AOF 持久化延迟** | 备份捕获空 AOF base RDB（88 字节），恢复后无数据 | 备份前 `BGREWRITEAOF` 所有 pod |
| 6 | **Sentinel 旧 IP** | Redis pod 重建后 IP 变更，Sentinel 读取旧 PVC 数据 → master s_down → replication 断裂 | 恢复时 Sentinel 缩到 0，恢复后 PVC 重置 |
| 7 | **Velero restore controller 卡死** | Restore Phase 长时间为空，无 PodVolumeRestore 创建 | 重启 Velero pod (`kubectl delete pod -l app=velero`) |
| 8 | **Redis replication 覆盖恢复数据** | restore-wait init container 完成后 Redis 启动，slave 连接 master 被覆盖 | STS 缩到 0 阻止启动，debug pod 直接验证 PVC |
| 9 | **restore-wait init container 镜像** | Velero v1.15 无 `--restore-helper-image` flag | 镜像推送到 ACR，ctr 拉取到所有节点，Cached image + pod delete 绕过 |

**最终验证结果**：

| 验证项 | 状态 | 详情 |
|--------|------|------|
| 备份完成 | ✅ | `final-backup` Completed, 413 items, 6 PVBs (含 3×redis-data) |
| PVC 数据恢复 | ✅ | redis-1 PVC PodVolumeRestore 完成，`.velero` 目录 + AOF 文件到位 |
| PVC 数据验证 | ✅ | debug pod 挂载 PVC，`strings` 检查 AOF base RDB 含 `final-demo-ok` |
| AOF 持久化前 | ❌ | 备份捕获 88 字节空 RDB（仅 metadata，无业务数据） |
| AOF 持久化后 | ✅ | 备份捕获 119 字节 RDB（含 `drill:test` → `final-demo-ok`） |
| ImagePullBackOff 绕过 | ✅ | 删除 stuck pod → kubelet 重用本地缓存 → Pod Running |
| Sentinel replication | ❌ | Sentinel 持有旧 Pod IP → `s_down` → slave 无数据 |

**关键结论**：
1. **Velero FSB 备份/恢复链路可用**：备份 → OSS → 恢复 → PVC 数据验证 全部通过
2. **Redis AOF 持久化是必须步骤**：不执行则恢复数据为空
3. **Sentinel 状态管理是独立问题**：与 Velero 备份恢复正交，需单独处理
4. **node-01 内存是长期瓶颈**：2GB 不足以稳定运行备份工作负载

#### 6.4 预期结果

| 演练 | 指标 | 预期 | 通过标准 |
|------|------|------|---------|
| MySQL | 恢复时间 | < 10 分钟 | 10 分钟内完成恢复 |
| MySQL | 数据完整性 | 所有表存在 | `SELECT COUNT(*)` 与备份前一致 |
| MySQL | 复制状态 | IO + SQL 线程运行 | `SHOW REPLICA STATUS\G` 两者都 Yes |
| K8s | 恢复时间 | < 5 分钟 | Restore phase = Completed |
| K8s | Pod 恢复 | 所有 Pod Running | `kubectl get pods -A` 全部 1/1 |
| K8s | Redis 数据 | drill:test 值完好 | `GET drill:test` 返回预期值 |
| K8s | 应用健康 | shortlink 响应 | `curl /health` 返回 ok |

#### 6.4 失败回滚

| 演练 | 失败场景 | 回滚操作 |
|------|---------|---------|
| MySQL | 恢复数据损坏 | 停 mysqld → `mv /var/lib/mysql.pre-restore.<ts> /var/lib/mysql` → 启动 mysqld |
| K8s | 恢复资源冲突 | `kubectl delete ns data-layer app-layer`（如损坏）→ `flux reconcile kustomization data-layer; flux reconcile kustomization app-layer` |
| K8s | Redis 数据丢失 | FSB 恢复失败 = 数据丢失。从最新 Velero 备份重试，或从 GitOps 重建（无数据） |

---

## 5. 受影响文件总览

### 新建文件（14 个）

| 文件路径 | 步骤 | 说明 |
|---------|------|------|
| `ansible/playbooks/04-setup-backup-tools.yml` | Step 2 | xtrabackup + ossutil 安装 + cron 部署 |
| `ansible/playbooks/templates/ossutil-config.j2` | Step 2 | ossutil 配置模板 |
| `ansible/playbooks/05-restore-mysql.yml` | Step 4 | MySQL xtrabackup 恢复 playbook |
| `scripts/xtrabackup-backup.sh` | Step 2 | MySQL 备份脚本（流式 + 推送 OSS） |
| `k8s/velero/namespace.yaml` | Step 3 | Velero namespace + ResourceQuota |
| `k8s/velero/rbac.yaml` | Step 3 | ServiceAccount + ClusterRoleBinding |
| `k8s/velero/deployment.yaml` | Step 3 | Velero server Deployment + AWS 插件 init container |
| `k8s/velero/node-agent-daemonset.yaml` | Step 3 | node-agent DaemonSet (FSB/kopia) |
| `k8s/velero/bsl-oss.yaml` | Step 3 | BackupStorageLocation (OSS S3 兼容) |
| `k8s/velero/schedule.yaml` | Step 3 | Velero Schedule (每日 02:30) |
| `k8s/velero/cloud-credentials.example` | Step 3 | OSS 凭证脱敏模板 |
| `k8s/velero/kustomization.yaml` | Step 3 | Kustomize base |
| `clusters/production/velero.yaml` | Step 3 | FluxCD Kustomization CR |
| `docs/phase-7-backup-dr.md` | Step 7 | Phase 7 文档（本文档） |

### 修改文件（6 个）

| 文件路径 | 步骤 | 变更内容 |
|---------|------|---------|
| `ansible/group_vars/all.yml` (gitignored) | Step 1 | 添加 OSS 凭证变量 |
| `ansible/group_vars/all.yml.example` | Step 1 | 添加 OSS 凭证脱敏模板 |
| `.gitignore` | Step 3 | 添加 `k8s/velero/cloud-credentials` |
| `k8s/data-layer/redis-statefulset.yaml` | Step 3 | 添加 `backup.velero.io/backup-volumes: redis-data` 注解 |
| `README.md` | Step 7 | Phase 7 状态更新 |
| `.workbuddy/memory/MEMORY.md` | Step 7 | 进度更新 |

### Git 提交历史（实施修复记录）

```
cba0d84 fix: xtrabackup 改用 /root/.my.cnf 认证 (避免 command-line 默认密码覆盖)
1a3a1ab fix: OSS PutObject 兼容性 — 添加 checksumAlgorithm "" 禁用 AWS 未签名 Payload
a16eb76 fix: OSS 需要 virtual hosted style (s3ForcePathStyle=false)
d281701 fix: Velero server args 修正, 移除 v2 CLI 不存在 flags
42ae84d fix: Velero 主容器添加 command + node-agent 挂载路径修正
0897294 fix: Velero init 容器 mountPath 改为 /target (避免覆盖镜像 /plugins)
37c31bb fix: Velero/node-agent pin node-01 (image pull) + 修复 node-agent entrypoint
```

## 6. 实施顺序与依赖关系

```
Step 1: OSS 基础设施 (手动) ─────────────────────┐
         │                                       │
         ├──► Step 2: xtrabackup ──► Step 4: MySQL 恢复
         │         (Ansible + 脚本)       (Ansible playbook)
         │                                       │
         └──► Step 3: Velero GitOps ──► Step 5: K8s 恢复
                   (K8s manifests)         (kubectl 命令)
                                                    │
                                                    v
                                       Step 6: 恢复演练
                                                    │
                                                    v
                                       Step 7: 文档 + 提交
```

**关键依赖**：
- Step 2 和 Step 3 可并行（都依赖 Step 1，互不依赖）
- Step 4 依赖 Step 2（需要 xtrabackup 已安装 + 有备份）
- Step 5 依赖 Step 3（需要 Velero 已安装 + 有备份）
- Step 6 依赖 Step 4 + Step 5（两种恢复都可用）
- Step 7 依赖所有步骤完成

## 7. 风险与注意事项

| # | 风险 | 影响 | 缓解措施 |
|---|------|------|---------|
| 1 | Velero FSB node-agent 需在所有节点运行 | FSB 无法备份/恢复 PVC | DaemonSet 确保 3 节点全覆盖 |
| 2 | local-path PV 在 `/var/lib/rancher/k3s/storage/` | node-agent 需访问此路径 | hostPath 挂载 + `mountPropagation: HostToContainer` |
| 3 | Velero OSS 插件用 AWS 插件 | 需正确配置 S3 兼容端点 | `s3Url` + `s3ForcePathStyle=false`（OSS 强制 virtual hosted style）+ `checksumAlgorithm=""`（禁用 AWS 无符号 Payload） |
| 4 | xtrabackup 版本兼容 | PXB 8.0.x 需支持 MySQL 8.0.46 | 安装 PXB 8.0.35+，验证 `xtrabackup --version` |
| 5 | 从 Slave 备份用 `--no-lock` | Slave 只读时安全 | `super_read_only=ON` 保证无写入 |
| 6 | ossutil 配置位置 | root cron job 需读取配置 | 配置文件在 `/root/.ossutilconfig` |
| 7 | Velero 镜像拉取 | `velero/velero` 在 Docker Hub | registries.yaml 已镜像到 daocloud |
| 8 | Redis StatefulSet 注解 | 必须用精确 PVC 卷名 | `backup.velero.io/backup-volumes: redis-data` |
| 9 | Velero Schedule 时区 | 默认 UTC = 北京时间 +8h | 添加 `velero.io/timezone: Asia/Shanghai` 注解 |
| 10 | Velero CRD 手动安装 | 打破纯 GitOps | Velero 标准实践，CRD 很少更新 |
| 11 | node-02/03 无公网 | RPM 下载需经 node-01 | 同 Phase 3 airgap 模式 |
| 12 | Velero server 在 node-01 | node-01 仅 2GB，备份时峰值 ~1.4GB | 备份前缩 FluxCD 到 0；长期考虑升级 node-01 到 4GB |
| 13 | `--copy-back` 保留备份 | 占用额外磁盘空间 | 恢复验证后清理 `/tmp/mysql-restore/` |
| 14 | GTID auto-positioning | 恢复后自动重建复制 | `SOURCE_AUTO_POSITION=1`，无需手动定位 binlog |
| 15 | OSS Lifecycle Rule | 7 天自动删除 | 必须配置，否则备份无限增长 |
| 16 | `command: ["/velero"]` 必填 | 镜像无 `ENTRYPOINT`，Pod CrashLoopBackOff | Deployment 和 DaemonSet 都需显式 `command` |
| 17 | `--uploader-type=kopia` 需显式指定 | 未来版本默认 uploader 可能变更 | 在 server args 中显式声明 |
| 18 | `--use-volume-snapshots` 等非 server 参数 | `velero install` CLI 参数混入 server args 导致 Pod 启动失败 | BSL CRD 管理 bucket/prefix/config，server 只接受 `--default-volumes-to-fs-backup` 和 `--uploader-type` |
| 19 | node-agent 挂载路径硬编码 `/host_pods` | mountPath 不匹配导致 FSB 无法读取 PVC 数据 | 必须使用 `/host_pods` 而非 `/var/lib/kubelet/pods` |
| 20 | init 容器 mountPath 须用 `/target` | 镜像内 `plugins` 目录有内容，`/plugins` 覆盖后插件不加载 | 使用 `/target` 避免覆盖已有内容 |
| 21 | root@localhost TCP 认证失败 | xtrabackup 走 DBI (TCP)，root@localhost 用 `caching_sha2_password` 只能 Unix socket | 创建 `root@127.0.0.1` + `mysql_native_password`，`/root/.my.cnf` 设 `host=127.0.0.1` |
| 22 | node-agent label `app=node-agent` | Velero v1.15 `IsRunningInNode()` 硬编码 `name=node-agent` 查找 Pod | DaemonSet 的 `spec.selector.matchLabels` 和 `spec.template.metadata.labels` 都设为 `name=node-agent` |
| 23 | Node-01 OOM (2GB RAM) | k3s server 756MB + FluxCD 6 controller + Redis/Sentinel/ProxySQL/Orch → 可用 ~200MB，kopia 备份触发 OOM Killer | 备份前 `kubectl scale deploy -n flux-system --replicas=0 --all` |
| 24 | containerd mirror 忽略本地缓存 | node-02/03 registries.yaml 设 docker.io mirror → daocloud，即使镜像已 `ctr images pull` 到本地，kubelet 仍尝试拉取 → ImagePullBackOff | 移除 `docker.io` mirror，重启 k3s |
| 25 | Redis AOF 数据未刷盘 | `appendonly yes` 模式下，`SET` 的数据异步写入 AOF，备份可能捕获空文件 | 备份前在所有 pod 执行 `BGREWRITEAOF`，检查 `base.rdb` 大小 > 88 字节 |
| 26 | Sentinel 旧 IP | Pod 重建后 IP 变更，Sentinel PVC 中存储的 master IP 过期 → `s_down` → replication 断裂 | 恢复时 Sentinel 缩到 0 或重置 PVC |
| 27 | Restore controller 间歇卡死 | Velero pod 的 restore controller 停止处理新 Restore CR（Phase 为空无进度） | `kubectl delete pod -n velero -l app=velero` 重启 |
| 28 | restore-wait init container 镜像不可配置 | Velero v1.15 无 `--restore-helper-image` flag，镜像 `velero/velero-restore-helper:v1.15.0` 硬编码 | ACR 推送镜像 + `ctr` 预拉到各节点；卡住时删 pod 触发缓存重用 |

## 8. 备份前后对比

| 维度 | 备份前 | 备份后 |
|------|--------|--------|
| MySQL 备份 | 无 | xtrabackup 每日全量，推送 OSS |
| K8s 备份 | 无 | Velero 每日备份资源 + Redis PVC (FSB) |
| 异地容灾 | 无 | 阿里云 OSS (S3 兼容, 7 天保留) |
| 恢复能力 | 无 | MySQL (Ansible playbook) + K8s (Velero restore) |
| 恢复演练 | 无 | MySQL + K8s 双演练验证 |
| 数据安全 | PV ReclaimPolicy=Delete 无兜底 | Velero FSB 备份 Redis PVC |
| GitOps 管理 | app-layer + data-layer | + velero (新增 Kustomization CR) |

