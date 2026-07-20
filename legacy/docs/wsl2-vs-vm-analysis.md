# WSL2 部署 K3s 踩坑记录 & 方案对比：WSL2 vs VM 桥接

> 生成时间：2026-07-19
> 背景：在 WSL2 三节点环境上部署 K3s 集群过程中遇到的一系列问题，最终导致架构从 HA（3 server embedded etcd）降级为 1 server + 2 agents，且 agent 仍无法正常启动。

---

## 一、踩坑全记录

### 坑 1：WSL2 共享网络命名空间（根本性问题）

**现象**：WSL2 的所有 distro（Ubuntu 实例）共享同一个网络命名空间——`127.0.0.1` 和 `0.0.0.0` 在所有 distro 之间是同一个地址。这意味着一个 distro 绑定了 `127.0.0.1:PORT`，其他 distro 就无法绑定同一端口。

**影响范围**：这是导致 K3s HA 不可用、agent 无法启动的**根本原因**。具体触发了以下连锁问题：

| 组件 | 绑定地址 | 冲突说明 |
|------|---------|---------|
| K3s Server Supervisor | `127.0.0.1:6444` | node-01 server 绑定后，node-02/03 的 server 或 agent LB 无法绑定 |
| K3s Embedded etcd | `127.0.0.1:2379` | 多个 server 节点的 etcd 客户端无法共存 |
| K3s Agent Load Balancer | `127.0.0.1:6444` | agent 的客户端负载均衡器与 server supervisor 端口冲突 |
| containerd Streaming Server | `127.0.0.1:10010` | 每个节点的 containerd 都尝试绑定，第二个起全部失败 |

**尝试过的绕行方案及结果**：

| 方案 | 结果 | 原因 |
|------|------|------|
| 设置 `supervisor-port: 6445` | ❌ 失败 | K3s 总是额外创建 `127.0.0.1:6444` 监听器，显式设置会导致重复绑定（K3s bug） |
| 设置 `etcd-arg: listen-client-urls=https://NODE_IP:2379` | ❌ 失败 | K3s 仍连接 `127.0.0.1:2379`（硬编码，不可配置） |
| config.yaml 中 `disable-apiserver-lb: true` | ✅ 部分解决 | agent 不再绑定 `127.0.0.1:6444`，但 containerd streaming server 仍冲突 |
| 自定义 containerd 配置修改 `stream_server_address` | 未尝试 | 需要为每个节点创建不同的 containerd 配置，维护成本高 |

**结论**：WSL2 共享 `127.0.0.1` 是架构级限制，K3s 多个组件硬编码绑定 loopback 地址，无法通过配置完全规避。

---

### 坑 2：K3s supervisor-port 配置项有 bug

**现象**：在 config.yaml 中设置 `supervisor-port: 6445` 后，K3s 报错：
```
failed to listen on 127.0.0.1:6444: bind: address already in use
```

**根因**：K3s 内部始终在 `127.0.0.1:6444` 创建一个 supervisor 监听器（硬编码），config.yaml 中的 `supervisor-port` 会导致创建**第二个**监听器，两者冲突。

**影响**：此 bug 使得无法通过改端口来绕行 WSL2 共享 loopback 的问题，直接导致 HA 方案不可行。

---

### 坑 3：K3s `*-arg` 配置格式要求

**现象**：config.yaml 中 `kube-proxy-arg`、`kube-controller-manager-arg` 等字段使用映射（map）格式时，K3s 解析失败：
```
unknown flag: --[{bind-address 192.168.50.11}]
```

**错误写法**：
```yaml
kube-proxy-arg:
  bind-address: "192.168.50.11"
```

**正确写法**：
```yaml
kube-proxy-arg:
  - "bind-address=192.168.50.11"
```

**影响**：调试过程中浪费了大量时间排查这个格式问题。

---

### 坑 4：K3s Embedded etcd 硬编码 `127.0.0.1:2379`

**现象**：在首节点 config.yaml 中设置 `etcd-arg: listen-client-urls=https://192.168.50.11:2379`，K3s 仍尝试连接 `127.0.0.1:2379`，连接被拒绝。

