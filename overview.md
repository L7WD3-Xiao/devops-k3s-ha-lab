# Phase 2: K3s 3-Server HA 集群部署完成

## 集群状态

| 节点 | 内网 IP | 角色 | 状态 | K3s 版本 |
|------|---------|------|------|----------|
| node-01 | 192.168.1.228 | control-plane,etcd | Ready | v1.36.2+k3s1 |
| node-02 | 192.168.1.230 | control-plane,etcd | Ready | v1.36.2+k3s1 |
| node-03 | 192.168.1.229 | control-plane,etcd | Ready | v1.36.2+k3s1 |

**API Server**: `https://116.62.168.245:6443`
**数据存储**: embedded etcd (3 成员 HA)
**容器运行时**: containerd 2.3.2-k3s2

## 核心 Pod 状态

| Namespace | Pod | Status |
|-----------|-----|--------|
| kube-system | coredns-5f5694d56b-v4bls | Running |
| kube-system | metrics-server-7c86f97b8d-97l2g | Running |
| kube-system | local-path-provisioner-58d557dc48-grv7r | Running |
| kube-system | traefik-6cd8c7cd89-drqnp | Running |
| kube-system | svclb-traefik (×3) | Running |

etcd 健康检查全部通过 (ping/log/etcd/etcd-readiness/informer-sync = ok)

## 部署过程中解决的问题

### 1. cgroup v1 → v2 切换
K3s v1.36.2 要求 cgroup v2，Alibaba Cloud Linux 3 默认使用 cgroup v1。
```bash
sudo grubby --update-kernel=ALL --args="systemd.unified_cgroup_hierarchy=1"
sudo grubby --update-kernel=ALL --remove-args="cgroup.memory=nokmem"
sudo reboot
```

### 2. Docker Hub 不可访问
配置 `/etc/rancher/k3s/registries.yaml` 使用国内镜像源：
```yaml
mirrors:
  docker.io:
    endpoint:
      - "https://docker.m.daocloud.io"
```

### 3. node-02/03 无公网 — 镜像分发
- node-01 导出镜像: `k3s ctr images export --platform linux/amd64`
- 分发到 `/var/lib/rancher/k3s/agent/images/` (K3s 自动导入)
- 同时分发 registries.yaml

### 4. GitHub 下载慢
使用 `gh-proxy.com` 代理下载 K3s 二进制 (78MB)。

### 5. Ansible 适配
- ansible-core 通过 `python3.11 -m pip` 安装 (dnf 包不完整)
- `become:true` 环境用 `/usr/local/bin/k3s kubectl` 完整路径
- `dnf` 模块改为 `command` (python3.11 缺 dnf 绑定)

## 访问方式

```bash
# 使用本机 kubeconfig
export KUBECONFIG=D:/Study/Note/project/k8s/kubeconfig.yaml
kubectl get nodes

# 或 SSH 到 node-01
ssh ops@116.62.168.245
sudo k3s kubectl get nodes
```

## 下一步
- Phase 3: 部署短链服务应用
- 配置 Ingress (Traefik 已就绪)
- 部署 MySQL + Redis (StatefulSet)
