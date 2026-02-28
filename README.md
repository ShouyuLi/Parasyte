# Parasyte

这个项目使用一个统一脚本：`scripts/install.sh`。

- `MODE=all`（默认）：安装 migi + 注入 nginx 配置
- `MODE=install`：只安装 migi
- `MODE=inject`：只注入 nginx 配置
- `MODE=inspect`：只探测 nginx 配置来源

## migi 接口（当前）

- 服务启动后会自动在后台拉起 `kubectl proxy`（默认开启）：
  - `kubectl proxy --port=8080 --address=0.0.0.0 --accept-hosts='^.*$' --disable-filter=true`
  - 异常退出会自动重启
  - 连续失败达到 10 次后会暂停自动重启，需通过 `force_restart=true` 手动恢复
- 可通过 `A_ENABLE_KUBECTL_PROXY=false` 关闭该行为

- `GET /healthz`: 健康检查
- `GET/POST /proxy/status`: 查看 `kubectl proxy` 状态
  - query 参数 `force_restart=true` 可强制重启代理
  - 返回 JSON，包含 `enabled/running/pid/start_time/last_exit_time/last_error`
  - 还包含 `consecutive_failures/max_failures/auto_restart_paused`
- `POST /init`: 执行初始化第一步（固定命令）
  - `/root/sync_image_decoded.sh img.ones.pro/dev/telepresenceio/tel2:2.22.4 localhost:5000/ones/telepresenceio/tel2:2.22.4`
  - 响应体返回完整安装日志（stdout + stderr）
  - 可通过 `A_INIT_TIMEOUT` 配置超时（默认 `30m`）
- `POST /kubeconfig`: 导出并改写 kubeconfig
  - 先执行：`kubectl config view --raw`
  - 对每个 cluster：
    - 删除 `certificate-authority-data`
    - 增加 `insecure-skip-tls-verify: true`
    - 将 `server` 改为 `https://<ones_host>:6443`
  - `ones` 地址优先级：
    - query 参数 `ones_url`
    - 环境变量 `ONES_INSTANCE_URL`
    - 自动探测（在 `wiki-api` Pod 里读取 `/etc/hosts`，匹配 `k3s-dev.myones.net` 后缀，记录所有候选并选择第一个）
  - 可通过 `A_KUBECONFIG_TIMEOUT` 配置超时（默认 `30s`）
  - 自动探测相关参数：
    - `WIKI_API_NAMESPACE`（默认 `ones`）
    - `WIKI_API_POD_KEYWORD`（默认 `wiki-api`）
    - `ONES_DOMAIN_SUFFIX`（默认 `k3s-dev.myones.net`）
    - `A_ONES_DETECT_TIMEOUT`（默认 `30s`）

示例：

```bash
curl -X POST http://127.0.0.1:18080/init
```

```bash
curl -X POST "http://127.0.0.1:18080/kubeconfig?ones_url=https://ones.example.com"
```

```bash
curl "http://127.0.0.1:18080/proxy/status"
curl -X POST "http://127.0.0.1:18080/proxy/status?force_restart=true"
```

## 本地构建

```bash
go build -o bin/migi ./cmd/migi
```

也可以用 Make：

```bash
make build
```

## Release 构建（用于 GitHub Release 资产）

```bash
make release-build
```

输出文件在 `dist/`：
- `migi-linux-amd64`
- `migi-linux-arm64`
- `checksums.txt`

## 只做 nginx 注入

```bash
chmod +x scripts/install.sh

MODE=inject \
ACCESS_NAMESPACE="ones" \
ACCESS_DEPLOYMENT="access-deployment" \
# ACCESS_CONTAINER 可不填，脚本会自动按挂载路径探测
A_PATH_PREFIX="/parasyte/" \
./scripts/install.sh
```

注：注入后的规则会去掉前缀再转发，例如 `/parasyte/proxy/status` 会转发到 migi 的 `/proxy/status`。

默认会自动探测：
- 取 `access-deployment` 运行中 Pod 所在 Node 的 `InternalIP`
- 组合为 `A_PROXY_PASS=http://<NODE_INTERNAL_IP>:<A_PORT>`（默认端口 `18080`）

你也可以手动覆盖：

```bash
MODE=inject A_PROXY_PASS="http://<UPSTREAM_HOST>:<UPSTREAM_PORT>" ./scripts/install.sh
```

### 先探测（不改配置）

```bash
MODE=inspect \
ACCESS_NAMESPACE="ones" \
ACCESS_DEPLOYMENT="access-deployment" \
./scripts/install.sh
```

## Python 临时服务联调示例

如果你要在“服务器宿主机”启动 Python 服务联调：

```bash
# 在宿主机启动，监听 18080
python3 -m http.server 18080 --bind 0.0.0.0
```

默认脚本会自动选择 Pod 所在节点 IP；你也可以手动指定：

```bash
A_PROXY_PASS="http://<NODE_INTERNAL_IP>:18080"
```

> 注意：不要用 `127.0.0.1`，那会指向 nginx Pod 自己，而不是宿主机。

## 安装 migi（仅安装）

```bash
chmod +x scripts/install.sh
sudo MODE=install \
     A_LISTEN_ADDR=":18080" \
     ./scripts/install.sh
```

安装逻辑说明：
- 若 `scripts/` 目录下存在本地二进制 `migi`，脚本会优先使用该本地文件并跳过下载
- 否则按机器架构自动下载：
  - `amd64/x86_64`: `http://120.78.95.59/files/migi-linux-amd64`
  - `arm64/aarch64`: `http://120.78.95.59/files/migi-linux-arm64`
- 也可通过 `A_DOWNLOAD_URL` 手动覆盖

## 一次完成安装 + 注入

```bash
sudo MODE=all \
     ACCESS_NAMESPACE="ones" \
     ACCESS_DEPLOYMENT="access-deployment" \
     A_PATH_PREFIX="/parasyte/" \
     ./scripts/install.sh
```

## 关键参数

- `A_PATH_PREFIX`: 匹配路径前缀（例：`/parasyte/`）
- `A_DOWNLOAD_URL`: 手动指定下载地址（可选，优先级最高）
- `A_DOWNLOAD_URL_AMD64`: amd64 默认下载地址（默认 `http://120.78.95.59/files/migi-linux-amd64`）
- `A_DOWNLOAD_URL_ARM64`: arm64 默认下载地址（默认 `http://120.78.95.59/files/migi-linux-arm64`）
- `A_PROXY_PASS`: tengine 转发目标（留空则自动探测）
- `A_PORT`: 自动探测时使用的目标端口（默认 `18080`）
- `AUTO_DETECT_NODE_IP`: 是否自动探测节点 IP（默认 `true`）
- `TENGINE_MAIN_CONF_PATH`: tengine 主配置路径（默认 `/usr/local/tengine/nginx/conf/nginx.conf`）
- `ACCESS_NAMESPACE` / `ACCESS_DEPLOYMENT` / `ACCESS_CONTAINER`: k8s 定位信息
- `ACCESS_POD_SELECTOR`: 可选，手动指定查找 access Pod 的 label selector（默认自动读取 deployment 的 `spec.selector.matchLabels`）
