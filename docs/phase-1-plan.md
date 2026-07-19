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
wsl --install -d Ubuntu
```

### 1.2 导出基础镜像

启动一次 Ubuntu，完成初始用户设置后退出。然后导出：

```powershell
# 创建存储目录
mkdir D:\WSL\k3s-cluster

# 导出基础镜像
wsl --export Ubuntu D:\WSL\k3s-cluster\ubuntu-base.tar
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

应看到 4 个 distro（含原始 Ubuntu + 3 个新实例），版本均为 2。

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

Ansible 项目部署在 node-01 的 `/home/ops/k3s-cluster/ansible` 目录下（通过 SCP 上传，非挂载卷）：

```
/home/ops/k3s-cluster/ansible/
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
cd /home/ops/k3s-cluster/ansible
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
- [ ] 每个 distro 中 `systemctl is-system-running` 显示 `running`（`degraded` 也可接受，详见 WSL2 特殊注意事项）
- [ ] `hostname` 分别返回 node-01 / node-02 / node-03
- [ ] `ip addr show eth0` 各节点看到自己的 192.168.50.1X
- [ ] **宿主机** `ssh node-01 hostname` 免密返回 node-01（宿主机 SSH 已配置）
- [ ] **宿主机** `ssh node-02 hostname` 免密返回 node-02
- [ ] **宿主机** `ssh node-03 hostname` 免密返回 node-03
- [ ] node-01 内 `ssh ops@192.168.50.12 hostname` 免密返回 node-02（节点间互通）
- [ ] `ansible all -m ping` 三节点全部 SUCCESS
- [ ] `free -h` 中 Swap 全为 0
- [ ] `sysctl net.ipv4.ip_forward` 返回 1
- [ ] `timedatectl` 时区为 Asia/Shanghai
- [ ] Ansible 项目位于 `/home/ops/k3s-cluster/ansible`（节点本地，非挂载卷）

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
| systemd 显示 `degraded` | `getty@tty1.service` 失败（WSL2 无物理终端） | 不影响 K3s，可忽略；或 `systemctl mask getty@tty1` |
| distro 执行完命令即关闭 | WSL2 无持久进程时自动回收 | 用 `start-all-nodes.ps1` 后台保活 |
| 宿主机无法访问 192.168.50.x | WSL2 NAT 模式下 192.168.50.0/24 不在默认路由 | `route add 192.168.50.0 mask 255.255.255.0 <wsl-gateway>` |
| 磁盘空间 | 每个 distro 约 1-2GB | 确保导入目录所在盘有足够空间 |

---

## 快速执行流程（修正版）

> **设计原则**：所有脚本上传到节点本地后执行，不通过 WSL 挂载卷直接调用宿主机脚本。这样增加兼容性并模拟非 WSL 的真实集群场景。
>
> **SSH 策略**：Phase 1 引导阶段使用 `wsl -d` 进入节点执行命令；SSH 配置完成后，**Phase 2 及后续所有阶段均通过宿主机 SSH 连接集群操作**，不再使用 `wsl -d` 命令。

### Step 0: Windows 侧准备

```powershell
# 在 PowerShell 中执行

# 1. 确认 WSL2 可用
wsl --status
wsl --set-default-version 2

# 2. 如果没有 Ubuntu，安装一个
wsl --install -d Ubuntu
# 启动一次完成初始用户设置，然后关闭

# 3. 创建 .wslconfig 关闭 swap（K3s 要求）
# 路径: C:\Users\<你的用户名>\.wslconfig
@"
[wsl2]
swap=0
memory=8GB
processors=4
"@ | Out-File -FilePath "$env:USERPROFILE\.wslconfig" -Encoding utf8

