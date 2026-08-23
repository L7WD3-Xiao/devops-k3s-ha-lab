# Phase 3.5：阿里云 ACR 镜像仓库配置

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

项目定位是校招简历级基础设施项目，ACR 个人版免费且零运维，是最优选择。

### 1.2 个人版 vs 企业版

| 维度 | 个人版 (免费) | 企业版 (~¥19/月) |
|------|-------------|-----------------|
| Namespace | 3 个 | 不限 |
| 仓库数 | 50 个 | 不限 |
| 认证 | 固定账号密码 | RAM 用户/临时凭证 |
| VPC 内网拉取 | **支持** | 支持 |
| 镜像安全扫描 | 不支持 ACR 原生扫描 | 支持 |
| 跨 Region 同步 | 不支持 | 支持 |

**选择个人版**——3 个 namespace、50 个仓库对这个项目绰绰有余，VPC 内网拉取同样支持。

> **个人版**不支持 ACR 原生扫描，但可集成 Trivy。[详见phase-5-CI/CD篇](phase-5-cicd.md)

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
公网:  crpi-{id}.cn-hangzhou.personal.cr.aliyuncs.com       ← 本地推送（开发机）
VPC:   crpi-{id}-vpc.cn-hangzhou.personal.cr.aliyuncs.com   ← K3s 拉取（ECS 内网，免费）
```

**3 台 ECS 和 ACR 都在 cn-hangzhou region，K3s 用 VPC 域名**，零流量费且延迟更低。

> **注意**：新个人版不支持公网域名拉取镜像，所以 K3s 必须使用 VPC 域名。
> 公网域名仅用于本地开发机推送镜像。

### 2.2 镜像命名规范

```
# 推送时（从本地开发机，走公网）
crpi-{id}.cn-hangzhou.personal.cr.aliyuncs.com/shortlink123/shortlink-app:v1

# 拉取时（K3s 集群，走 VPC 内网，免费）
crpi-{id}-vpc.cn-hangzhou.personal.cr.aliyuncs.com/shortlink123/shortlink-app:v1
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

## 4. 实施步骤（4 步）

> 执行顺序严格按依赖关系排列：控制台操作必须最先完成，凭证就绪后才能分发配置，配置生效后才能端到端验证。

```
Step 1: ACR 控制台 ──────► 开通个人版 + 设置凭证 + 创建 Namespace + 仓库
    │
    ▼
Step 2: Ansible 变量 ────► 从模板创建 all.yml，填入 ACR 凭证
    │
    ▼
Step 3: Playbook 分发 ───► 分发 registries.yaml + 滚动重启 K3s（串行 3 节点）
    │
    ▼
Step 4: 端到端验证 ──────► 本地推镜像 → K3s VPC 拉取 → Pod 运行
```

---

### Step 1: 阿里云控制台操作

**目标**：开通 ACR 个人版，设置访问凭证，创建 Namespace 和镜像仓库。

1. **开通 ACR 个人版**
   - 阿里云控制台 → 容器镜像服务 → 个人版 → 开启
   - 选择 Region：华东1（杭州）

2. **设置访问凭证**
   - 容器镜像服务 → 访问凭证 → 设置固定密码
   - 此密码与阿里云账号密码不同，是 ACR 专用密码

3. **创建 Namespace**
   - 个人版 → 命名空间 → 创建
   - 名称：`shortlink123`
   - Region：华东1（杭州）

4. **创建镜像仓库**
   - 个人版 → 镜像仓库 → 创建
   - 命名空间：`shortlink123`
   - 仓库名称：`shortlink-app`
   - 类型：**私有**（新个人版不支持匿名拉取，必须私有）
   - 代码源：不绑定（手动构建推送）

**验证**：
```bash
# 确认控制台显示 Namespace shortlink123 和仓库 shortlink-app
# 确认访问凭证已设置（记住此密码，Step 2 需要）
```

---

### Step 2: 配置 Ansible 变量

**目标**：将 ACR 凭证填入 Ansible 变量文件，供后续 Playbook 分发使用。

**涉及文件**：

| 文件 | 操作 | 说明 |
|------|------|------|
| `ansible/group_vars/all.yml` | 从模板创建 | 包含密码，**已加入 `.gitignore`** |
| `ansible/group_vars/all.yml.example` | 已入库 | 脱敏模板 |

**变量内容**：
```yaml
# VPC 域名（K3s 拉取用，免费·低延迟）
acr_registry: "crpi-{id}-vpc.cn-hangzhou.personal.cr.aliyuncs.com"
# 公网域名（本地开发机推送用）
acr_registry_public: "crpi-{id}.cn-hangzhou.personal.cr.aliyuncs.com"
acr_namespace: "shortlink123"
acr_repository: "shortlink-app"
acr_username: "<your-username>"   # 阿里云账号或 RAM 子账号
acr_password: "<your-password>"   # Step 1 设置的固定密码
```

**域名说明**：

| 域名 | 用途 | 流量费 |
|------|------|--------|
| `crpi-...-vpc....`（VPC） | K3s 拉取镜像 | 免费（同 Region 内网） |
| `crpi-...`（公网） | 本地推送镜像 | 按量计费 |

> ⚠️ 新个人版**不支持公网域名拉取镜像**——K3s 必须使用 `-vpc` 域名。公网域名仅用于本地开发机推送。

**验证**：
```bash
# 确保 all.yml 已加入 .gitignore，不会误提交
grep "all.yml" .gitignore   # 应包含 ansible/group_vars/all.yml
```

---

### Step 3: 分发 registries.yaml 并滚动重启 K3s

