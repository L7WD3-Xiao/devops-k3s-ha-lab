# Phase 4 准备：阿里云 ACR 镜像仓库配置

> 日期：2026-07-21
> 状态：配置文件已就绪，凭证已填入（脱敏模板已入库）
> 前置文档：[phase-3-data-layer.md](phase-3-data-layer.md)（数据层部署）

---

## 1. 方案选型

### 1.1 为什么用 ACR 而不是自建 Harbor

| 维度 | 阿里云 ACR 个人版 | 自建 Harbor |
|------|------------------|-------------|
| 费用 | **免费** | 需额外 ECS + 存储 |
| 运维 | 零运维 | 需维护 Harbor 实例 |
| 可用性 | 阿里云 SLA 保证 | 自负可用性 |
| VPC 集成 | 原生 VPC 内网拉取 | 需额外配置 |
| 安全扫描 | 个人版不支持 | 支持 Trivy 集成 |

项目定位是校招简历级基础设施项目，ACR 个人版免费且零运维，是最优选择。

### 1.2 个人版 vs 企业版

| 维度 | 个人版 (免费) | 企业版 (~¥19/月) |
|------|-------------|-----------------|
| Namespace | 3 个 | 不限 |
| 仓库数 | 50 个 | 不限 |
| 认证 | 固定账号密码 | RAM 用户/临时凭证 |
| VPC 内网拉取 | **支持** | 支持 |
| 镜像安全扫描 | 不支持 | 支持 |
| 跨 Region 同步 | 不支持 | 支持 |

**选择个人版**——3 个 namespace、50 个仓库对这个项目绰绰有余，VPC 内网拉取同样支持。

### 1.3 新个人版 vs 旧个人版域名格式

> **重要**：2024-09-09 后创建的个人版实例使用 `crpi-` 开头的独占域名，不再使用 `registry` 开头的共享域名。

| 类型 | 新个人版 (本项目) | 旧个人版 |
|------|-------------------|---------|
| 公网 | `crpi-{id}.{region}.personal.cr.aliyuncs.com` | `registry.{region}.aliyuncs.com` |
| VPC | `crpi-{id}-vpc.{region}.personal.cr.aliyuncs.com` | `registry-vpc.{region}.aliyuncs.com` |

**新个人版的额外限制**：
- **不支持公网域名拉取镜像**——K3s 必须用 VPC 域名
- **不支持匿名拉取**——必须配置认证
- **仅允许一个 RAM 子账号设置登录密码**

---

## 2. 网络设计

### 2.1 VPC 域名 vs 公网域名

本项目 ACR 实例的两个域名：

```
公网:  crpi-vvz6iv4av6k8awep.cn-hangzhou.personal.cr.aliyuncs.com       ← 本地推送（开发机）
VPC:   crpi-vvz6iv4av6k8awep-vpc.cn-hangzhou.personal.cr.aliyuncs.com   ← K3s 拉取（ECS 内网，免费）
```

**3 台 ECS 和 ACR 都在 cn-hangzhou region，K3s 用 VPC 域名**，零流量费且延迟更低。

> **注意**：新个人版不支持公网域名拉取镜像，所以 K3s 必须使用 VPC 域名。
> 公网域名仅用于本地开发机推送镜像。

### 2.2 镜像命名规范

```
# 推送时（从本地开发机，走公网）
crpi-vvz6iv4av6k8awep.cn-hangzhou.personal.cr.aliyuncs.com/shortlink123/shortlink-app:v1

# 拉取时（K3s 集群，走 VPC 内网，免费）
crpi-vvz6iv4av6k8awep-vpc.cn-hangzhou.personal.cr.aliyuncs.com/shortlink123/shortlink-app:v1
```

> 同一个镜像在 ACR 中只有一份存储，公网域名和 VPC 域名指向同一个 manifest。
> 本地推送用公网域名（开发机不在 VPC 内），K3s 拉取用 VPC 域名。

