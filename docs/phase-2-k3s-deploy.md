# Phase 2: K3s 3-Server HA 集群部署

> 日期：2026-07-19（部署） / 2026-07-21（代理兜底）
> 状态：已完成
> 前置文档：[phase-1-plan.md](phase-1-plan.md)（Terraform IaC 基础设施）

---

## 1. 概述

### 1.1 目标

在 Phase 1 创建的 3 台阿里云 ECS 上，使用 **Ansible** 部署 **K3s 3-Server HA 集群**（embedded etcd），作为短链服务的容器编排平台。

### 1.2 架构

```
                        ┌─────────────────────────────────────────┐
                        │            K3s HA Cluster               │
                        │         (embedded etcd HA)              │
                        │                                         │
   Internet             │  node-01          node-02    node-03   │
   ──────────────► EIP  │  192.168.1.228    .230       .229      │
                        │  server+etcd      server+etcd server+etcd│
                        │  worker           worker     worker    │
                        └────────────┬────────────────────────────┘
                                     │
                          Ansible 控制节点 (node-01)
                          ansible-playbook 执行点
```

| 特性 | 值 |
|------|-----|
| K8s 发行版 | K3s v1.36.2+k3s1 |
| HA 模式 | 3-Server + embedded etcd |
| 网络插件 | Flannel (K3s 内置) |
| 数据存储 | embedded etcd (3 副本) |
| API Server | `https://<集群公网入口IP>:6443` |
| Ingress | Traefik (K3s 内置) |

### 1.3 产出物

| 产出 | 路径 | 说明 |
|------|------|------|
| Ansible 项目 | `ansible/` | inventory + group_vars + 2 个 playbook + 模板 |
| K3s 集群 | 阿里云 ECS | 3 节点 Ready，etcd HA |
| kubeconfig | `kubeconfig.yaml`（本机，.gitignore） | 外部 kubectl 访问 |
| kubeconfig 模板 | `kubeconfig.yaml.example` | 脱敏模板（入库） |
| 本文档 | `docs/phase-2-k3s-deploy.md` | 你正在看的这个 |

---

## 2. 前置条件

### 2.1 基础设施（Phase 1 产出）

- ✅ 3 台 ECS 已创建，cloud-init 完成（ops 用户 + SSH 密钥 + 基础包）
- ✅ node-01 绑定 EIP (<集群公网入口IP>)，可从本机 SSH 访问
- ✅ 3 节点内网互通（192.168.1.0/24）
- ✅ node-02/03 无公网 IP（通过 node-01 分发二进制和镜像）

### 2.2 SSH 配置

本机 `~/.ssh/config` 已配置：

```sshconfig
Host k3s-node-01
    HostName <集群公网入口IP>
    User ops
    IdentityFile ~/.ssh/id_rsa

Host k3s-node-01-proxy
    HostName <集群公网入口IP>
    User ops
    IdentityFile ~/.ssh/id_rsa
    RemoteForward 8888 127.0.0.1:7897
    ServerAliveInterval 30
    ServerAliveCountMax 3
    ExitOnForwardFailure yes
```

### 2.3 Ansible 控制节点（node-01）

node-01 既是集群节点，也是 Ansible 控制节点。安装方式：

```bash
# EPEL 的 ansible-community 包不完整（缺 ansible-core 命令）
# 改用 python3.11 pip 安装
sudo python3.11 -m pip install ansible-core
```

> **坑**：Alibaba Cloud Linux 3 的 EPEL 仓库里有 `ansible` 包，但安装后没有 `ansible-playbook` 命令。原因是 EPEL 只装了 `ansible-community` 框架，缺少 `ansible-core`。用 `python3.11 -m pip install ansible-core` 直接装最可靠。

---

## 3. 部署流程

### 3.1 Ansible 项目结构

```
ansible/
├── ansible.cfg                          # 配置（python 解释器指定 3.11）
├── inventory.ini                        # 3 节点 inventory
├── group_vars/
│   └── all.yml                          # 全局变量（IP、包、K3s 配置）
└── playbooks/
    ├── 00-init-system.yml               # 系统初始化
    ├── 01-deploy-k3s.yml                # K3s HA 部署
    └── templates/
        └── k3s-config.yaml.j2           # K3s config.yaml 模板
```