**目标**：通过 Ansible playbook将 ACR 认证配置分发到 3 个节点，containerd 加载后能拉取私有镜像。

**涉及文件**：

| 文件 | 操作 | 说明 |
|------|------|------|
| `ansible/playbooks/templates/registries.yaml.j2` | 新建 | Jinja2 模板，含 mirrors + configs 段 |
| `ansible/playbooks/03-configure-acr.yml` | 新建 | Ansible Playbook，分发 + 滚动重启 |

**registries.yaml 模板**（Jinja2 模板，变量由 all.yml 注入）：

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
  "{{ acr_registry }}":         # ← Jinja2 变量，渲染为 VPC 域名
    auth:
      username: {{ acr_username }}
      password: {{ acr_password }}
```

- `mirrors` 段保持 Phase 2 已配置的 Docker Hub 镜像加速
- `configs` 段新增 ACR VPC 域名的认证信息
- K3s containerd 自动使用 `configs` 中的凭证拉取私有镜像

**Playbook 执行流程**：
1. **验证**：检查 `acr_username` 和 `acr_password` 非空
2. **分发**：将 registries.yaml 推送到 3 个节点（`serial=1`，逐节点执行）
3. **滚动重启**：每次重启一个节点的 K3s 服务，等待节点重新 Ready 后继续下一个
4. **验证**：从每个节点 curl ACR VPC 端点，确认连通性

**与 Phase 2 镜像代理的关系**：
公共镜像与私有镜像两套方案互不冲突——`mirrors` 段处理 Docker Hub 等公共镜像加速，`configs` 段处理 ACR 私有认证，同在一个文件中。

**验证**：
```bash
ssh k3s-node-01

# 分发 registries.yaml
cd /home/ops/ansible
ansible-playbook -i inventory.ini playbooks/03-configure-acr.yml

# 检查各节点 registries.yaml 已生成
sudo cat /etc/rancher/k3s/registries.yaml | grep -A3 configs

# 检查 K3s 已重启且节点 Ready
sudo /usr/local/bin/k3s kubectl get nodes

# 验证 VPC 端点可达
curl -I https://crpi-{id}-vpc.cn-hangzhou.personal.cr.aliyuncs.com/v2/
```

---

### Step 4: 端到端验证

**目标**：完整走一遍推送 → 拉取 → 运行链路，确认 ACR 配置在 K3s 集群中生效。

> 使用 hello-world 镜像测试，给一个 shortlink-app:test 的 tag

```bash
# 1. 本地推送测试镜像（走公网）
docker pull hello-world
docker tag hello-world crpi-{id}.cn-hangzhou.personal.cr.aliyuncs.com/shortlink123/shortlink-app:test
docker push crpi-{id}.cn-hangzhou.personal.cr.aliyuncs.com/shortlink123/shortlink-app:test

# 2. K3s 用 VPC 域名拉取（免费·内网）
ssh k3s-node-01
sudo /usr/local/bin/k3s kubectl run acr-test --image=crpi-{id}-vpc.cn-hangzhou.personal.cr.aliyuncs.com/shortlink123/shortlink-app:test"

# 3. 确认 Pod 运行
sudo /usr/local/bin/k3s kubectl get pods acr-test

# 4. 查看日志
sudo /usr/local/bin/k3s kubectl logs acr-test

# 5. 清理测试 Pod
sudo /usr/local/bin/k3s kubectl delete pod acr-test
```

**验证指标**：

| 检查项 | 预期结果 |
|--------|---------|
| Pod 状态 | Running（非 ImagePullBackOff / ErrImagePull） |
| 拉取耗时 | < 10s（VPC 内网，零流量费） |
| 公网推送 | 成功（本地开发机） |
| VPC 拉取 | 成功（K3s 节点，使用 registries.yaml 凭证） |

---

## 5. 注意事项

### 5.1 常见坑

| 问题 | 原因 | 解决 |
|------|------|------|
| `401 Unauthorized` | 凭证错误或未配置 | 检查 registries.yaml 的 auth 段 |
| `403 Forbidden` | 新个人版不支持匿名拉取 | 确保仓库类型为「私有」+ auth 配置 |
| 拉取超时/不可达 | 用了公网域名而非 VPC 域名 | K3s 镜像地址必须用 `-vpc` 域名 |
| K3s 未加载新配置 | registries.yaml 改后未重启 | `systemctl restart k3s` |
| 本地推送失败 | 用了 VPC 域名（本地不在 VPC） | 本地推送用公网域名（不带 `-vpc`） |
| `ctr image pull` 401 | ctr 不继承 K3s 代理环境变量 | 显式传 `--user` 或依赖 registries.yaml |

### 5.2 安全建议

- `registries.yaml` 权限设为 `0600`（仅 root 可读）
- `group_vars/all.yml` 包含密码，**已加入 `.gitignore`**，不入版本控制
- 脱敏模板 `all.yml.example` 入库，真实配置仅本地保留
- ACR 仓库类型选「私有」，防止镜像泄露
- 定期更换 ACR 固定密码

### 5.3 关键设计决策

| 领域 | 决策 | 理由 |
|------|------|------|
| 认证方式 | registries.yaml（而非 imagePullSecret） | 全局生效，应用 YAML 更干净，配合 Ansible 统一管理 |
| 域名策略 | 公网推送 + VPC 拉取 | 同一镜像一份存储，两端域名不同但指向同一 manifest |
| 个人版类型 | 新个人版（crpi- 域名） | 2024-09 后新创建实例均为新格式，不支持公网拉取 |