---

## 3. 认证方式

### 3.1 个人版认证机制

个人版使用**固定账号密码**（不是阿里云账号密码，也不是 RAM 临时凭证）：

- **Username**：阿里云账号全名（如 `xxx@aliyun.com`）或 RAM 子账号
- **Password**：在 ACR 控制台「访问凭证」页面单独设置的固定密码

### 3.2 K3s 集成方式——registries.yaml

本项目选择 **registries.yaml 方式**（而非 imagePullSecret），原因：

| 方式 | 原理 | 适合场景 |
|------|------|---------|
| **registries.yaml** (本项目) | containerd 级别全局配置 | 单一镜像仓库，全局生效 |
| imagePullSecret | K8s Secret，per-namespace | 多仓库、多租户隔离 |

registries.yaml 方式的优势：
- 全局生效，所有 Deployment 无需添加 `imagePullSecrets` 字段
- 配置在基础设施层，应用 YAML 更干净
- 3 个节点统一管理，通过 Ansible 分发

---

## 4. 配置文件

### 4.1 Ansible 变量 (`ansible/group_vars/all.yml`)

> **凭证脱敏**：`all.yml` 包含密码，已加入 `.gitignore`，不入版本控制。
> 脱敏模板见 `ansible/group_vars/all.yml.example`。

```yaml
# VPC 域名（K3s 拉取用，免费）
acr_registry: "crpi-vvz6iv4av6k8awep-vpc.cn-hangzhou.personal.cr.aliyuncs.com"
# 公网域名（本地推送用）
acr_registry_public: "crpi-vvz6iv4av6k8awep.cn-hangzhou.personal.cr.aliyuncs.com"
acr_namespace: "shortlink123"
acr_repository: "shortlink-app"
acr_username: "<your-username>"   # 阿里云账号或 RAM 子账号
acr_password: "<your-password>"   # ACR 控制台设置的固定密码
```

### 4.2 registries.yaml 模板 (`ansible/playbooks/templates/registries.yaml.j2`)

```yaml
mirrors:
  docker.io:
    endpoint:
      - "https://docker.m.daocloud.io"
      - "https://registry-1.docker.io"
  gcr.io:
    endpoint:
      - "https://gcr.m.daocloud.io"
  quay.io:
    endpoint:
      - "https://quay.m.daocloud.io"

configs:
  "crpi-vvz6iv4av6k8awep-vpc.cn-hangzhou.personal.cr.aliyuncs.com":
    auth:
      username: <acr_username>
      password: <acr_password>
```

- `mirrors` 段保持原有 Docker Hub 镜像加速配置
- `configs` 段新增 ACR VPC 域名的认证信息
- K3s containerd 自动使用 `configs` 中的凭证拉取私有镜像

### 4.3 Ansible Playbook (`ansible/playbooks/03-configure-acr.yml`)

```bash
# 执行 ACR 配置（需先填入凭证）
ansible-playbook -i inventory.ini playbooks/03-configure-acr.yml
```

Playbook 执行流程：
1. **验证**：检查 `acr_username` 和 `acr_password` 非空
2. **分发**：将 registries.yaml 推送到 3 个节点（serial=1，逐节点执行）
3. **滚动重启**：每次重启一个节点的 K3s 服务，等待节点重新 Ready 后继续下一个
4. **验证**：从每个节点 curl ACR VPC 端点，确认连通性

### 4.4 镜像构建推送脚本 (`scripts/build-push.sh`)

```bash
# 构建并推送 v1 版本
./scripts/build-push.sh v1

# 不使用缓存构建
./scripts/build-push.sh v1 --no-cache
```

脚本会自动：
1. `docker login` 到 ACR 公网域名
2. `docker build` 构建镜像
3. `docker tag` 打上 ACR 远程标签
4. `docker push` 推送到 ACR

---

## 5. 操作步骤

