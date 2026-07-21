# Phase 4 准备：阿里云 ACR 镜像仓库配置

## 完成内容

为 Phase 4（短链服务部署）前置的镜像仓库配置——阿里云 ACR 个人版集成 K3s 集群。

### 新增文件
- `ansible/playbooks/templates/registries.yaml.j2` — K3s containerd 镜像仓库配置模板（Docker Hub 加速 + ACR VPC 认证）
- `ansible/playbooks/03-configure-acr.yml` — Ansible playbook：验证凭证 → 分发配置 → 滚动重启 K3s → 验证连通性
- `scripts/build-push.sh` — 本地 Docker 构建推送脚本
- `docs/phase-4-acr-setup.md` — 完整配置指南（方案选型、网络设计、认证方式、操作步骤、常见坑）
- `ansible/group_vars/all.yml.example` — 脱敏配置模板（入库）

### 修改文件
- `ansible/group_vars/all.yml` — 新增 ACR 变量（含真实凭证，已 gitignore 不入库）
- `.gitignore` — 添加 `group_vars/all.yml`

## 方案设计

- **ACR 个人版（新）**（免费）：`crpi-` 独占域名格式，2024-09-09 后创建
- **VPC 内网拉取**：`crpi-vvz6iv4av6k8awep-vpc.cn-hangzhou.personal.cr.aliyuncs.com`，零流量费
- **公网推送**：`crpi-vvz6iv4av6k8awep.cn-hangzhou.personal.cr.aliyuncs.com`（本地开发机）
- **registries.yaml 认证**：containerd 级别全局配置，Deployment 无需 imagePullSecrets
- **滚动重启**：`serial=1` 逐节点重启 K3s，保持集群 HA
- **凭证脱敏**：`all.yml` 加入 `.gitignore`，`all.yml.example` 入库

## 待用户操作

1. ~~阿里云控制台开通 ACR 个人版~~ ✅ 已完成
2. ~~填入 `acr_username` 和 `acr_password`~~ ✅ 已完成
3. 执行 `ansible-playbook -i inventory.ini playbooks/03-configure-acr.yml`
4. 推送测试镜像验证拉取链路

## 下一步

- Phase 4：编写短链服务 Dockerfile + K8s Deployment/Service/Ingress
- Phase 5：CI/CD（FluxCD GitOps）