# 4. 添加路由：让宿主机能访问 WSL2 内的 192.168.50.0/24 网段
#    （WSL2 NAT 模式下，宿主机默认只能访问 WSL2 的 172.x.x.x 网段）
wsl --shutdown
Start-Sleep -Seconds 3
wsl -d k3s-node-01 -u root -- echo "WSL started" 2>$null  # 触发 WSL 网络初始化
Start-Sleep -Seconds 2
$wslGateway = (Get-NetIPAddress -InterfaceAlias "vEthernet (WSL*)" -AddressFamily IPv4).IPAddress
route add 192.168.50.0 mask 255.255.255.0 $wslGateway
Write-Host "Route added: 192.168.50.0/24 via $wslGateway"
```

> **关于路由**：WSL2 NAT 模式下，`192.168.50.0/24` 是我们手动添加的 IP 别名，不在 WSL2 默认网段内。需要告诉 Windows 怎么路由到这个网段。上面的命令获取 WSL 虚拟网卡 IP 作为网关。
>
> **替代方案**：如果你使用 WSL2 `networkingMode=mirrored`（Windows 11 22H2+），则不需要添加路由，宿主机可以直接访问所有 WSL2 IP。

### Step 1: 创建 3 个 WSL 实例

```powershell
# 在 PowerShell 中执行（工作目录已为项目根目录）
.\scripts\01-create-distros.ps1
```

### Step 2: 上传脚本并初始化各节点（WSL 重启前）

> 脚本通过 WSL 挂载卷复制到节点 `/tmp/k3s-bootstrap/` 目录，然后在节点本地执行。
> 这模拟了真实集群中"上传脚本 → 本地执行"的模式。

```powershell
# 定义脚本源路径（基于当前工作目录动态获取，不硬编码绝对路径）
$scriptsDir = "$PWD\scripts"
# 转换为 WSL 挂载路径（用于通过挂载卷将脚本上传到节点本地）
$wslScriptsDir = (wsl wslpath -u "$scriptsDir").Trim()

# --- node-01 ---
# 上传脚本到节点本地
wsl -d k3s-node-01 -u root -- bash -c "mkdir -p /tmp/k3s-bootstrap && cp '$wslScriptsDir/02-init-node.sh' /tmp/k3s-bootstrap/"
# 在节点本地执行
wsl -d k3s-node-01 -u root -- bash /tmp/k3s-bootstrap/02-init-node.sh node-01 192.168.50.11

# --- node-02 ---
wsl -d k3s-node-02 -u root -- bash -c "mkdir -p /tmp/k3s-bootstrap && cp '$wslScriptsDir/02-init-node.sh' /tmp/k3s-bootstrap/"
wsl -d k3s-node-02 -u root -- bash /tmp/k3s-bootstrap/02-init-node.sh node-02 192.168.50.12

# --- node-03 ---
wsl -d k3s-node-03 -u root -- bash -c "mkdir -p /tmp/k3s-bootstrap && cp '$wslScriptsDir/02-init-node.sh' /tmp/k3s-bootstrap/"
wsl -d k3s-node-03 -u root -- bash /tmp/k3s-bootstrap/02-init-node.sh node-03 192.168.50.13
```

<details>
<summary><b>📖 上传脚本的最佳实践（补充说明）</b></summary>

上面的流程通过 WSL 挂载卷 `cp` 上传脚本，这是 Phase 1 引导阶段的临时手段——此时 SSH 尚未配置，无法使用 `scp`。在 SSH 可用后（Step 6 起），推荐采用以下生产级模式：

```bash
# ── 以 02-init-node.sh 为例，SSH 可用后的标准上传执行流程 ──

# 1. 本地语法检查（上传前确认脚本无语法错误，避免远端报错浪费往返）
bash -n scripts/02-init-node.sh

# 2. 通过 SCP 上传到目标节点的安全目录
scp scripts/02-init-node.sh node-01:/tmp/k3s-bootstrap/

# 3. 远程执行（开启伪终端 -t 保留环境变量，tee 同时输出到终端和带时间戳的日志）
ssh -t node-01 "bash -c 'cd /tmp/k3s-bootstrap && ./02-init-node.sh node-01 192.168.50.11 2>&1 | tee /var/log/k3s-bootstrap-$(date +%Y%m%d_%H%M%S).log'"