### 3.2 Playbook 00: 系统初始化

`00-init-system.yml` 在所有节点上执行：

| 步骤 | 说明 |
|------|------|
| 安装基础包 | curl, wget, vim, git, iproute, chrony, python3... |
| 禁用 swap | `swapoff -a` + 清理 fstab（K8s 要求） |
| 内核参数 | `ip_forward=1`, `bridge-nf-call-iptables=1` |
| /etc/hosts | 3 节点主机名映射（Ansible 用主机名 SSH） |
| 时区 + NTP | `Asia/Shanghai` + chronyd |
| firewalld | 禁用（K3s 自管防火墙） |
| ops 用户 | 确保存在 + wheel 组 + 免密 sudo |

> **坑**：`dnf` Ansible 模块需要 python3 的 dnf 绑定，但 python3.11 没有这个绑定。改用 `command` 模块直接执行 `dnf install -y` 命令绕过。

### 3.3 Playbook 01: K3s HA 部署

`01-deploy-k3s.yml` 分 4 个 Play：

#### Play 1: Pre-flight 检查（所有节点）

- 验证 swap 已禁用
- 验证 systemd 运行正常
- 验证 `ip_forward=1`
- 验证节点间网络互通
- 检查 K3s 是否已安装（`stat /etc/systemd/system/k3s.service`）

> **坑**：最初用 `which k3s` 检查是否已安装，但预下载的二进制让检查误判为"已安装"。改用 `stat` 检查 systemd service 文件，更准确。

#### Play 2: 部署首个 Server（node-01, cluster-init）

1. 部署 `config.yaml`（Jinja2 模板渲染）
2. 下载 K3s 安装脚本 `get.k3s.io`
3. 验证 K3s 二进制已预下载（`/usr/local/bin/k3s`）
4. 执行安装：`INSTALL_K3S_SKIP_DOWNLOAD=true /tmp/k3s-install.sh`
5. 等待 API 端口 6443 就绪
6. 等待 node-01 Ready
7. 读取 cluster token（供 node-02/03 join）
8. 配置 ops 用户 kubectl 访问

> **坑**：GitHub 直连下载 K3s 二进制（78MB）在中国极慢/超时。改用 `gh-proxy.com` 代理下载到 node-01，`INSTALL_K3S_SKIP_DOWNLOAD=true` 跳过安装脚本的下载步骤。

#### Play 3: 部署 joining Server（node-02, node-03）

`serial: 1` 逐个加入，避免 etcd 选举冲突：

1. 部署 `config.yaml`（join 模式，`server: https://node-01:6443`）
2. 从 node-01 复制 K3s 二进制和安装脚本（node-02/03 无公网）
3. 执行安装：`K3S_TOKEN=xxx INSTALL_K3S_SKIP_DOWNLOAD=true /tmp/k3s-install.sh`
4. 在 node-01 上等待新节点 Ready

> **坑**：node-02/03 没有公网 IP，无法直接拉取 K3s 镜像。解决方案见 §4 Step 4 Airgap 分发及 §10.3。

#### Play 4: 集群健康验证（node-01）

- 3 节点全部 Ready
- 所有 pod Running
- etcd 健康检查

### 3.4 K3s 配置文件

模板 `k3s-config.yaml.j2` 根据 `inventory_hostname` 区分首节点和加入节点：

```yaml
# 首节点 (node-01)
node-ip: 192.168.1.228
node-name: node-01
flannel-iface: eth0
write-kubeconfig-mode: "0644"
tls-san:
  - 192.168.1.228
  - <集群公网入口IP>      # EIP，供外部 kubectl 访问
cluster-init: true       # 初始化新集群

# 加入节点 (node-02/03)
node-ip: 192.168.1.230
node-name: node-02
flannel-iface: eth0
write-kubeconfig-mode: "0644"
tls-san:
  - 192.168.1.230
server: https://192.168.1.228:6443   # 指向首节点
```

---

## 4. 实施计划（5 步）

> 执行顺序严格按依赖关系排列：必须在 Ansible 控制节点就绪且 SSH 连通后，才能运行 playbook。K3s 集群必须先初始化首节点，后加入其余节点。

