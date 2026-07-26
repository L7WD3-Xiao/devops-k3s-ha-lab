# Phase 7：备份容灾

## 1. 概述

为 K3s HA 集群建立完整的备份与灾难恢复体系，覆盖"集群级"和"数据级"两个维度：

- **MySQL（物理机级）**：Percona XtraBackup 全量备份，流式压缩，推送阿里云 OSS
- **K8s 资源 + Redis PVC（集群级）**：Velero + File System Backup (kopia)，后端 OSS (S3 兼容)
- **恢复演练**：MySQL (xtrabackup --copy-back via Ansible) + K8s (Velero restore)

**状态：计划已就绪，待执行**

| 配置项 | 值 |
|--------|-----|
| 存储后端 | 阿里云 OSS (cn-hangzhou, S3 兼容) |
| 保留策略 | 7 天（OSS Lifecycle Rule 自动清理） |
| MySQL 备份时间 | 每日 02:00 (Asia/Shanghai) |
| K8s 备份时间 | 每日 02:30 (Asia/Shanghai, xtrabackup 之后) |
| 预估月费用 | ~¥0.84（标准存储 LRS ¥0.12/GB/月, 7 天总量 ~7GB） |

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
| node-01 资源最小 (2C2G) | 已跑 FluxCD 6 controller，内存紧张 | Velero server 调度到 node-02 (2C4G) |
| node-02/03 无公网 | RPM 下载需经 node-01 中转 | 同 Phase 3 airgap 模式：node-01 下载 → scp → 安装 |
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
MYSQL_PASSWORD="${MYSQL_PASSWORD:-CHANGE_ME}"
BACKUP_DIR="${BACKUP_DIR:-/data/backups/mysql}"
OSS_BUCKET="${OSS_BUCKET:-k3s-backup-velero}"
OSS_PREFIX="${OSS_PREFIX:-mysql-backups}"
OSSUTIL_BIN="${OSSUTIL_BIN:-/usr/local/bin/ossutil}"
OSS_ENDPOINT="${OSS_ENDPOINT:-oss-cn-hangzhou-internal.aliyuncs.com}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
DATE="$(date +%Y%m%d-%H%M%S)"
BACKUP_NAME="mysql-full-${DATE}"
BACKUP_FILE="${BACKUP_DIR}/${BACKUP_NAME}.xbstream.gz"

# ── Pre-flight checks ────────────────────────────────────────
# 检查 xtrabackup / ossutil 二进制
# 检查 MySQL 连通性: mysqladmin ping
# 检查磁盘空间 (可用 < 5G 时告警)
# 创建 $BACKUP_DIR

# ── Backup ────────────────────────────────────────────────────
# 流式备份直接写入压缩文件 (无中间暂存)
# --slave-info: 记录 relay log 位置 (replica 备份)
# --no-lock: Slave 只读 (super_read_only=ON), 安全无需锁

echo "--- Starting xtrabackup: ${BACKUP_NAME} ---"
xtrabackup --backup \
  --stream=xbstream \
  --user="${MYSQL_USER}" \
  --password="${MYSQL_PASSWORD}" \
  --slave-info \
  --no-lock \
  | gzip > "${BACKUP_FILE}"

# ── Verify backup ─────────────────────────────────────────────
# 检查文件大小 > 0
# (跳过 --prepare 以加速; 恢复时再 prepare)

# ── Push to OSS ───────────────────────────────────────────────
echo "--- Uploading to OSS: ${OSS_BUCKET}/${OSS_PREFIX}/ ---"
"${OSSUTIL_BIN}" cp "${BACKUP_FILE}" \
  "oss://${OSS_BUCKET}/${OSS_PREFIX}/$(basename "${BACKUP_FILE}")" \
  -e "${OSS_ENDPOINT}"

# ── Cleanup old local backups ─────────────────────────────────
# 保留本地最近 2 份 (快速恢复), OSS Lifecycle Rule 处理远端 7 天清理
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
# 手动运行备份
ssh -J k3s-node-01 ops@192.168.1.229 "sudo /usr/local/bin/xtrabackup-backup.sh"

# 检查本地备份文件
ssh -J k3s-node-01 ops@192.168.1.229 "ls -lh /data/backups/mysql/"

# 检查 OSS 上传
ossutil ls oss://k3s-backup-velero/mysql-backups/

# 验证备份完整性 (prepare 测试)
ssh -J k3s-node-01 ops@192.168.1.229 "sudo bash -c \
  'gunzip -c /data/backups/mysql/mysql-full-*.xbstream.gz | xbstream -x -C /tmp/xbtest && \
   xtrabackup --prepare --target-dir=/tmp/xbtest'"