# 4. 检查返回值（0=成功，非 0=失败）
echo $?
```

**每一步的作用**：

| 步骤 | 命令 | 解决什么问题 |
|------|------|------------|
| 语法检查 | `bash -n` | 上传前就发现语法错误，避免"上传→远端报错→改了再传"的往返浪费 |
| SCP 上传 | `scp ... node-01:/path/` | 通用传输方式，非 WSL 环境（真实服务器、云主机）同样适用 |
| 伪终端 + tee | `ssh -t ... \| tee log` | `-t` 保留远端环境变量（如 `$PATH`）；`tee` 输出同时落盘，事后可追溯 |
| 返回值检查 | `echo $?` | 自动化判断成败，可嵌入 CI/CD 或脚本做条件分支 |

**与当前 Phase 1 流程的对比**：

| 维度 | 当前流程（Phase 1 引导） | 最佳实践（SSH 可用后） |
|------|------------------------|---------------------|
| 传输方式 | WSL 挂载卷 `cp` | `scp`（通用，非 WSL 环境同样适用） |
| 语法检查 | 无 | `bash -n` 上传前验证 |
| 执行日志 | 仅输出到终端，关闭后不可追溯 | `tee` 同时输出到终端和带时间戳的日志文件 |
| 返回值检查 | 人工观察输出 | `$?` 自动判断，可脚本化 |
| 适用场景 | SSH 未就绪的引导阶段（Step 2-5） | SSH 可用后的所有阶段（Step 6 起） |

> **为什么 Phase 1 不能直接用最佳实践？** Step 2 执行时 sshd 尚未安装和配置（这正是 02-init-node.sh 要做的事），无法 `scp` 或 `ssh`。这是"鸡生蛋"问题——需要先用 WSL 挂载卷引导出 SSH 能力，之后才能切换到标准模式。

</details>

### Step 3: 重启 WSL 使 systemd 生效

```powershell
wsl --shutdown
# 等待 5 秒后重新进入
```

### Step 4: 启动所有节点并上传引导脚本

> WSL2 distro 执行完命令后会自动关闭，需要用后台进程保活。
> 使用 `start-all-nodes.ps1` 同时启动 3 个节点。

```powershell
# 启动所有节点（保持运行）
.\scripts\start-all-nodes.ps1

# 上传引导脚本到各节点
$nodes = @(
    @{ Distro = "k3s-node-01"; Name = "node-01"; IP = "192.168.50.11" }
    @{ Distro = "k3s-node-02"; Name = "node-02"; IP = "192.168.50.12" }
    @{ Distro = "k3s-node-03"; Name = "node-03"; IP = "192.168.50.13" }
)

foreach ($node in $nodes) {
    # 上传 03-post-restart.sh 到节点本地（$wslScriptsDir 在 Step 2 中定义）
    wsl -d $node.Distro -u root -- bash -c "mkdir -p /tmp/k3s-bootstrap && cp '$wslScriptsDir/03-post-restart.sh' /tmp/k3s-bootstrap/"
    # 在节点本地执行
    wsl -d $node.Distro -u root -- bash /tmp/k3s-bootstrap/03-post-restart.sh $node.Name $node.IP
}
```

> **上传脚本最佳实践**：此处与 Step 2 相同，使用 WSL 挂载卷上传是因为 systemd 刚重启、SSH 密钥尚未分发。Step 6 SSH 配置完成后，后续脚本上传应切换为 `scp + tee + $?` 模式（详见 Step 2 补充说明）。

### Step 5: 分发 SSH 密钥（在 node-01 中）

```powershell
# 通过 wsl 进入 node-01
wsl -d k3s-node-01 -u ops
```

```bash
# 分发公钥到三个节点（密码: ops123）
ssh-copy-id ops@192.168.50.11
ssh-copy-id ops@192.168.50.12
ssh-copy-id ops@192.168.50.13