```
Step 1: Ansible 控制节点 ──► 安装 ansible-core、配置 SSH 免密、验证 3 节点连通
    │
    ▼
Step 2: Playbook 分发 ─────► scp ansible/ 目录到 node-01
    │
    ▼
Step 3: 系统初始化 ────────► ansible-playbook 00-init-system.yml（swap/sysctl/chronyd/hosts）
    │
    ▼
Step 4: K3s HA 部署 ───────► cluster-init → node-02/03 join → airgap 镜像分发
    │
    ▼
Step 5: 集群验证 ──────────► 3 节点 Ready → etcd 健康 → 核心 Pod 正常
```

---

### Step 1: Ansible 控制节点就绪

**目标**：在 node-01 上安装 `ansible-core`，配置 ops 用户 SSH 免密登录 node-02/03，验证控制节点到受管节点的连通性。

**前置条件**：
- node-01 有 EIP 可从本机 SSH 访问
- node-02/03 已开机，cloud-init 完成
- 3 节点内网互通（192.168.1.0/24）

**执行**：

```bash
# 本机：上传 SSH 私钥到 node-01（复用 k3s-cluster-key 或生成专用部署密钥）
scp -i ~/.ssh/id_rsa ~/.ssh/id_rsa ops@<集群公网入口IP>:/home/ops/.ssh/deploy_key
scp -i ~/.ssh/id_rsa ~/.ssh/id_rsa.pub ops@<集群公网入口IP>:/home/ops/.ssh/deploy_key.pub

# nod-01：安装 ansible-core（python3.11 pip 方式最可靠）
ssh ops@k3s-node-01
sudo python3.11 -m pip install ansible-core

# node-01：配置 SSH 免密到 node-02/03
cat ~/.ssh/deploy_key.pub >> ~/.ssh/authorized_keys
ssh-copy-id -i ~/.ssh/deploy_key.pub ops@192.168.1.230
ssh-copy-id -i ~/.ssh/deploy_key.pub ops@192.168.1.229

# node-01：验证免密连通性
ssh -o StrictHostKeyChecking=accept-new ops@192.168.1.230 hostname   # k3s-node-02
ssh -o StrictHostKeyChecking=accept-new ops@192.168.1.229 hostname   # k3s-node-03
```

> **坑**：Alibaba Cloud Linux 3 的 EPEL 仓库有 `ansible` 包但缺少 `ansible-core` 命令，`dnf install ansible` 后无 `ansible-playbook`。改用 `python3.11 -m pip install ansible-core` 直接安装最可靠。

**验证**：
```bash
ansible-playbook --version                                # 确认安装成功
ansible all -i inventory.ini -m ping                      # 3 节点均 pong
ansible all -i inventory.ini -a "hostname"                # 返回 k3s-node-01/02/03
```

---

### Step 2: Ansible 项目文件分发

**目标**：将本机适配后的 `ansible/` 目录上传到 node-01 的 `/home/ops/ansible/`，作为 playbook 执行源。

**新建文件**（在本机 `ansible/` 目录）：

| 文件 | 说明 |
|------|------|
| `ansible/ansible.cfg` | 配置（python 解释器指定 3.11） |
| `ansible/inventory.ini` | 3 节点 inventory（`k3s-node-01` `k3s-node-02` `k3s-node-03`） |
| `ansible/group_vars/all.yml` | 全局变量（IP、包名、K3s 版本、镜像 endpoint） |
| `ansible/playbooks/00-init-system.yml` | 系统初始化 playbook（swap/sysctl/hosts/chronyd/firewalld） |
| `ansible/playbooks/01-deploy-k3s.yml` | K3s HA 部署 playbook（4 个 Play） |
| `ansible/playbooks/templates/k3s-config.yaml.j2` | K3s config.yaml Jinja2 模板 |

**执行**：
```bash
# 本机：上传 ansible/ 目录
scp -r ansible ops@<集群公网入口IP>:/home/ops/ansible/

# node-01：目录结构确认
ssh ops@k3s-node-01 "tree /home/ops/ansible/"
```

**验证**：
```bash
# node-01：检查 inventory 解析
ansible-inventory -i /home/ops/ansible/inventory.ini --list | python3 -m json.tool

# node-01：dry-run 检查语法
ansible-playbook -i /home/ops/ansible/inventory.ini /home/ops/ansible/playbooks/00-init-system.yml --syntax-check
ansible-playbook -i /home/ops/ansible/inventory.ini /home/ops/ansible/playbooks/01-deploy-k3s.yml --syntax-check
```

