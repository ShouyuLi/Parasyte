#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  parasyte-local-setup.sh --host <xxxx-k3s-YY.k3s-dev.myones.net> [options]

Options:
  --host <host>               Required. Target host for /parasyte endpoints.
  --namespace <ns>            Kubernetes namespace for telepresence connect. Default: ones
  --kube-namespace <ns>       Namespace for kubectl pod check. Default: ones
  --kube-grep <pattern>       Grep pattern for kubectl check. Default: project-api
  --skip-init                 Skip POST /parasyte/init
  --skip-telepresence         Skip telepresence install/helm/connect/status/curl checks
  --no-auto-install           Do not install missing kubectl/telepresence automatically
  --curl-insecure             Add -k to curl requests
  -h, --help                  Show this help
EOF
}

log() {
  printf '[parasyte] %s\n' "$*"
}

fail() {
  printf '[parasyte][error] %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

install_with_brew() {
  local formula="$1"
  need_cmd brew || fail "缺少 brew，无法自动安装 ${formula}。请先手动安装后重试。"
  log "安装 ${formula}"
  brew install "${formula}"
}

HOST=""
NAMESPACE="ones"
KUBE_NAMESPACE="ones"
KUBE_GREP="project-api"
SKIP_INIT="false"
SKIP_TELEPRESENCE="false"
AUTO_INSTALL="true"
CURL_INSECURE="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      HOST="${2:-}"
      shift 2
      ;;
    --namespace)
      NAMESPACE="${2:-}"
      shift 2
      ;;
    --kube-namespace)
      KUBE_NAMESPACE="${2:-}"
      shift 2
      ;;
    --kube-grep)
      KUBE_GREP="${2:-}"
      shift 2
      ;;
    --skip-init)
      SKIP_INIT="true"
      shift
      ;;
    --skip-telepresence)
      SKIP_TELEPRESENCE="true"
      shift
      ;;
    --no-auto-install)
      AUTO_INSTALL="false"
      shift
      ;;
    --curl-insecure)
      CURL_INSECURE="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "未知参数: $1"
      ;;
  esac
done

[[ -n "${HOST}" ]] || fail "请提供 --host。示例: --host x2113-k3s-5.k3s-dev.myones.net"
[[ "${HOST}" =~ ^[^.]+-k3s-[0-9]+\.k3s-dev\.myones\.net$ ]] || \
  fail "--host 格式不符合预期，应为 xxxx-k3s-YY.k3s-dev.myones.net（前缀可变，-k3s- 固定）"

PARASYTE_BASE="https://${HOST}/parasyte"
CURL_FLAGS=(-fsS)
if [[ "${CURL_INSECURE}" == "true" ]]; then
  CURL_FLAGS+=(-k)
fi

status_field_true() {
  local json="$1"
  local field="$2"
  echo "${json}" | grep -q "\"${field}\":[[:space:]]*true"
}

log "目标地址: ${PARASYTE_BASE}"

log "步骤 2: 检查 kubectl"
if ! need_cmd kubectl; then
  if [[ "${AUTO_INSTALL}" == "true" ]]; then
    install_with_brew kubectl
  else
    fail "本机缺少 kubectl，请先安装（macOS: brew install kubectl）"
  fi
fi
kubectl version --client >/dev/null
log "kubectl 可用"

log "步骤 3: 检查 migi/proxy 状态"
STATUS_JSON="$(curl "${CURL_FLAGS[@]}" "${PARASYTE_BASE}/proxy/status")"
status_field_true "${STATUS_JSON}" "enabled" || fail "proxy/status 显示 enabled=false"
status_field_true "${STATUS_JSON}" "running" || fail "proxy/status 显示 running=false"
if echo "${STATUS_JSON}" | grep -q '"auto_restart_paused":[[:space:]]*true'; then
  fail "proxy/status 显示 auto_restart_paused=true，请先远端恢复后重试"
fi
log "proxy/status 检查通过"

if [[ "${SKIP_INIT}" != "true" ]]; then
  log "执行 /init（可能耗时较长）"
  curl "${CURL_FLAGS[@]}" -X POST "${PARASYTE_BASE}/init" >/dev/null
  log "/init 完成"