**根因**：K3s 的 embedded etcd 客户端连接地址硬编码为 `127.0.0.1:2379`，`etcd-arg` 只能修改 etcd **监听**地址，不能修改 K3s **连接**地址。

**影响**：在 WSL2 环境下，多个 server 节点的 etcd 无法区分，HA 模式彻底不可行。

---

### 坑 5：GitHub 下载不稳定

**现象**：K3s 安装脚本 `curl -sfL https://get.k3s.io | sh -` 在 agent 节点上频繁失败：
```
[INFO]  Downloading hash https://github.com/k3s-io/k3s/releases/download/v1.36.2%2Bk3s1/sha256sum-amd64.txt
[ERROR]  Download failed
```

**环境**：`curl -sI https://github.com` 返回 HTTP 200（GitHub 可达），但 releases 下载的 302 跳转到 `objects.githubusercontent.com` 经常超时。

**解决方案**：从已安装的 node-01 复制 K3s 二进制到 agent 节点，然后使用 `INSTALL_K3S_SKIP_DOWNLOAD=true` 跳过下载：
```bash
# Ansible task: copy binary from node-01
- name: Copy K3s binary from node-01
  copy:
    src: /usr/local/bin/k3s
    dest: /usr/local/bin/k3s
    mode: '0755'

# Install with skip download
curl -sfL https://get.k3s.io | K3S_URL=... K3S_TOKEN=... INSTALL_K3S_SKIP_DOWNLOAD=true sh -
```

---

### 坑 6：架构被迫降级

**原计划**：3 节点 K3s HA（embedded etcd），每个节点都是 server + control-plane。

**实际结果**：因 WSL2 共享 loopback 导致 K3s HA 不可行，降级为 **1 server + 2 agents** 架构。

| 对比项 | 原计划（HA） | 实际（降级） |
|--------|-------------|-------------|
| 节点角色 | 3 × server | 1 server + 2 agents |
| Control-plane HA | ✅ 3 副本 | ❌ 单点故障 |
| etcd | ✅ 3 成员 Raft | ❌ 无（SQLite 单文件） |
| 简历亮点 | 高可用架构 | 基础集群部署 |
| 简历含金量 | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ |

---

### 坑 7：iptables / nftables 工具缺失

**现象**：K3s 安装日志提示：
```
[INFO]  Host iptables-save/iptables-restore tools not found
[INFO]  Host ip6tables-save/ip6tables-restore tools not found
```

**影响**：K3s 的网络策略（NetworkPolicy）和 Service 负载均衡可能无法正常工作。WSL2 的 Ubuntu 26.04 默认使用 nftables，但 K3s 期望 iptables。

**解决方案**：需要手动安装 `iptables`（在 Phase 1 的 Ansible Playbook 中已处理）。

---

### 坑 8：systemd 状态为 degraded

**现象**：所有节点的 systemd 状态为 `degraded`（而非 `running`）。

**原因**：WSL2 的 systemd 支持是通过 `/etc/wsl.conf` 中的 `[boot] systemd=true` 实现的，并非原生 systemd。某些系统服务在 WSL2 中无法正常启动（如 `multipathd`、`packagekit` 等），导致整体状态为 degraded。

**影响**：K3s 的 `systemctl is-system-running` 检查需要放宽到接受 `degraded` 状态。

---

### 坑 9：containerd Streaming Server 端口冲突（当前阻塞项）

**现象**：K3s agent 的 containerd 启动后立即退出：
```
level=fatal msg="Failed to run CRI service" error="stream server error: listen tcp 127.0.0.1:10010: bind: address already in use"
```

**根因**：containerd CRI 插件的 streaming server（用于 `kubectl exec`/`logs`/`port-forward`）默认绑定 `127.0.0.1:10010`。由于 WSL2 共享 loopback，node-01 的 containerd 已占用该端口，node-02/03 无法绑定。

**可能的解决方案**：