---

### Step 3: 系统初始化

**目标**：在 3 节点上运行 `00-init-system.yml`，统一系统配置（swap 禁用、内核参数、hosts 映射、时区 NTP、firewalld 禁用、ops 用户确认）。

**执行**：
```bash
# node-01：运行系统初始化 playbook
cd /home/ops/ansible
ansible-playbook -i inventory.ini playbooks/00-init-system.yml
```

**Playbook 步骤清单**：

| 步骤 | 说明 | 验证方式 |
|------|------|---------|
| 安装基础包 | curl, wget, vim, git, iproute, chrony, python3 | `rpm -q` 已安装 |
| 禁用 swap | `swapoff -a` + 清理 fstab | `free -h` → Swap: 0 |
| 内核参数 | `ip_forward=1`, `bridge-nf-call-iptables=1` | `sysctl net.ipv4.ip_forward` → 1 |
| /etc/hosts | 3 节点主机名 → 内网 IP 映射 | `ssh k3s-node-02 "hostname && ping -c 1 node-01"` |
| 时区 + NTP | `Asia/Shanghai` + chronyd 启用 | `timedatectl` → Asia/Shanghai |
| firewalld | 禁用 + 停止自启 | `systemctl is-active firewalld` → inactive |
| ops 用户 | wheel 组 + 免密 sudo | `cat /etc/sudoers.d/ops` → NOPASSWD |

> **坑**：Ansible `dnf` 模块需要 python3 的 dnf 绑定，但 python3.11 没有这个绑定。Playbook 中改用 `command: dnf install -y <pkg>` 绕过。

**验证**：
```bash
# 逐节点检查关键配置
ansible all -i inventory.ini -a "free -h | grep Swap"
ansible all -i inventory.ini -a "sysctl net.ipv4.ip_forward"
ansible all -i inventory.ini -a "timedatectl | grep 'Time zone'"
ansible all -i inventory.ini -a "systemctl is-active chronyd"
ansible all -i inventory.ini -a "cat /etc/hosts | grep 192.168"
# 节点间互通
ansible all -i inventory.ini -a "ping -c 2 -W 1 192.168.1.228"
ansible all -i inventory.ini -a "ping -c 2 -W 1 192.168.1.230"
ansible all -i inventory.ini -a "ping -c 2 -W 1 192.168.1.229"
```

---

### Step 4: K3s HA 部署

**目标**：运行 `01-deploy-k3s.yml`，依次完成 node-01 cluster-init、node-02/03 逐个 join。处理 node-02/03 无公网场景下的二进制分发和镜像 airgap 导入。

**执行**：
```bash
# node-01：运行 K3s 部署 playbook
cd /home/ops/ansible
ansible-playbook -i inventory.ini playbooks/01-deploy-k3s.yml
```

**Playbook 执行流程**：

| Play | 目标节点 | 关键操作 | 依赖 |
|------|---------|---------|------|
| Play 1: Pre-flight | 全部 | 验证 swap/sysctl/systemd/网络互通/未安装 | Step 3 完成 |
| Play 2: cluster-init | node-01 | 渲染 config.yaml → 下载 K3s 二进制 → `cluster-init: true` 安装 → 等待 Ready → 读取 token | K3s 二进制预下载到 `/usr/local/bin/k3s` |
| Play 3: join（serial: 1） | node-02 → node-03 | 从 node-01 复制 K3s 二进制 → 渲染 join config → `server: https://node-01:6443` 安装 → 等待 Ready | token 来自 Play 2 |
| Play 4: 健康验证 | node-01 | 3 节点 Ready + pod Running + etcd 健康 | Play 3 完成 |

**处理无公网节点（Airgap）**：

node-02/03 没有公网 IP，无法直接拉取 K3s 所需镜像。Playbook 自动执行：

```bash
# 1. node-01 导出所有 K3s 镜像
k3s ctr images export /tmp/k3s-airgap-images.tar \
  $(k3s ctr images list -q)

# 2. scp 分发到 node-02/03
scp /tmp/k3s-airgap-images.tar node-02:/var/lib/rancher/k3s/agent/images/
scp /tmp/k3s-airgap-images.tar node-03:/var/lib/rancher/k3s/agent/images/

# 3. K3s 启动时自动导入 /var/lib/rancher/k3s/agent/images/*.tar
```

