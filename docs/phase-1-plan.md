# Phase 1: WSL2 三节点环境搭建

## 概述

### 目标

在 Windows 本地通过 WSL2 创建 3 个独立 Linux 实例，配置网络互通、SSH 免密、Ansible 自动化管理，为 Phase 2 的 K3s 集群部署打好基础设施。

### 产出物

| 产出 | 路径 | 说明 |
|------|------|------|
| 3 个 WSL2 实例 | `node-01` / `node-02` / `node-03` | 独立 rootfs + PID，共享网络命名空间 |
| Ansible 项目 | `ansible/` | inventory + playbook 脚手架 |
| 初始化脚本 | `scripts/` | WSL2 distro 创建 + 节点初始化 |
| 本计划文档 | `docs/phase-1-plan.md` | 你正在看的这个 |

### 节点规划

| 节点 | WSL Distro 名 | IP 别名 | sshd 监听 | 角色 |
|------|-------------|---------|-----------|------|
| node-01 | k3s-node-01 | 192.168.50.11 | 192.168.50.11:22 | Master+Worker+etcd, Ansible 控制节点 |
| node-02 | k3s-node-02 | 192.168.50.12 | 192.168.50.12:22 | Master+Worker+etcd |
| node-03 | k3s-node-03 | 192.168.50.13 | 192.168.50.13:22 | Master+Worker+etcd |

---

## WSL2 多实例架构说明

### 核心挑战：共享网络命名空间

WSL2 的多个 distro 实例运行在同一个轻量级 Utility VM 中，它们 **共享同一个内核和网络命名空间**。这意味着：

- 所有 distro 看到的是同一块 `eth0` 网卡，同一个 IP
- 默认情况下无法通过不同 IP 区分节点
- 端口绑定冲突：如果所有 sshd 都监听 `0.0.0.0:22`，只有一个能启动

### 解决方案：eth0 IP 别名

为每个 distro 在共享的 `eth0` 上添加独立的 IP 别名（alias），并通过 `ListenAddress` 将 sshd 绑定到各自的 IP：

```
eth0: 172.x.x.x (WSL2 NAT 默认地址，所有 distro 共享)
    + 192.168.50.11  (node-01 别名)
    + 192.168.50.12  (node-02 别名)
    + 192.168.50.13  (node-03 别名)
```

**为什么能工作**：

1. 所有 IP 别名都在同一块 eth0 上，所有 distro 都能访问到全部 3 个 IP
2. 每个 distro 的 sshd 绑定到自己的 IP（`ListenAddress 192.168.50.1X`），不冲突
3. 每个 distro 的 K3s 使用 `--node-ip 192.168.50.1X` 声明自己的地址
4. etcd 集群通过这些 IP 互相通信，连通性有保障

**隔离性说明**：distro 之间的隔离在 **文件系统 + 进程空间** 层面（各自独立），网络层面是共享的。对于学习项目完全足够。

### IP 别名持久化

WSL2 重启后 `ip addr add` 添加的别名会丢失。需要创建 systemd service 在启动时自动添加。

---

## 步骤 1: 创建 WSL2 实例

### 1.1 前置条件检查

在 Windows PowerShell 中执行：

```powershell
# 确认 WSL2 已安装
wsl --status

# 确认默认版本为 2
wsl --set-default-version 2

# 如果没有 Ubuntu，安装一个作为基础镜像
wsl --install -d Ubuntu-22.04
```

### 1.2 导出基础镜像

启动一次 Ubuntu-22.04，完成初始用户设置后退出。然后导出：

```powershell
# 创建存储目录
mkdir D:\WSL\k3s-cluster

# 导出基础镜像
wsl --export Ubuntu-22.04 D:\WSL\k3s-cluster\ubuntu-base.tar
```

### 1.3 导入 3 个实例

```powershell
# 导入 node-01
wsl --import k3s-node-01 D:\WSL\k3s-cluster\node-01 D:\WSL\k3s-cluster\ubuntu-base.tar --version 2

# 导入 node-02
wsl --import k3s-node-02 D:\WSL\k3s-cluster\node-02 D:\WSL\k3s-cluster\ubuntu-base.tar --version 2

# 导入 node-03
wsl --import k3s-node-03 D:\WSL\k3s-cluster\node-03 D:\WSL\k3s-cluster\ubuntu-base.tar --version 2
```

> **注意**：`wsl --import` 创建的实例默认以 root 登录，后续会创建普通用户。

### 1.4 验证

```powershell
wsl -l -v
```

应看到 4 个 distro（含原始 Ubuntu-22.04 + 3 个新实例），版本均为 2。