| 方案 | 可行性 | 复杂度 |
|------|--------|--------|
| 为每个 agent 创建自定义 containerd 配置，修改 `stream_server_address` 为节点 IP | 可行 | 中等 — 需要模板化 containerd 配置 |
| 为每个 agent 设置不同的 `stream_server_port` | 可行 | 中等 — 需要按节点分配端口 |
| 放弃 WSL2，改用 VM | 根治 | 高 — 需要重建环境 |

**当前状态**：此问题尚未解决，agent 节点无法加入集群。

---

## 二、问题根因分析

所有问题的根源可以用一句话概括：

> **WSL2 的所有 distro 共享同一个网络命名空间（loopback 接口），而 K3s 及其依赖组件（etcd、containerd）大量硬编码绑定 `127.0.0.1`，两者叠加导致多节点部署时端口冲突无法避免。**

```
┌─────────────────────────────────────────────────────────────┐
│                    Windows Host                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │              WSL2 共享网络命名空间                      │   │
│  │                                                      │   │
│  │  127.0.0.1:6444  ← K3s Server Supervisor (node-01)   │   │
│  │  127.0.0.1:6444  ← K3s Agent LB (node-02) ✗ 冲突!    │   │
│  │  127.0.0.1:6444  ← K3s Agent LB (node-03) ✗ 冲突!    │   │
│  │  127.0.0.1:10010 ← containerd Stream (node-01)       │   │
│  │  127.0.0.1:10010 ← containerd Stream (node-02) ✗冲突! │   │
│  │  127.0.0.1:10010 ← containerd Stream (node-03) ✗冲突! │   │
│  │  127.0.0.1:2379  ← K3s etcd (node-01)                │   │
│  │  127.0.0.1:2379  ← K3s etcd (node-02) ✗ 冲突!        │   │
│  │                                                      │   │
│  │  node-01 (192.168.50.11) ──┐                         │   │
│  │  node-02 (192.168.50.12) ──┤ IP 别名在同一 eth0 上    │   │
│  │  node-03 (192.168.50.13) ──┘ 但 loopback 是共享的!    │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

即使通过 IP 别名（192.168.50.1X）区分了节点身份，loopback 地址的共享仍然是不可逾越的障碍。K3s 的组件在设计时假设每个节点有独立的 loopback，这在 WSL2 中不成立。

---

## 三、方案对比：继续 WSL2 vs 切换 VM 桥接

### 方案 A：继续使用 WSL2（打补丁路线）

**思路**：逐一为每个 WSL2 限制寻找绕行方案，逐步打补丁。

需要解决的遗留问题：

| 问题 | 绕行方案 | 工作量 | 风险 |
|------|---------|--------|------|
| containerd streaming port 冲突 | 为每个 agent 生成自定义 containerd 配置，设置不同 `stream_server_port` | 中 | 后续可能还有其他组件绑定 loopback |
| agent LB port 冲突 | `disable-apiserver-lb: true`（已解决） | 低 | — |
| HA 不可用 | 接受 1 server + 2 agents 架构 | 无 | server 单点故障 |
| GitHub 下载不稳定 | 从 server 节点复制二进制（已解决） | 低 | — |
| 未来未知冲突 | 未知 | 未知 | K3s 升级可能引入新的 loopback 绑定 |

**优点**：
- 环境已搭建完成（Phase 1 投入不浪费）
- 轻量，不额外消耗内存（WSL2 共享 Windows 内核）
- 与 Windows 文件系统天然集成（`/mnt/d/` 直接访问项目文件）

**缺点**：
- 架构降级：只能 1 server + 2 agents，无 HA，简历含金量降低
- 持续踩坑：每解决一个 loopback 冲突，可能冒出新的
- 不接近生产环境：真实 K8s 集群不会遇到这些问题
- 隐患不可控：K3s 版本升级可能引入新的硬编码 loopback 绑定

---

### 方案 B：切换到 VM + 桥接网络（重建路线）

**思路**：使用 Hyper-V 或 VirtualBox 创建 3 台独立 VM，配置桥接网络，每台 VM 拥有独立的网络命名空间。

**环境规划**：

```
┌──────────────────────────────────────────────────────────────────┐
│                        Windows Host                               │
│                                                                   │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐              │
│  │  VM node-01  │  │  VM node-02  │  │  VM node-03  │             │
│  │ 192.168.50.11│  │ 192.168.50.12│  │ 192.168.50.13│             │
│  │ 独立 loopback│  │ 独立 loopback│  │ 独立 loopback│             │
│  │ 独立 eth0    │  │ 独立 eth0    │  │ 独立 eth0    │             │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘             │
│         │                 │                 │                     │
│         └────────┬────────┴────────┬────────┘                     │
│                  │  桥接交换机      │                              │
│                  └────────┬────────┘                              │
│                           │                                       │
│                    物理网卡 (Wi-Fi/Ethernet)                       │
└──────────────────────────────────────────────────────────────────┘
```

**VM 技术选型**：

| 选项 | 优点 | 缺点 | 推荐度 |
|------|------|------|--------|
| **Hyper-V** (Windows 内置) | 无需额外安装、性能好、与 WSL2 共存 | 配置稍复杂 | ⭐⭐⭐⭐⭐ |
| VirtualBox | 界面友好、跨平台 | 性能略差、与 Hyper-V 冲突 | ⭐⭐⭐ |
| VMware Workstation | 功能丰富 | 收费、与 Hyper-V 冲突 | ⭐⭐ |

> **推荐 Hyper-V**：Windows 10/11 Pro 内置，与现有 WSL2 不冲突（可以共存），性能最优。

**资源需求**：

| 资源 | 每台 VM | 3 台合计 | 当前宿主机假设 |
|------|---------|---------|--------------|
| CPU | 2 vCPU | 6 vCPU | 8 核以上 |
| 内存 | 2 GB | 6 GB | 16 GB 以上 |
| 磁盘 | 10 GB | 30 GB | 充足 |
| 网络 | 桥接模式 | — | — |

**优点**：
- **完全独立的网络命名空间**：每台 VM 有自己的 `127.0.0.1`，彻底解决所有 loopback 端口冲突
- **支持 K3s HA**：3 server + embedded etcd，真正的高可用架构
- **接近生产环境**：VM 的网络模型与云服务器一致，操作经验可迁移
- **IP 固定**：桥接模式下可设置静态 IP，重启后不变
- **systemd 完美支持**：VM 中运行完整 Linux 内核，systemd 状态为 `running`
- **简历含金量高**：HA 架构 + 标准网络模型，面试时更有说服力

**缺点**：
- **重建工作**：需要重新创建 3 台 VM、配置 SSH、重跑 Ansible
- **资源占用高**：每台 VM 独立内存，合计 6GB+（WSL2 共享内核更省）
- **Phase 1 投入**：WSL2 环境搭建的脚本和时间部分浪费（Ansible Playbook 可复用）

---

### 综合对比

| 维度 | 方案 A：继续 WSL2 | 方案 B：切换 VM 桥接 |
|------|-------------------|---------------------|
| **当前进度** | Phase 1 完成，Phase 2 阻塞中 | 需从 Phase 1 重新开始 |
| **预估剩余工作量** | 1-2 天（打补丁 + 踩新坑） | 2-3 天（建 VM + 跑 Playbook） |
| **架构天花板** | 1 server + 2 agents（无 HA） | 3 server HA（embedded etcd） |
| **简历含金量** | ⭐⭐⭐ 基础集群 | ⭐⭐⭐⭐⭐ HA 集群 + 生产级网络 |
| **技术债** | 高 — 持续绕行 WSL2 限制 | 低 — 标准方案 |
| **可扩展性** | 差 — 无法加 server 节点 | 好 — 可随时加节点 |
| **生产可迁移性** | 低 — WSL2 特殊性太多 | 高 — 与云服务器一致 |
| **资源消耗** | 低（~4GB 内存） | 中（~6-8GB 内存） |
| **Ansible 复用** | ✅ Playbook 完全复用 | ✅ Playbook 完全复用（改 inventory IP） |
| **后续 Phase 影响** | 每个新组件都可能踩 WSL2 坑 | 无额外限制 |
| **风险可控性** | 低 — 未知坑不可预测 | 高 — 标准方案，问题可搜索 |

---

## 四、推荐方案

### 推荐：方案 B — 切换到 Hyper-V VM + 桥接网络

**理由**：

1. **根本问题不可治**：WSL2 共享 loopback 是架构级限制，K3s 的 loopback 硬编码无法通过配置规避。继续打补丁只是延缓问题，不是解决问题。

2. **简历价值**：本项目的核心目标是"校招简历级别的 K8s 集群项目"。1 server + 2 agents 的非 HA 架构在面试中说服力有限；而 3 server HA + embedded etcd 才是真正有技术含量的方案。

3. **沉没成本可控**：Phase 1 的 Ansible Playbook、inventory 结构、角色定义等**完全可以复用**，只需修改 inventory 中的 IP 地址和 SSH 连接方式。真正需要重做的只是 VM 创建和基础网络配置。

4. **后续 Phase 更顺畅**：Phase 3（MySQL 主从）、Phase 4（Redis HA）、Phase 5（短链服务）都需要稳定的集群基础。在 WSL2 上每个 Phase 都可能遇到新的 loopback 冲突，而在 VM 上则一劳永逸。

5. **资源充足**：现代开发机通常 16GB+ 内存，Hyper-V 的动态内存分配可以让 3 台 VM 在 6GB 左右运行，完全可行。

### 迁移计划

如果决定切换，建议按以下步骤进行：

```
Step 1: 创建 3 台 Hyper-V VM（Ubuntu 22.04/24.04 Server）
        ├── 配置桥接网络（External Virtual Switch）
        ├── 分配静态 IP：192.168.50.11/12/13
        └── 每台 2vCPU / 2GB RAM / 20GB Disk