> **坑**：GitHub 直连下载 K3s 二进制（78MB）在中国极慢/超时。使用 `gh-proxy.com` 代理下载到 `/usr/local/bin/k3s`，Playbook 中 `INSTALL_K3S_SKIP_DOWNLOAD=true` 跳过下载步骤。node-02/03 通过从 node-01 复制二进制获得。

**验证**（Play 4 自动执行，也可手动确认）：
```bash
# node-01 等待集群就绪
kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml wait --for=condition=Ready nodes --all --timeout=120s
```

---

### Step 5: 集群验证

**目标**：全面验证 K3s 集群 3 节点 Ready、etcd 健康、核心 Pod 正常运行、kubeconfig 可用。

**配置 kubectl 访问**（本机）：

```bash
# 从 node-01 获取 kubeconfig
ssh ops@k3s-node-01 "cat /etc/rancher/k3s/k3s.yaml" \
  | sed "s/127.0.0.1/<集群公网入口IP>/g" \
  > kubeconfig.yaml

chmod 600 kubeconfig.yaml
# 验证
kubectl --kubeconfig kubeconfig.yaml get nodes
```

> 本机没有 kubectl 则不用此步，直接在 k3s-node-01 查看，同时命令删除“ --kubeconfig kubeconfig.yaml ”，例如：

```bash
ssh ops@k3s-node-01
# 配置普通用户权限
mkdir -p $HOME/.kube
sudo cp /etc/rancher/k3s/k3s.yaml $HOME/.kube/config
sudo chown $USER:$USER $HOME/.kube/config
chmod 600 $HOME/.kube/config
# 验证
kubectl get nodes -o wide
```

**验证清单**：

```bash
# 1. 3 节点全部 Ready
kubectl --kubeconfig kubeconfig.yaml get nodes -o wide
# NAME      STATUS   ROLES                       AGE   VERSION
# node-01   Ready    control-plane,etcd,master   ...   v1.36.2+k3s1
# node-02   Ready    control-plane,etcd,master   ...   v1.36.2+k3s1
# node-03   Ready    control-plane,etcd,master   ...   v1.36.2+k3s1

# 2. 核心 Pod 全部 Running
kubectl --kubeconfig kubeconfig.yaml get pods -n kube-system
# coredns, metrics-server, local-path-provisioner, traefik, svclb-traefik

# 3. etcd 健康
kubectl --kubeconfig kubeconfig.yaml get pods -n kube-system | grep etcd
# etcd-node-01, etcd-node-02, etcd-node-03 全部 Running

# 4. etcd 成员检查
ssh ops@k3s-node-01 "sudo /usr/local/bin/k3s etcd member list"
# 3 active members

# 5. 远程 API Server 访问
kubectl --kubeconfig kubeconfig.yaml cluster-info
# Kubernetes control plane is running at https://<集群公网入口IP>:6443
```

---

## 5. 部署结果

### 5.1 集群状态

```bash
$ kubectl --kubeconfig kubeconfig.yaml get nodes -o wide

NAME      STATUS   ROLES                       AGE   VERSION          INTERNAL-IP      ...
node-01   Ready    control-plane,etcd,master   2d    v1.36.2+k3s1     192.168.1.228
node-02   Ready    control-plane,etcd,master   2d    v1.36.2+k3s1     192.168.1.230
node-03   Ready    control-plane,etcd,master   2d    v1.36.2+k3s1     192.168.1.229
```

### 5.2 核心 Pod

| Pod | Namespace | 功能 |
|-----|-----------|------|
| coredns | kube-system | 集群 DNS |
| metrics-server | kube-system | 资源监控 |
| local-path-provisioner | kube-system | 动态存储 |
| traefik | kube-system | Ingress Controller |
| svclb-traefik | kube-system | Service LB（DaemonSet） |

### 5.3 etcd 健康

3 个 etcd 成员，HA 数据存储正常。

---

## 6. 受影响文件总览

### 新建文件（6 个）

