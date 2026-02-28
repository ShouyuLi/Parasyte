---
name: parasyte-tool-guide
description: 指导用户安装、配置、验证并排障 Parasyte 工具链（`migi`、远程 `curl` 获取并执行 `install.sh`、`scripts/inject-nginx-config.sh`、`/parasyte/*` 接口）。当用户表达“控制 https://pXXXX-k3s-4.k3s-dev.myones.net”（其中 `pXXXX` 可变，域名后缀固定）或提到 Parasyte、migi、`/proxy/status`、`/init`、`/kubeconfig`、远程 k3s 接入、Telepresence 联调时触发本技能。
---

# Parasyte 使用指南

## 概览

使用本技能为用户提供可落地的 Parasyte 操作指导。
优先给出可直接执行的 shell 命令、明确的环境变量，以及每一步的验证动作。

## 触发规则

当用户出现以下表达时直接使用本技能：

1. “控制 `https://p2113-k3s-4.k3s-dev.myones.net`”这类请求（仅 `p2113` 可变）。
2. “帮我连远程 k3s / 拉起 parasyte / 检查 migi 状态”。
3. “执行 `/parasyte/proxy/status`、`/parasyte/init`、`/parasyte/kubeconfig`”。
4. “安装 telepresence 并打通 project-api-service”。

## 主流程（标准 0-8）

以下流程默认从用户输入目标域名开始。设：

```bash
TARGET_HOST="p2113-k3s-4.k3s-dev.myones.net"   # 用户口述的控制域名
PARASYTE_BASE="https://${TARGET_HOST}/parasyte"
```

如果用户给的是其他 `pXXXX`，只替换前缀编号，其他部分保持不变。

### 0. 识别触发

用户说“控制 `https://pXXXX-k3s-4.k3s-dev.myones.net`”即进入本流程。

### 1. 远程服务器安装并启动 migi

指导用户在目标服务器直接下载并执行安装脚本：

```bash
curl -fsSL http://120.78.95.59/files/install.sh -o /tmp/install.sh
chmod +x /tmp/install.sh
sudo /tmp/install.sh
```

说明：

1. 脚本会下载 `migi` 二进制并拉起服务。
2. 若目标机访问 GitHub 慢或失败，提示用户先本地构建 `migi`，再与脚本同目录执行安装。
3. 成功信号：`systemctl status migi --no-pager` 显示 `active (running)`。

### 2. 检查本地 kubectl

```bash
kubectl version --client
```

若未安装，指导用户执行：

```bash
brew install kubectl
```

### 3. 检查 migi 与 kube proxy 状态，状态正常后执行 init

```bash
curl "${PARASYTE_BASE}/proxy/status"
```

判定字段：

1. `enabled=true`
2. `running=true`
3. `auto_restart_paused=false`

满足后再执行：

```bash
curl -X POST "${PARASYTE_BASE}/init"
```

### 4. 配置本地 kubeconfig

检查目录：

```bash
ls -ld ~/.kube
```

若不存在：

```bash
mkdir -p ~/.kube
```

然后提示用户执行（必要时先备份 `~/.kube/config`）：

```bash
curl -X POST "${PARASYTE_BASE}/kubeconfig" > ~/.kube/config
```

### 5. 验证远程 k3s 连接

```bash
kubectl get po -n ones | grep project-api
```

成功时应看到 `project-api` 相关 Pod。

### 6. 检查本地 Telepresence

```bash
telepresence version
```

若未安装：

```bash
brew install telepresenceio/telepresence/telepresence-oss
```

### 7. 安装 telepresence traffic-manager 并验证

```bash
telepresence helm install \
  --set image.registry=localhost:5000/ones/telepresenceio,image.tag=2.22.4,agent.image.registry=localhost:5000/ones/telepresenceio,agent.image.tag=2.22.4 \
  --set 'client.dns.includeSuffixes={.advanced-tidb-pd,.advanced-tidb-tikv,kafka-ha}'
kubectl get pods -A | grep traffic-manager
```

成功示例：看到类似 `ambassador traffic-manager-xxxx`。

### 8. 建立连接并验证服务访问

```bash
telepresence connect --namespace ones
telepresence status
curl http://project-api-service/version
```

成功信号：`telepresence status` 为已连接，且 `curl` 返回版本信息。

## 本地自动化脚本（推荐执行 2-8）

优先使用仓库脚本自动完成 2-8 步：

```bash
chmod +x scripts/parasyte-local-setup.sh
./scripts/parasyte-local-setup.sh --host p2113-k3s-4.k3s-dev.myones.net
```

常用参数：

1. `--skip-init`：跳过 `/parasyte/init`。
2. `--skip-telepresence`：只做到 kubeconfig 与 kubectl 连通验证。
3. `--no-auto-install`：缺少依赖时不自动执行 `brew install`。
4. `--curl-insecure`：curl 增加 `-k`（证书环境异常时临时使用）。

## 关键说明

1. 优先基于用户提供的 `pXXXX-k3s-4.k3s-dev.myones.net` 生成所有 URL。
2. 若用户提供了不一致主机（例如 `-3` 与 `-4` 混用），先指出并默认使用用户最初声明的控制域名。
3. `init` 可能耗时较长，明确提示用户等待命令完成再继续下一步。
4. 涉及覆盖 `~/.kube/config` 时，必须提醒备份。

## 常见故障快速处理

1. `proxy/status` 异常：先检查远程 `migi` 服务日志。
```bash
systemctl status migi --no-pager
journalctl -u migi -n 200 --no-pager
```
2. `auto_restart_paused=true`：执行强制重启后重试。
```bash
curl -X POST "${PARASYTE_BASE}/proxy/status?force_restart=true"
```
3. `kubectl` 无法连通：重新拉取 kubeconfig 并检查当前上下文。
```bash
kubectl config current-context
kubectl cluster-info
```

## 输出约定

回复用户时固定包含：

1. 一行目标摘要。
2. 按执行顺序排列的精确命令。
3. 每条命令对应的成功信号。
4. 失败时的快速回滚或重试步骤。