```

#### 2.6 注意事项

1. **xtrabackup 版本兼容**：PXB 8.0.35+ 支持 MySQL 8.0.46，安装后验证 `xtrabackup --version`
2. **node-03 无公网**：RPM 经 node-01 下载后 scp 传输，同 Phase 3 airgap 模式
3. **`--no-lock` 安全性**：Slave 有 `super_read_only=ON` 防止写入，`--no-lock` 安全；Master 上则不可用
4. **磁盘空间**：771M 数据压缩后约 100-200M，`/data/backups/mysql/` 需 ~1G（保留 2 份）
5. **cron 用户**：以 `root` 运行（xtrabackup 需 root 读取 MySQL 数据文件）
6. **ossutil 配置**：必须在 `/root/.ossutilconfig`（root cron job 读取位置）

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
| 镜像来源 | Docker Hub `velero/velero`（通过 daocloud 镜像拉取） |
| 备份模式 | FSB (File System Backup / kopia) |
| 调度节点 | node-02 (2C4G，比 node-01 宽裕) |

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
# 预期: backups.velero.io, backupstoragelocations.velero.io, schedules.velero.io, etc.
```

> **注意**：CRD 不纳入 GitOps 是 Velero 标准实践 — CRD 很少更新，放入 Kustomize 会增加 ~2000 行 YAML。

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
    pod-security.kubernetes.io/enforce: baseline
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

> PSS = `baseline`：node-agent DaemonSet 需要 hostPath + runAsUser: 0，`restricted` 会拒绝。

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
        kubernetes.io/hostname: node-02    # 调度到 2C4G 节点
      initContainers:
        - name: velero-plugin-for-aws      # 拷贝 S3 插件到 /plugins
          image: velero/velero-plugin-for-aws:v1.11.0
          volumeMounts:
            - name: plugins
              mountPath: /plugins
      containers:
        - name: velero
          image: velero/velero:v1.15.0
          args:
            - server
            - --default-volumes-to-fs-backup=true    # FSB 默认 (无 CSI 快照)
            - --use-volume-snapshots=false            # 禁用 CSI 快照
            - --backup-location-config=region=cn-hangzhou,s3ForcePathStyle=true,s3Url=https://oss-cn-hangzhou-internal.aliyuncs.com
            - --bucket=k3s-backup-velero
            - --prefix=velero-backups
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
  template:
    spec:
      serviceAccountName: velero
      securityContext:
        runAsUser: 0    # FSB 需 root 访问 hostPath PV 数据
      containers:
        - name: node-agent
          image: velero/velero:v1.15.0
          args: [server, --node-agent, --log-level=info]
          env:
            - name: NODE_NAME
              valueFrom: { fieldRef: { fieldPath: spec.nodeName } }
            - name: VELERO_NAMESPACE
              valueFrom: { fieldRef: { fieldPath: metadata.namespace } }
          volumeMounts:
            - name: host-pods              # kubelet pods 目录 — PVC 挂载点
              mountPath: /var/lib/kubelet/pods
              mountPropagation: HostToContainer
            - name: host-storage           # K3s local-path PV 存储目录
              mountPath: /var/lib/rancher/k3s/storage
              mountPropagation: HostToContainer
            - name: scratch                # kopia 临时空间
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
- `/var/lib/rancher/k3s/storage` 是 K3s local-path-provisioner 存储 PV 数据的路径
- `mountPropagation: HostToContainer` 确保 node-agent 能看到 kubelet 运行时挂载的卷
- 没有 `mountPropagation`，FSB 将无法访问 PVC 数据

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
    s3ForcePathStyle: "true"
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
    metadata:
      annotations:
        velero.io/timezone: Asia/Shanghai
    includedNamespaces:
      - data-layer
      - app-layer
    defaultVolumesToFsBackup: true        # FSB 备份所有 PVC (redis-data)
    ttl: 168h0m0s                         # 7 天 = 7 × 24h
    storageLocation: default
```

> **时区陷阱**：Velero Schedule 默认使用 UTC。`30 2 * * *` 在 UTC 下 = 北京时间 10:30。必须添加 `velero.io/timezone: Asia/Shanghai` 注解。

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

# 检查 OSS 中的备份对象
ossutil ls oss://k3s-backup-velero/velero-backups/
```

#### 3.8 注意事项