| 文件路径 | 步骤 | 说明 |
|---------|------|------|
| `ansible/ansible.cfg` | Step 2 | Ansible 配置（python 解释器指定 3.11） |
| `ansible/inventory.ini` | Step 2 | 3 节点 inventory |
| `ansible/group_vars/all.yml` | Step 2 | 全局变量 |
| `ansible/playbooks/00-init-system.yml` | Step 3 | 系统初始化 playbook |
| `ansible/playbooks/01-deploy-k3s.yml` | Step 4 | K3s HA 部署 playbook |
| `ansible/playbooks/templates/k3s-config.yaml.j2` | Step 4 | K3s config.yaml Jinja2 模板 |

### 自动生成文件（2 个）

| 文件路径 | 说明 |
|---------|------|
| `kubeconfig.yaml` | 集群 kubeconfig（`.gitignore` 排除） |
| `/home/ops/.ssh/deploy_key` | 部署专用 SSH 密钥（node-01 上生成或上传） |

## 7. 部署顺序与回滚

### 推荐部署顺序

```
1. Step 1: 安装 ansible-core + SSH 免密配置 → 3 节点连通
2. Step 2: ansible/ 目录 scp 上传 → syntax-check
3. Step 3: 00-init-system.yml → 逐节点验证系统配置
4. Step 4: 01-deploy-k3s.yml → serial:1 逐个 join
5. Step 5: 集群验证 → nodes + pods + etcd + kubeconfig
```

### 回滚策略

| 步骤 | 回滚方式 |
|------|---------|
| Step 1（Ansible/SSH） | `ssh-keygen -R 192.168.x.x` 移除 known_hosts |
| Step 2（项目文件） | `rm -rf /home/ops/ansible/` 重新 scp |
| Step 3（系统初始化） | 逐项逆操作：`swapon -a`、`systemctl start firewalld`、`timedatectl set-timezone UTC` |
| Step 4（K3s 部署） | node-03/02 逐个 `kubectl drain + delete node` → `/usr/local/bin/k3s-uninstall.sh`；node-01 最后 uninstall。或 `terraform destroy` 整集群重建 |
| Step 5（kubeconfig） | `rm kubeconfig.yaml`，重新从 node-01 获取 |

> **完全重建**：K3s uninstall 脚本会清理 systemd service、二进制和数据目录。执行顺序与部署相反：先 uninstall joining 节点，最后 uninstall 首节点。

## 8. 关键设计决策

| 决策 | 原因 |
|------|------|
| Ansible 控制节点放在 node-01 | 避免额外维护跳板机，node-01 有 EIP 可达 |
| `serial: 1` 逐个 join | 避免 etcd 选举冲突 |
| K3s binary 预下载 + `SKIP_DOWNLOAD` | 绕过 GitHub 下载慢，且可分发到无公网节点 |
| `stat` 检查 service 文件 | 比 `which k3s` 更准确地判断安装状态 |
| daocloud + Docker Hub 双 endpoint | 主源直连快，fallback 走代理保底 |
| SSH config 拆分两个 Host | 隧道连接和普通连接互不干扰 |

---

## 9. 踩坑记录与解决方案

### 9.1 cgroup v1 → v2

|          |                                                              |
| -------- | ------------------------------------------------------------ |
| **现象** | K3s v1.36.2 启动失败：`kubelet is configured to not run on a host using cgroup v1` |
| **原因** | Alibaba Cloud Linux 3 默认使用 cgroup v1，K3s v1.36.2 要求 cgroup v2 |
| **解决** | `grubby --update-kernel=ALL --args="systemd.unified_cgroup_hierarchy=1"` + 重启所有节点 |

### 9.2 Docker Hub 不可访问

|          |                                                              |
| -------- | ------------------------------------------------------------ |
| **现象** | containerd 拉镜像超时：`registry-1.docker.io` 无法连接       |
| **原因** | Docker Hub 在中国被墙                                        |
| **解决** | 配置 `/etc/rancher/k3s/registries.yaml` 使用 daocloud 镜像源 |

```yaml
# /etc/rancher/k3s/registries.yaml
mirrors:
  docker.io:
    endpoint:
      - "https://docker.m.daocloud.io"
      - "https://registry-1.docker.io"   # fallback（走代理）
  gcr.io:
    endpoint:
      - "https://gcr.m.daocloud.io"
  quay.io:
    endpoint:
      - "https://quay.m.daocloud.io"
```

