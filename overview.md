# Phase 4 准备：ACR 配置 + 安全加固

## 完成内容

### 1. MySQL 密码明文 → K8s Secret 迁移
将 `proxysql.yaml` 和 `orchestrator.yaml` 中硬编码的 MySQL 密码改为 K8s Secret + init container 方案：
- ConfigMap 只放 `__PLACEHOLDER__` 占位符
- init container 从 Secret 读取密码，用 `sed` 渲染最终配置到 emptyDir
- 主容器挂载渲染后的文件
- 验证：ProxySQL 读写分离 + Orchestrator 拓扑发现均正常

### 2. ACR Playbook 执行
`03-configure-acr.yml` 从 node-01 执行成功：
- 3 节点滚动重启 K3s（serial=1），全部零失败
- ACR VPC 域名连通性：3 节点均返回 HTTP 401（可达）
- registries.yaml 配置验证：3 节点均包含 ACR auth

## 新增/修改文件

| 文件 | 说明 |
|------|------|
| `k8s/data-layer/secret.yaml.example` | K8s Secret 脱敏模板（入库） |
| `k8s/data-layer/proxysql.yaml` | ConfigMap 占位符 + init container 渲染 |
| `k8s/data-layer/orchestrator.yaml` | 同上 + imagePullPolicy: IfNotPresent |
| `.gitignore` | 添加 `k8s/data-layer/secret.yaml` |

## ACR 配置摘要

- **VPC 拉取**：`crpi-vvz6iv4av6k8awep-vpc.cn-hangzhou.personal.cr.aliyuncs.com`
- **公网推送**：`crpi-vvz6iv4av6k8awep.cn-hangzhou.personal.cr.aliyuncs.com`
- **镜像地址**：`crpi-vvz6iv4av6k8awep-vpc.cn-hangzhou.personal.cr.aliyuncs.com/shortlink123/shortlink-app:v1`
- **K3s 全局免 imagePullSecret**：registries.yaml `configs` 段已配置 auth

## 下一步

- Phase 4：编写短链服务 Dockerfile + K8s Deployment/Service/Ingress
- Phase 5：CI/CD（FluxCD GitOps）