1. **Velero 镜像拉取**：`velero/velero:v1.15.0` 在 Docker Hub，registries.yaml 已镜像 `docker.io` → `docker.m.daocloud.io`，所有节点应能拉取。如 daocloud 未镜像，走 airgap：node-01 拉取 → 导出 tarball → scp → K3s 自动导入
2. **node-agent hostPath**：`/var/lib/rancher/k3s/storage` 是 K3s 特有路径，如 K3s 数据目录不同需调整。验证：`ssh node-03 'ls /var/lib/rancher/k3s/storage/'`
3. **Velero server 在 node-02**：node-02 跑 MySQL Master (771M + 256M buffer pool)，Velero 增加 ~128-512M RAM，4G 内存应够。如 OOM 则迁移到 node-03
4. **CRD 不在 Git**：CRD 手动安装，打破纯 GitOps 模型，但这是 Velero 标准实践
5. **Schedule 时区**：默认 UTC，必须添加 `velero.io/timezone: Asia/Shanghai` 注解
6. **defaultVolumesToFsBackup vs 注解**：Schedule 设 `true`（备份所有 PVC via FSB），StatefulSet 注解显式声明意图，两者保留

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
- 创建临时目录：`/tmp/mysql-restore/`
- 下载：`ossutil cp oss://.../{backup_name}.xbstream.gz /tmp/mysql-restore/`
- 解压：`gunzip -c ... | xbstream -x -C /tmp/mysql-restore/backup/`
- 准备：`xtrabackup --prepare --target-dir=/tmp/mysql-restore/backup/`
- 显示结果（应显示 "completed OK!"）

**Play 4：停 MySQL + 清空 datadir** (hosts: node-03, become: true, serial: 1)
- 停止：`systemctl stop mysqld`
- 等待 3306 端口关闭
- **重命名**（不删除）旧数据：`mv /var/lib/mysql /var/lib/mysql.pre-restore.$(date +%s)`
- 创建空目录：`mkdir -p /var/lib/mysql && chown mysql:mysql /var/lib/mysql`

**Play 5：恢复备份** (hosts: node-03, become: true)
- 运行：`xtrabackup --copy-back --target-dir=/tmp/mysql-restore/backup/`
- 设置权限：`chown -R mysql:mysql /var/lib/mysql/`

**Play 6：启动 MySQL + 验证** (hosts: node-03, become: true)
- 启动：`systemctl start mysqld`
- 等待 3306 就绪（timeout 60s）
- 验证 root 登录：`SELECT VERSION();`
- 检查数据库：`SHOW DATABASES;`
- 检查短链数据：`SELECT COUNT(*) FROM shortlink.urls;`

**Play 7：重建复制** (hosts: node-03, become: true)
- 检查当前复制状态：`SHOW REPLICA STATUS\G`
- 如未运行，配置：
  ```sql
  STOP REPLICA;
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

#### 4.4 验证

```bash
# 运行 playbook
ansible-playbook -i ansible/inventory.ini ansible/playbooks/05-restore-mysql.yml

# 手动验证
ssh -J k3s-node-01 ops@192.168.1.229 \
  "mysql -u root -p'MyRoot@2026!' -e 'SHOW REPLICA STATUS\G' 2>/dev/null"
# 预期: Replica_IO_Running: Yes, Replica_SQL_Running: Yes

ssh -J k3s-node-01 ops@192.168.1.229 \
  "mysql -u root -p'MyRoot@2026!' -e 'SELECT COUNT(*) FROM shortlink.urls;' 2>/dev/null"
