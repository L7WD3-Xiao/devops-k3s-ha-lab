# Phase 4 准备：阿里云 ACR 镜像仓库配置

## 完成内容

为 Phase 4（短链服务部署）前置的镜像仓库配置——阿里云 ACR 个人版集成 K3s 集群。

### 新增文件
- `ansible/playbooks/templates/registries.yaml.j2` — K3s containerd 镜像仓库配置模板（Docker Hub 加速 + ACR VPC 认证）
- `ansible/playbooks/03-configure-acr.yml` — Ansible playbook：验证凭证 → 分发配置 → 滚动重启 K3s → 验证连通性
- `scripts/build-push.sh` — 本地 Docker 构建推送脚本
- `docs/phase-4-acr-setup.md` — 完整配置指南（方案选型、网络设计、认证方式、操作步骤、常见坑）

### 修改文件
- `ansible/group_vars/all.yml` — 新增 ACR 变量（`acr_registry`、`acr_namespace`、`acr_username`、`acr_password`）

## 方案设计

- **ACR 个人版**（免费）：3 namespace、50 repo，够用
- **VPC 内网拉取**：`registry-vpc.cn-hangzhou.aliyuncs.com`，零流量费
- **registries.yaml 认证**：containerd 级别全局配置，Deployment 无需 imagePullSecrets
- **滚动重启**：`serial=1` 逐节点重启 K3s，保持集群 HA

## 待用户操作

1. 阿里云控制台开通 ACR 个人版 + 设置固定密码 + 创建 namespace(`shortlink`) + 仓库(`shortlink-app`)
2. 在 `ansible/group_vars/all.yml` 填入 `acr_username` 和 `acr_password`
3. 执行 `ansible-playbook -i inventory.ini playbooks/03-configure-acr.yml`
4. 推送测试镜像验证拉取链路

## 下一步

- Phase 4：编写短链服务 Dockerfile + K8s Deployment/Service/Ingress
- Phase 5：CI/CD（FluxCD GitOps）