### Step 1 阿里云控制台手动操作（约 5 分钟）

1. **开通 ACR 个人版**
   - 阿里云控制台 → 容器镜像服务 → 个人版 → 开启
   - 选择 Region：华东1（杭州）

2. **设置访问凭证**
   - 容器镜像服务 → 访问凭证 → 设置固定密码
   - 这个密码与阿里云账号密码不同，是 ACR 专用密码

3. **创建 Namespace**
   - 个人版 → 命名空间 → 创建
   - 名称：`shortlink123`
   - Region：华东1（杭州）

4. **创建镜像仓库**
   - 个人版 → 镜像仓库 → 创建
   - 命名空间：`shortlink123`
   - 仓库名称：`shortlink-app`
   - 类型：**私有**
   - 代码源：不绑定（手动构建推送）

### Step 2 填入凭证并执行配置

```bash
# 1. 从脱敏模板创建本地配置
cp ansible/group_vars/all.yml.example ansible/group_vars/all.yml
vim ansible/group_vars/all.yml
# 填入 acr_username 和 acr_password（以及 MySQL 等其他密码）

# 2. 执行 Ansible playbook
cd /home/ops/ansible
ansible-playbook -i inventory.ini playbooks/03-configure-acr.yml

# 3. 验证 K3s 可以拉取 ACR 镜像（先推送一个测试镜像hello-world）
docker login crpi-vvz6iv4av6k8awep.cn-hangzhou.personal.cr.aliyuncs.com
docker pull hello-world
docker tag hello-world crpi-vvz6iv4av6k8awep.cn-hangzhou.personal.cr.aliyuncs.com/shortlink123/shortlink-app:test
docker push crpi-vvz6iv4av6k8awep.cn-hangzhou.personal.cr.aliyuncs.com/shortlink123/shortlink-app:test

# 4. 在 K3s 中拉取测试（用 VPC 域名）
kubectl run acr-test --image=crpi-vvz6iv4av6k8awep-vpc.cn-hangzhou.personal.cr.aliyuncs.com/shortlink123/shortlink-app:test
kubectl logs acr-test
kubectl delete pod acr-test
```

---

## 6. 注意事项

### 6.1 常见坑

| 问题 | 原因 | 解决 |
|------|------|------|
| `401 Unauthorized` | 凭证错误或未配置 | 检查 registries.yaml 的 auth 段 |
| `403 Forbidden` | 新个人版不支持匿名拉取 | 确保仓库类型为「私有」+ auth 配置 |
| 拉取超时/不可达 | 新个人版不支持公网域名拉取 | K3s 镜像地址必须用 `-vpc` 域名 |
| K3s 未加载新配置 | registries.yaml 改后未重启 | `systemctl restart k3s` |
| 本地推送失败 | 用了 VPC 域名（本地不在 VPC） | 本地推送用公网域名（不带 `-vpc`） |
| `ctr image pull` 401 | ctr 不继承 K3s 代理环境变量 | 显式传 `--user` 或依赖 registries.yaml |

### 6.2 安全建议

- `registries.yaml` 权限设为 `0600`（仅 root 可读）
- `group_vars/all.yml` 包含密码，**已加入 `.gitignore`**，不入版本控制
- 脱敏模板 `all.yml.example` 入库，真实配置仅本地保留
- ACR 仓库类型选「私有」，防止镜像泄露
- 定期更换 ACR 固定密码

### 6.3 与 Phase 2 镜像代理的关系

| 场景 | 方案 | 状态 |
|------|------|------|
| 公共镜像（Docker Hub） | daocloud 镜像 + SSH 隧道代理 fallback | Phase 2 已配置 |
| 私有镜像（ACR） | VPC 内网直连 + registries.yaml auth | Phase 4 本文档 |

两者互不冲突，registries.yaml 中 `mirrors` 段处理公共镜像加速，`configs` 段处理 ACR 私有认证。

---