# 预期: 与备份前相同的行数
```

#### 4.5 注意事项

1. **node-03 停机时间**：恢复期间 MySQL Slave 停机约 5-10 分钟（771M 数据），ProxySQL 将读请求路由到 Master
2. **从 Slave 备份恢复到 Slave**：备份包含 Slave 的 GTID 已执行集，恢复后新 Slave 用 `SOURCE_AUTO_POSITION=1` 连接 Master 自动同步
3. **复制延迟**：恢复后 Slave 需追上备份后的所有变更，使用最新备份可最小化延迟
4. **`--copy-back` vs `--move-back`**：使用 `--copy-back`（保留已准备的备份以便重试）

---

### Step 5：K8s 恢复 (Velero Restore)

**类型**：文档 + kubectl 命令（无新文件）
**依赖**：Step 3（Velero 已安装，有备份）

#### 5.1 恢复命令

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

1. 执行 `ansible-playbook -i inventory.ini playbooks/05-restore-mysql.yml`
2. 预期结果：
   - MySQL 在 node-03 成功启动
   - 所有数据库和表存在
   - `shortlink.urls` 表行数与备份前一致
   - 复制状态：`Replica_IO_Running: Yes`, `Replica_SQL_Running: Yes`
3. 失败回滚：
   ```bash
   systemctl stop mysqld
   mv /var/lib/mysql.pre-restore.<ts> /var/lib/mysql
   systemctl start mysqld
   ```

#### 6.2 K8s 恢复演练

1. **设置测试数据**：
   ```bash
   kubectl exec -n data-layer redis-0 -- \
     redis-cli SET drill:test "backup-verify-$(date +%s)"
   ```

2. **触发备份**：
   ```bash
   kubectl apply -f - <<'EOF'
   apiVersion: velero.io/v1
   kind: Backup
   metadata: { name: drill-backup, namespace: velero }
   spec:
     includedNamespaces: [data-layer, app-layer]
     defaultVolumesToFsBackup: true
     ttl: 1h
   EOF
   ```
   等待 `PHASE = Completed`

3. **模拟灾难**：删除 Redis StatefulSet + PVC
   ```bash
   kubectl delete statefulset redis -n data-layer
   kubectl delete pvc redis-data-redis-0 redis-data-redis-1 redis-data-redis-2 -n data-layer
   ```

4. **恢复**：
   ```bash
   kubectl apply -f - <<'EOF'
   apiVersion: velero.io/v1
   kind: Restore
   metadata: { name: drill-restore, namespace: velero }
   spec:
     backupName: drill-backup
     includedNamespaces: [data-layer]
   EOF
   ```
   等待 `PHASE = Completed`

5. **验证**：
   ```bash
   kubectl get pods -n data-layer -l app=redis
   kubectl exec -n data-layer redis-0 -- redis-cli GET drill:test
   # 预期: backup-verify-<timestamp>
   curl http://116.62.168.245/health
   # 预期: {"status":"ok"}
   ```

6. **清理**：
   ```bash
   kubectl exec -n data-layer redis-0 -- redis-cli DEL drill:test
   kubectl delete backup drill-backup -n velero
   kubectl delete restore drill-restore -n velero
   ```

#### 6.3 预期结果

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

### Step 7：文档 + 提交

**类型**：文档 + Git 操作
**依赖**：所有前序步骤

1. 完善 `docs/phase-7-backup-dr.md`（本文档）
2. 更新 `README.md` 路线图（Phase 7 → 已完成）
3. 更新 `.workbuddy/memory/MEMORY.md`
4. Git commit

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
| 3 | Velero OSS 插件用 AWS 插件 | 需正确配置 S3 兼容端点 | `s3Url` + `s3ForcePathStyle=true` |
| 4 | xtrabackup 版本兼容 | PXB 8.0.x 需支持 MySQL 8.0.46 | 安装 PXB 8.0.35+，验证 `xtrabackup --version` |
| 5 | 从 Slave 备份用 `--no-lock` | Slave 只读时安全 | `super_read_only=ON` 保证无写入 |
| 6 | ossutil 配置位置 | root cron job 需读取配置 | 配置文件在 `/root/.ossutilconfig` |
| 7 | Velero 镜像拉取 | `velero/velero` 在 Docker Hub | registries.yaml 已镜像到 daocloud |
| 8 | Redis StatefulSet 注解 | 必须用精确 PVC 卷名 | `backup.velero.io/backup-volumes: redis-data` |
| 9 | Velero Schedule 时区 | 默认 UTC = 北京时间 +8h | 添加 `velero.io/timezone: Asia/Shanghai` 注解 |
| 10 | Velero CRD 手动安装 | 打破纯 GitOps | Velero 标准实践，CRD 很少更新 |
| 11 | node-02/03 无公网 | RPM 下载需经 node-01 | 同 Phase 3 airgap 模式 |
| 12 | Velero server 在 node-02 | 与 MySQL Master 共享资源 | 2C4G 应够；如 OOM 迁移到 node-03 |
| 13 | `--copy-back` 保留备份 | 占用额外磁盘空间 | 恢复验证后清理 `/tmp/mysql-restore/` |
| 14 | GTID auto-positioning | 恢复后自动重建复制 | `SOURCE_AUTO_POSITION=1`，无需手动定位 binlog |
| 15 | OSS Lifecycle Rule | 7 天自动删除 | 必须配置，否则备份无限增长 |

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

## 9. 下一步

- Phase 8：文档整理（README、架构文档、部署手册）