Step 2: 基础初始化（复用 Phase 1 Ansible Playbook）
        ├── 创建 ops 用户 + SSH 密钥
        ├── 关闭 swap
        ├── 安装基础工具（curl, iptables, etc.）
        └── Ansible 免密配置

Step 3: 部署 K3s HA（恢复原 Phase 2 计划）
        ├── 3 server + embedded etcd
        ├── serial: 1 逐个加入
        └── 验证 etcd 健康 + 3 节点 Ready

Step 4: 继续 Phase 3+ 不变
```

> Phase 1 的 Ansible Playbook（`00-init-base.yml`）几乎可以原样复用，只需将 `inventory.ini` 中的连接方式从 WSL2 改为 VM SSH。

---

## 五、附：WSL2 踩坑时间线

| 阶段 | 问题 | 耗时 | 结果 |
|------|------|------|------|
| 初始设计 | 设计 3 server HA + embedded etcd | — | 方案合理 |
| 首次部署 | `*-arg` 配置格式错误 | ~1h | 修复为字符串列表 |
| 二次部署 | etcd 连接 `127.0.0.1:2379` 被拒绝 | ~2h | 发现 K3s 硬编码 |
| 三次部署 | `supervisor-port: 6444` 端口冲突 | ~2h | 发现 K3s bug |
| 架构决策 | 放弃 HA，改为 1 server + 2 agents | — | 降级方案 |
| 四次部署 | node-01 server 成功 | ✅ | — |
| 五次部署 | agent 缺少 `K3S_URL`，以 server 模式启动 | ~30min | 添加环境变量 |
| 六次部署 | GitHub 下载失败 | ~1h | 改用本地复制 |
| 七次部署 | agent LB 绑定 `127.0.0.1:6444` 冲突 | ~1h | `disable-apiserver-lb: true` |
| 八次部署 | containerd streaming `127.0.0.1:10010` 冲突 | ~30min | **当前阻塞** |
| **合计** | — | **~8h+** | 仍未完成 |

> 这 8+ 小时中，绝大部分时间花在了排查 WSL2 特有的 loopback 共享问题上。如果使用 VM，这些问题根本不会出现。