---

## 步骤 2: 系统初始化（每节点执行）

以下操作需要在 **每个 distro** 中各执行一次。可以通过 `wsl -d k3s-node-0X` 进入对应实例。

### 2.1 启用 systemd

WSL2 默认不启用 systemd，K3s 和 sshd 都依赖它。

```bash
# 在每个 distro 中执行
cat > /etc/wsl.conf << 'EOF'
[boot]
systemd=true

[network]
hostname=node-01
generateHosts=false
generateResolvConf=true

[interop]
enabled=true
appendWindowsPath=false
EOF
```

> 将 `hostname=node-01` 替换为对应节点名（node-02 / node-03）。

修改完成后，需要在 PowerShell 中重启 WSL：

```powershell
wsl --shutdown
# 然后重新进入各 distro
```

### 2.2 配置 /etc/hosts

```bash
cat > /etc/hosts << 'EOF'
127.0.0.1   localhost
192.168.50.11  node-01
192.168.50.12  node-02
192.168.50.13  node-03
EOF
```

### 2.3 关闭 swap

K3s 要求关闭 swap。

```bash
# 临时关闭
swapoff -a

# 永久关闭：注释 /etc/fstab 中的 swap 行
sed -i '/swap/s/^/#/' /etc/fstab
```

> WSL2 的 swap 还受 `.wslconfig` 控制。在 Windows 用户目录下创建 `C:\Users\<你的用户名>\.wslconfig`：
> ```ini
> [wsl2]
> swap=0
> ```

### 2.4 内核参数调优

```bash
cat > /etc/sysctl.d/99-k3s.conf << 'EOF'
net.ipv4.ip_forward=1
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
EOF

# 应用
sysctl --system
```

> **WSL2 内核模块注意**：`br_netfilter` 模块在 WSL2 自定义内核中可能未加载。如果 `sysctl` 报错 `cannot stat /proc/sys/net/bridge/bridge-nf-call-iptables`，执行 `modprobe br_netfilter`。如果模块不存在，暂时注释掉这两行，K3s 的 Flannel 仍可工作。

### 2.5 安装基础软件包

```bash
apt-get update && apt-get install -y \
    curl wget vim git \
    net-tools iproute2 \
    openssh-server \
    chrony \
    python3 python3-pip \
    gnupg software-properties-common \
    ca-certificates
```

### 2.6 设置时区

```bash
timedatectl set-timezone Asia/Shanghai
systemctl enable chrony
systemctl start chrony
```

---

## 步骤 3: 网络配置（IP 别名）

### 3.1 创建 IP 别名持久化服务

在每个 distro 中创建 systemd service，使 IP 别名在 WSL 重启后自动恢复。

```bash
# node-01 中执行
cat > /etc/systemd/system/wsl-ip-alias.service << 'EOF'
[Unit]
Description=WSL2 IP Alias for K3s node
After=network.target

[Service]
Type=oneshot
ExecStart=/sbin/ip addr add 192.168.50.11/24 dev eth0
ExecStop=/sbin/ip addr del 192.168.50.11/24 dev eth0
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable wsl-ip-alias.service
systemctl start wsl-ip-alias.service
```

> node-02 替换为 `192.168.50.12`，node-03 替换为 `192.168.50.13`。

### 3.2 验证 IP 可达性

```bash
# 在 node-01 中验证
ip addr show eth0
# 应看到 172.x.x.x 和 192.168.50.11 两个 IP

ping -c 2 192.168.50.12  # 能 ping 通 node-02 的 IP
ping -c 2 192.168.50.13  # 能 ping 通 node-03 的 IP
```

---

## 步骤 4: SSH 免密配置

### 4.1 配置 sshd 绑定独立 IP

每个 distro 的 sshd 必须绑定到自己的 IP，否则端口冲突。

```bash
# node-01 中执行
sed -i 's/^#\?ListenAddress.*/ListenAddress 192.168.50.11/' /etc/ssh/sshd_config
sed -i 's/^#\?Port.*/Port 22/' /etc/ssh/sshd_config

# 确保 sshd 启动
systemctl enable ssh
systemctl restart ssh
```

> node-02 替换为 `192.168.50.12`，node-03 替换为 `192.168.50.13`。

### 4.2 创建运维用户（可选但推荐）

```bash
# 在每个 distro 中创建相同的用户
useradd -m -s /bin/bash ops
echo 'ops:ops123' | chpasswd
echo 'ops ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ops
```

### 4.3 生成并分发 SSH 密钥

在 node-01（Ansible 控制节点）上：