# 验证免密
ssh ops@192.168.50.12 hostname  # 应返回 node-02
ssh ops@192.168.50.13 hostname  # 应返回 node-03
```

### Step 6: 宿主机 SSH 连接配置

> 从此步骤起，宿主机可以通过 SSH 直接连接集群。**Phase 2 及后续所有阶段均使用宿主机 SSH 操作集群**，不再需要 `wsl -d` 命令。

#### 6.1 验证宿主机到 node-01 的 SSH 连通性

```powershell
# 在 Windows PowerShell 中执行
# 先确保 start-all-nodes.ps1 已运行（节点保持运行中）

# 测试 SSH 连接（使用密码 ops123）
ssh ops@192.168.50.11
# 输入密码 ops123，应成功进入 node-01
exit
```

> 如果连接超时，检查 Step 0 中的路由是否添加成功：
> ```powershell
> route print 192.168.50.*
> ```
> 如果没有路由，重新执行 `route add 192.168.50.0 mask 255.255.255.0 <wsl-gateway-ip>`。

#### 6.2 生成宿主机 SSH 密钥并配置免密

```powershell
# 在 Windows PowerShell 中执行

# 1. 生成密钥对（如果没有的话）
if (-not (Test-Path "$env:USERPROFILE\.ssh\id_ed25519")) {
    ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\id_ed25519" -N '""' -q
}

# 2. 将公钥上传到 node-01（密码: ops123）
$type = Get-Content "$env:USERPROFILE\.ssh\id_ed25519.pub"
wsl -d k3s-node-01 -u root -- bash -c "mkdir -p /home/ops/.ssh && echo '$type' >> /home/ops/.ssh/authorized_keys && chmod 700 /home/ops/.ssh && chmod 600 /home/ops/.ssh/authorized_keys && chown -R ops:ops /home/ops/.ssh"

# 3. 验证免密登录
ssh ops@192.168.50.11 hostname
# 应直接返回 node-01，无需密码
```

#### 6.3 配置 SSH 别名（可选但推荐）

在 Windows 上创建/编辑 `C:\Users\<你的用户名>\.ssh\config`：

```ssh-config
# K3s Cluster Nodes
Host node-01
    HostName 192.168.50.11
    User ops
    IdentityFile ~/.ssh/id_ed25519

Host node-02
    HostName 192.168.50.12
    User ops
    IdentityFile ~/.ssh/id_ed25519

Host node-03
    HostName 192.168.50.13
    User ops
    IdentityFile ~/.ssh/id_ed25519
```

配置后可直接 `ssh node-01` 连接。

#### 6.4 验证宿主机 SSH 连接

```powershell
ssh node-01 hostname   # 应返回 node-01
ssh node-02 hostname   # 应返回 node-02
ssh node-03 hostname   # 应返回 node-03
```

> **从现在起，所有集群操作通过宿主机 SSH 进行：**
> ```powershell
> ssh node-01           # 连接到 Ansible 控制节点
> ```
> 不再使用 `wsl -d k3s-node-01`。

### Step 7: 上传 Ansible 项目并运行 Playbook

> Ansible 项目通过 SCP 上传到 node-01 本地目录，模拟真实集群的文件部署方式。

#### 7.1 上传 Ansible 项目到 node-01

```powershell
# 在 Windows PowerShell 中执行
# 通过 SCP 上传（利用 Step 6 配置的 SSH 免密）

# 创建远程目录
ssh node-01 "mkdir -p /home/ops/k3s-cluster"

# 上传 ansible 目录（使用相对路径，工作目录已为项目根目录）
scp -r ansible node-01:/home/ops/k3s-cluster/

# 设置权限（避免 world-writable 警告）
ssh node-01 "chmod 700 /home/ops/k3s-cluster/ansible && chmod 600 /home/ops/k3s-cluster/ansible/ansible.cfg /home/ops/k3s-cluster/ansible/inventory.ini /home/ops/k3s-cluster/ansible/group_vars/all.yml && chmod 600 /home/ops/k3s-cluster/ansible/playbooks/*.yml"
```

<details>
<summary><b>📖 上传脚本的最佳实践——SCP 场景（补充说明）</b></summary>

Step 7.1 已经使用了 `scp` 上传，符合最佳实践中的传输方式。但对于 **Playbook 执行**，可以进一步优化为带日志记录和返回值检查的模式：

```bash
# ── SSH 可用后的标准执行流程（以 Playbook 为例）──