fi

log "步骤 4: 配置 ~/.kube/config（自动备份）"
mkdir -p "${HOME}/.kube"
if [[ -f "${HOME}/.kube/config" ]]; then
  backup="${HOME}/.kube/config.bak.$(date +%Y%m%d%H%M%S)"
  cp "${HOME}/.kube/config" "${backup}"
  log "已备份现有 kubeconfig: ${backup}"
fi
curl "${CURL_FLAGS[@]}" -X POST "${PARASYTE_BASE}/kubeconfig" > "${HOME}/.kube/config"
log "kubeconfig 已写入 ${HOME}/.kube/config"

log "步骤 5: 验证远程 k3s 连接"
kubectl get po -n "${KUBE_NAMESPACE}" | grep "${KUBE_GREP}" >/dev/null || \
  fail "未找到匹配 ${KUBE_GREP} 的 Pod，请检查 kubeconfig 或集群状态"
log "kubectl 连接验证通过"

if [[ "${SKIP_TELEPRESENCE}" != "true" ]]; then
  log "步骤 6: 检查 telepresence"
  if ! need_cmd telepresence; then
    if [[ "${AUTO_INSTALL}" == "true" ]]; then
      install_with_brew telepresenceio/telepresence/telepresence-oss
    else
      fail "本机缺少 telepresence，请先安装（brew install telepresenceio/telepresence/telepresence-oss）"
    fi
  fi

  log "步骤 7: 检查并安装 telepresence traffic-manager"
  helm_args=(
    --set image.registry=localhost:5000/ones/telepresenceio,image.tag=2.22.4,agent.image.registry=localhost:5000/ones/telepresenceio,agent.image.tag=2.22.4
    --set 'client.dns.includeSuffixes={.advanced-tidb-pd,.advanced-tidb-tikv,kafka-ha}'
  )
  if kubectl get pods -A | grep -q traffic-manager; then
    log "检测到已有 traffic-manager，跳过安装"
  else
    log "未检测到 traffic-manager，执行 telepresence helm install"
    install_err_file="$(mktemp)"
    if ! telepresence helm install "${helm_args[@]}" 2>"${install_err_file}"; then
      cat "${install_err_file}" >&2 || true
      if grep -q "already installed" "${install_err_file}"; then
        log "install 提示已安装（release 已存在），执行一次 telepresence helm upgrade 兜底"
        telepresence helm upgrade "${helm_args[@]}" || \
          fail "telepresence helm upgrade 失败，请手动检查 telepresence/helm 状态"
      else
        fail "telepresence helm install 失败，请查看输出日志"
      fi
    fi
    rm -f "${install_err_file}" || true
  fi
  kubectl get pods -A | grep traffic-manager >/dev/null || \
    fail "未检测到 traffic-manager Pod"
  log "traffic-manager 安装验证通过"

  log "步骤 8: 建立 telepresence 连接并验证服务"
  log "先执行 telepresence quit，避免跨环境切换导致 connect 长时间等待"
  telepresence quit >/dev/null 2>&1 || true
  connect_err_file="$(mktemp)"
  if ! telepresence connect --namespace "${NAMESPACE}" 2>"${connect_err_file}"; then
    cat "${connect_err_file}" >&2 || true
    if grep -q "Cluster configuration changed" "${connect_err_file}"; then
      log "检测到集群配置已变化，自动执行 telepresence quit 后重连"
      telepresence quit >/dev/null 2>&1 || true
      telepresence connect --namespace "${NAMESPACE}" || \
        fail "telepresence 重连失败，请执行 telepresence quit 后手动重试"
    else
      fail "telepresence connect 失败，请查看日志: ~/Library/Logs/telepresence/connector.log"
    fi
  fi
  rm -f "${connect_err_file}" || true
  telepresence status >/dev/null
  curl "${CURL_FLAGS[@]}" "http://project-api-service/version" >/dev/null
  log "telepresence 联通验证通过"
fi

log "2-8 步执行完成"