```bash
# 切换到 ops 用户
su - ops

# 生成密钥对（一路回车）
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""

# 分发公钥到三个节点（密码 ops123）
ssh-copy-id ops@192.168.50.11
ssh-copy-id ops@192.168.50.12
ssh-copy-id ops@192.168.50.13
```

### 4.4 验证免密登录

```bash
ssh ops@192.168.50.12 hostname  # 应输出 node-02，无需密码
ssh ops@192.168.50.13 hostname  # 应输出 node-03，无需密码
```

---

## 步骤 5: Ansible 环境搭建

### 5.1 安装 Ansible（node-01）

```bash
# 在 node-01 上以 ops 用户操作
# 使用 pip 安装（Ubuntu apt 版本较旧）
pip3 install ansible
```

### 5.2 项目结构

```
ansible/
├── ansible.cfg              # Ansible 配置
├── inventory.ini            # 节点清单
├── group_vars/
│   └── all.yml              # 全局变量
└── playbooks/
    └── 00-init-system.yml   # 基础初始化 Playbook
```

### 5.3 inventory.ini

```ini
[k3s_cluster]
node-01 ansible_host=192.168.50.11
node-02 ansible_host=192.168.50.12
node-03 ansible_host=192.168.50.13

[k3s_cluster:vars]
ansible_user=ops
ansible_ssh_private_key_file=/home/ops/.ssh/id_ed25519
ansible_python_interpreter=/usr/bin/python3
```

### 5.4 测试连通性

```bash
cd ~/k8s-project/ansible
ansible all -i inventory.ini -m ping
```

三个节点都应返回 `SUCCESS`。

---

## 步骤 6: 基础初始化 Playbook

编写 `00-init-system.yml`，用 Ansible 统一执行步骤 2 中的系统初始化操作，确保三节点配置一致、可复现。

### Playbook 功能

| Task | 模块 | 说明 |
|------|------|------|
| 更新 apt 缓存 | apt | 三节点同步更新 |
| 安装基础软件包 | apt | 统一软件清单 |
| 关闭 swap | shell + lineinfile | 临时关闭 + 永久注释 fstab |
| 配置 sysctl | copy + sysctl | K3s 内核参数 |
| 设置时区 | timezone | Asia/Shanghai |
| 启动 chrony | service | 时间同步 |
| 配置 /etc/hosts | copy | 节点解析 |
| 创建 ops 用户 | user | 统一运维用户 |

### 执行方式

```bash
ansible-playbook -i inventory.ini playbooks/00-init-system.yml
```

---

## 验证清单

全部完成后，逐项验证：

- [ ] `wsl -l -v` 显示 3 个 k3s-node-0X 实例，版本 2
- [ ] 每个 distro 中 `systemctl is-system-running` 显示 `running`
- [ ] `hostname` 分别返回 node-01 / node-02 / node-03
- [ ] `ip addr show eth0` 各节点看到自己的 192.168.50.1X
- [ ] `ssh ops@192.168.50.12 hostname` 免密返回 node-02
- [ ] `ansible all -m ping` 三节点全部 SUCCESS
- [ ] `free -h` 中 Swap 全为 0
- [ ] `sysctl net.ipv4.ip_forward` 返回 1
- [ ] `timedatectl` 时区为 Asia/Shanghai

---

## WSL2 特殊注意事项

| 问题 | 原因 | 解决方案 |
|------|------|---------|
| IP 别名重启丢失 | WSL2 网络非持久化 | systemd service `wsl-ip-alias.service` |
| 主机名被重置 | WSL2 启动时可能覆盖 | `/etc/wsl.conf` 中设置 `hostname` + `generateHosts=false` |
| `br_netfilter` 不可用 | WSL2 自定义内核可能未编译该模块 | `modprobe br_netfilter`；若失败则注释相关 sysctl，K3s Flannel 仍可工作 |
| swap 无法通过 fstab 完全关闭 | WSL2 的 swap 由 `.wslconfig` 管理 | 在 Windows 用户目录创建 `.wslconfig` 设置 `swap=0` |
| `wsl --shutdown` 影响所有 distro | WSL2 共享 VM | 所有 distro 会同时关闭，需要重新启动需要的实例 |
| systemd 未启动 | `/etc/wsl.conf` 修改后未重启 | `wsl --shutdown` 后重新进入 |
| 磁盘空间 | 每个 distro 约 1-2GB | 确保导入目录所在盘有足够空间 |

---

## 下一步

Phase 1 完成后，进入 **Phase 2: K3s 集群部署**——使用 Ansible Playbook 在 3 节点上部署 K3s HA 集群（embedded etcd）。