# 1. 本地 YAML 语法检查（上传前确认 Playbook 无语法错误）
#    （需要本地安装 ansible-lint 或使用 ansible-playbook --syntax-check）
ansible-playbook --syntax-check -i inventory.ini playbooks/00-init-system.yml

# 2. SCP 上传（已完成，见上方）

# 3. 远程执行 Playbook，输出同时写入日志
ssh -t node-01 "bash -c 'cd /home/ops/k3s-cluster/ansible && ansible-playbook -i inventory.ini playbooks/00-init-system.yml 2>&1 | tee /home/ops/k3s-cluster/logs/ansible-$(date +%Y%m%d_%H%M%S).log'"

# 4. 检查返回值
if [ $? -eq 0 ]; then
    echo "Playbook 执行成功"
else
    echo "Playbook 执行失败，请查看日志"
fi
```

**当前流程 vs 增强模式**：

| 维度 | 当前流程（7.2） | 增强模式 |
|------|---------------|---------|
| 语法检查 | 无 | `--syntax-check` 上传前验证 |
| 执行日志 | 仅终端输出 | `tee` 落盘，可追溯 |
| 返回值 | 人工观察 | `$?` 自动判断 |
| 日志路径 | 无 | `/home/ops/k3s-cluster/logs/ansible-YYYYMMDD_HHMMSS.log` |

> **Phase 2+ 建议**：后续所有 Playbook 执行采用增强模式，确保每次操作都有日志可追溯。可在 node-01 上编写 wrapper 脚本封装此模式。

</details>

#### 7.2 安装 Ansible 并运行 Playbook

```powershell
# 通过 SSH 连接到 node-01
ssh node-01
```

```bash
# 在 node-01 上以 ops 用户操作

# 安装 Ansible
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ansible

# 运行基础初始化 Playbook
cd /home/ops/k3s-cluster/ansible
ansible-playbook -i inventory.ini playbooks/00-init-system.yml
```

### Step 8: 验证

```bash
# 通过宿主机 SSH 连接到 node-01
# 在 Windows PowerShell 中: ssh node-01

# Ansible 连通性测试
cd /home/ops/k3s-cluster/ansible
ansible all -i inventory.ini -m ping

# 逐项验证
ansible all -i inventory.ini -m command -a "hostname"
ansible all -i inventory.ini -m command -a "free -h"
ansible all -i inventory.ini -m command -a "ip addr show eth0"
ansible all -i inventory.ini -m command -a "sysctl net.ipv4.ip_forward"
ansible all -i inventory.ini -m command -a "timedatectl"
```

---

## 后续阶段操作模式

> **从 Phase 2 起，所有集群操作遵循以下模式：**

```powershell
# 1. 宿主机 SSH 连接到 node-01（Ansible 控制节点）
ssh node-01

# 2. 在 node-01 上执行 Ansible Playbook / kubectl / helm 等操作
cd /home/ops/k3s-cluster/ansible
ansible-playbook -i inventory.ini playbooks/xx-xxx.yml
```

- 脚本和配置文件通过 `scp` 上传到节点本地，不在节点上通过 `/mnt/d/` 访问宿主机文件
- 所有运维操作通过 SSH 远程执行，与真实非 WSL 集群保持一致
- `wsl -d` 命令仅用于 Phase 1 的环境引导（创建 distro、首次初始化），后续不再使用

---

## 下一步

Phase 1 完成后，进入 **Phase 2: K3s 集群部署**——通过宿主机 SSH 连接 node-01，使用 Ansible Playbook 在 3 节点上部署 K3s HA 集群（embedded etcd）。