### 9.3 node-02/03 无公网拉镜像（Airgap 分发）

|          |                                                    |
| -------- | -------------------------------------------------- |
| **现象** | node-02/03 无法从 daocloud 拉取 K3s 所需镜像       |
| **原因** | 无公网 IP，内网也无法访问 daocloud                 |
| **解决** | node-01 导出镜像 tarball → scp 分发 → K3s 自动导入 |

```bash
# node-01: 导出所有 K3s 镜像
k3s ctr images export /tmp/k3s-airgap-images.tar \
  $(k3s ctr images list -q)

# 分发到 node-02/03
scp /tmp/k3s-airgap-images.tar node-02:/var/lib/rancher/k3s/agent/images/
scp /tmp/k3s-airgap-images.tar node-03:/var/lib/rancher/k3s/agent/images/

# K3s 启动时自动导入 /var/lib/rancher/k3s/agent/images/*.tar
```

### 9.4 GitHub 下载慢

|          |                                       |
| -------- | ------------------------------------- |
| **现象** | 下载 K3s 二进制（78MB）从 GitHub 超时 |
| **解决** | 使用 `gh-proxy.com` 代理下载          |

```bash
wget https://gh-proxy.com/https://github.com/k3s-io/k3s/releases/download/v1.36.2+k3s1/k3s -O /usr/local/bin/k3s
chmod +x /usr/local/bin/k3s
```

### 9.5 Ansible become PATH 问题

|          |                                                           |
| -------- | --------------------------------------------------------- |
| **现象** | Playbook 中 `k3s kubectl` 命令找不到 k3s                  |
| **原因** | `become: true` 切换到 root 后，PATH 不含 `/usr/local/bin` |
| **解决** | 使用完整路径 `/usr/local/bin/k3s kubectl`                 |

### 9.6 dnf 模块不可用

|          |                                                |
| -------- | ---------------------------------------------- |
| **现象** | Ansible `dnf` 模块报错：找不到 python dnf 绑定 |
| **原因** | python3.11 没有 `dnf` python 包                |
| **解决** | 改用 `command` 模块直接执行 `dnf install -y`   |

---

## 10. 镜像拉取代理兜底（Phase 2.5）

daocloud 镜像源作为主源，但在它不可用时需要一个 fallback。通过 SSH 反向隧道把本机机场代理映射到 node-01，作为镜像拉取兜底。

### 10.1 SSH 反向隧道

```
本机机场代理 (127.0.0.1:7897)
        │
        │  SSH RemoteForward
        ▼
node-01 (127.0.0.1:8888)  ←── K3s containerd 代理请求
```

```bash
# 启动后台隧道（本机执行）
ssh -fN k3s-node-01-proxy
```

> SSH config 拆分为两个 Host：`k3s-node-01`（普通连接）和 `k3s-node-01-proxy`（带 RemoteForward），避免每次 SSH 都抢占 8888 端口。

### 10.2 K3s 代理环境变量

```bash
# /etc/systemd/system/k3s.service.env
HTTP_PROXY=http://127.0.0.1:8888
HTTPS_PROXY=http://127.0.0.1:8888
NO_PROXY=localhost,127.0.0.1,::1,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12,.daocloud.io,.aliyuncs.com,.svc,.cluster.local,<集群公网入口IP>,192.168.1.228,192.168.1.229,192.168.1.230
```

> `NO_PROXY` 排除 daocloud（主源直连不走代理），内网和集群 IP。只有 fallback 到 `registry-1.docker.io` 时才走代理。

### 10.3 兜底机制

containerd mirror 的 endpoint 按顺序尝试：

1. `docker.m.daocloud.io`（直连，不走代理）
2. `registry-1.docker.io`（走 SSH 隧道代理）

daocloud 正常时秒拉，daocloud 挂了自动 fallback 到 Docker Hub（经代理），无缝切换。

### 10.4 验证

强制只留 `registry-1.docker.io`（绕过 daocloud），删除缓存后重拉 `hello-world` 镜像成功，证明代理兜底链路完整可用。

> **注意**：SSH 隧道是本机后台进程，本机重启后需重新执行 `ssh -fN k3s-node-01-proxy`。仅配置在 node-01（node-02/03 靠 airgap 分发，无需各自代理）。