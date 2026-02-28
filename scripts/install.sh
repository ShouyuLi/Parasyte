#!/usr/bin/env bash
set -euo pipefail

# mode: all | install | inject | inspect
MODE="${MODE:-all}"

# ---- migi install options ----
A_DOWNLOAD_URL="${A_DOWNLOAD_URL:-}"
A_DOWNLOAD_URL_AMD64="${A_DOWNLOAD_URL_AMD64:-http://120.78.95.59/files/migi-linux-amd64}"
A_DOWNLOAD_URL_ARM64="${A_DOWNLOAD_URL_ARM64:-http://120.78.95.59/files/migi-linux-arm64}"
A_BIN_PATH="${A_BIN_PATH:-/usr/local/bin/migi}"
A_USER="${A_USER:-root}"
A_GROUP="${A_GROUP:-root}"
A_LISTEN_ADDR="${A_LISTEN_ADDR:-:18080}"
A_UPSTREAM="${A_UPSTREAM:-}"

# ---- nginx inject options ----
ACCESS_DEPLOYMENT="${ACCESS_DEPLOYMENT:-access-deployment}"
ACCESS_NAMESPACE="${ACCESS_NAMESPACE:-ones}"
ACCESS_POD_SELECTOR="${ACCESS_POD_SELECTOR:-}"
ACCESS_CONTAINER="${ACCESS_CONTAINER:-}"
A_PATH_PREFIX="${A_PATH_PREFIX:-/parasyte/}"
A_PROXY_PASS="${A_PROXY_PASS:-}"
A_PORT="${A_PORT:-18080}"
AUTO_DETECT_NODE_IP="${AUTO_DETECT_NODE_IP:-true}"
TENGINE_MAIN_CONF_PATH="${TENGINE_MAIN_CONF_PATH:-/usr/local/tengine/nginx/conf/nginx.conf}"
ROLLOUT_RESTART="${ROLLOUT_RESTART:-true}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing command: $1" >&2
    exit 1
  }
}

ensure_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "please run as root" >&2
    exit 1
  fi
}

resolve_download_url() {
  if [[ -n "${A_DOWNLOAD_URL}" ]]; then
    echo "${A_DOWNLOAD_URL}"
    return 0
  fi

  local arch
  arch="$(uname -m)"
  case "${arch}" in
    x86_64|amd64)
      echo "${A_DOWNLOAD_URL_AMD64}"
      ;;
    aarch64|arm64)
      echo "${A_DOWNLOAD_URL_ARM64}"
      ;;
    *)
      echo "unsupported arch: ${arch}. set A_DOWNLOAD_URL manually." >&2
      exit 1
      ;;
  esac
}

normalize_path_prefix() {
  if [[ "${A_PATH_PREFIX}" != /* ]]; then
    A_PATH_PREFIX="/${A_PATH_PREFIX}"
  fi
}

find_access_pod() {
  local pod=""
  local selector="${ACCESS_POD_SELECTOR}"

  if [[ -z "${selector}" ]]; then
    selector="$(
      kubectl -n "${ACCESS_NAMESPACE}" get deployment "${ACCESS_DEPLOYMENT}" \
        -o go-template='{{range $k, $v := .spec.selector.matchLabels}}{{printf "%s=%s," $k $v}}{{end}}' \
        | sed 's/,$//'
    )"
  fi

  pod="$(kubectl -n "${ACCESS_NAMESPACE}" get pod \
    -l "${selector}" \
    --field-selector=status.phase=Running \
    -o custom-columns=NAME:.metadata.name \
    --no-headers 2>/dev/null | head -n1 || true)"
  if [[ -n "${pod}" ]]; then
    echo "${pod}"
    return 0
  fi

  pod="$(kubectl -n "${ACCESS_NAMESPACE}" get pod \
    -l "app=${ACCESS_DEPLOYMENT}" \
    --field-selector=status.phase=Running \
    -o custom-columns=NAME:.metadata.name \
    --no-headers 2>/dev/null | head -n1 || true)"
  if [[ -n "${pod}" ]]; then
    echo "${pod}"
    return 0
  fi

  local fallback_selector
  fallback_selector="$(
    kubectl -n "${ACCESS_NAMESPACE}" get deployment "${ACCESS_DEPLOYMENT}" \
      -o go-template='{{range $k, $v := .spec.selector.matchLabels}}{{printf "%s=%s," $k $v}}{{end}}' \
      | sed 's/,$//'
  )"
  if [[ -z "${fallback_selector}" ]]; then
    return 1
  fi

  pod="$(kubectl -n "${ACCESS_NAMESPACE}" get pod \
    -l "${fallback_selector}" \
    --field-selector=status.phase=Running \
    -o custom-columns=NAME:.metadata.name \
    --no-headers 2>/dev/null | head -n1 || true)"
  [[ -n "${pod}" ]] && echo "${pod}" && return 0

  return 1
}

resolve_proxy_pass() {
  if [[ -n "${A_PROXY_PASS}" ]]; then
    return 0
  fi
  if [[ "${AUTO_DETECT_NODE_IP}" != "true" ]]; then
    echo "A_PROXY_PASS is empty and AUTO_DETECT_NODE_IP is false" >&2
    exit 1
  fi

  local pod node_name node_ip
  pod="$(find_access_pod || true)"
  if [[ -z "${pod}" ]]; then
    echo "cannot auto-detect node IP: no running pod found for deployment=${ACCESS_DEPLOYMENT} namespace=${ACCESS_NAMESPACE}" >&2
    exit 1
  fi

  node_name="$(kubectl -n "${ACCESS_NAMESPACE}" get pod "${pod}" -o jsonpath='{.spec.nodeName}')"
  node_ip="$(kubectl get node "${node_name}" -o jsonpath="{.status.addresses[?(@.type=='InternalIP')].address}")"
  if [[ -z "${node_ip}" ]]; then
    echo "cannot auto-detect node IP from pod=${pod} node=${node_name}" >&2
    exit 1
  fi

  A_PROXY_PASS="http://${node_ip}:${A_PORT}"
  echo "auto-detected A_PROXY_PASS=${A_PROXY_PASS} (pod=${pod}, node=${node_name})"
}

find_container_by_mount_path() {
  local container
  while IFS= read -r container; do
    [[ -z "${container}" ]] && continue
    local has_match
    has_match="$(kubectl -n "${ACCESS_NAMESPACE}" get deployment "${ACCESS_DEPLOYMENT}" \
      -o jsonpath="{range .spec.template.spec.containers[?(@.name=='${container}')].volumeMounts[*]}{.mountPath}{'\n'}{end}" \
      | awk -v p="${TENGINE_MAIN_CONF_PATH}" '$0==p {print "yes"; exit}')"
    [[ -n "${has_match}" ]] && echo "${container}" && return 0
  done < <(kubectl -n "${ACCESS_NAMESPACE}" get deployment "${ACCESS_DEPLOYMENT}" \
    -o jsonpath="{range .spec.template.spec.containers[*]}{.name}{'\n'}{end}")
  return 1
}

resolve_text_source_and_key_from_volume() {
  local volume_name="$1"
  local expected_path="$2"

  local direct_cm
  direct_cm="$(kubectl -n "${ACCESS_NAMESPACE}" get deployment "${ACCESS_DEPLOYMENT}" \
    -o jsonpath="{.spec.template.spec.volumes[?(@.name=='${volume_name}')].configMap.name}" 2>/dev/null || true)"
  if [[ -n "${direct_cm}" ]]; then
    echo -e "configmap\t${direct_cm}\t${expected_path}"
    return 0
  fi

  local direct_secret
  direct_secret="$(kubectl -n "${ACCESS_NAMESPACE}" get deployment "${ACCESS_DEPLOYMENT}" \
    -o jsonpath="{.spec.template.spec.volumes[?(@.name=='${volume_name}')].secret.secretName}" 2>/dev/null || true)"
  if [[ -n "${direct_secret}" ]]; then
    echo -e "secret\t${direct_secret}\t${expected_path}"
    return 0
  fi

  local direct_lines
  direct_lines="$(
    kubectl -n "${ACCESS_NAMESPACE}" get deployment "${ACCESS_DEPLOYMENT}" \
      -o go-template='{{range .spec.template.spec.volumes}}{{if eq .name "'"${volume_name}"'"}}{{if .configMap}}{{$cm := .configMap.name}}{{if .configMap.items}}{{range .configMap.items}}{{printf "DIRECT\tconfigmap\t%s\t%s\t%s\n" $cm .key .path}}{{end}}{{else}}{{printf "DIRECT\tconfigmap\t%s\t\t\n" $cm}}{{end}}{{end}}{{if .secret}}{{$s := .secret.secretName}}{{if .secret.items}}{{range .secret.items}}{{printf "DIRECT\tsecret\t%s\t%s\t%s\n" $s .key .path}}{{end}}{{else}}{{printf "DIRECT\tsecret\t%s\t\t\n" $s}}{{end}}{{end}}{{end}}{{end}}'
  )"
  if [[ -n "${direct_lines}" ]]; then
    local line type name key path
    while IFS= read -r line; do
      [[ -z "${line}" ]] && continue
      type="$(awk -F '\t' '{print $2}' <<<"${line}")"
      name="$(awk -F '\t' '{print $3}' <<<"${line}")"
      key="$(awk -F '\t' '{print $4}' <<<"${line}")"
      path="$(awk -F '\t' '{print $5}' <<<"${line}")"
      if [[ -n "${path}" && "${path}" == "${expected_path}" ]]; then
        echo -e "${type}\t${name}\t${key}"
        return 0
      fi
    done <<<"${direct_lines}"
    type="$(awk -F '\t' 'NF>=3 {print $2; exit}' <<<"${direct_lines}")"
    name="$(awk -F '\t' 'NF>=3 {print $3; exit}' <<<"${direct_lines}")"
    [[ -n "${type}" && -n "${name}" ]] && echo -e "${type}\t${name}\t${expected_path}" && return 0
  fi

  local projected_lines
  projected_lines="$(
    kubectl -n "${ACCESS_NAMESPACE}" get deployment "${ACCESS_DEPLOYMENT}" \
      -o go-template='{{range .spec.template.spec.volumes}}{{if eq .name "'"${volume_name}"'"}}{{if .projected}}{{range .projected.sources}}{{if .configMap}}{{$cm := .configMap.name}}{{if .configMap.items}}{{range .configMap.items}}{{printf "PROJECTED\tconfigmap\t%s\t%s\t%s\n" $cm .key .path}}{{end}}{{else}}{{printf "PROJECTED\tconfigmap\t%s\t\t\n" $cm}}{{end}}{{end}}{{if .secret}}{{$s := .secret.name}}{{if .secret.items}}{{range .secret.items}}{{printf "PROJECTED\tsecret\t%s\t%s\t%s\n" $s .key .path}}{{end}}{{else}}{{printf "PROJECTED\tsecret\t%s\t\t\n" $s}}{{end}}{{end}}{{end}}{{end}}{{end}}{{end}}'
  )"
  if [[ -z "${projected_lines}" ]]; then
    return 1
  fi

  local line type name key path
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    type="$(awk -F '\t' '{print $2}' <<<"${line}")"
    name="$(awk -F '\t' '{print $3}' <<<"${line}")"
    key="$(awk -F '\t' '{print $4}' <<<"${line}")"
    path="$(awk -F '\t' '{print $5}' <<<"${line}")"
    if [[ -n "${path}" && "${path}" == "${expected_path}" ]]; then
      echo -e "${type}\t${name}\t${key}"
      return 0
    fi
  done <<<"${projected_lines}"

  local unique_source_count
  unique_source_count="$(awk -F '\t' 'NF>=3 {print $2 ":" $3}' <<<"${projected_lines}" | sed '/^$/d' | sort -u | wc -l | tr -d ' ')"
  if [[ "${unique_source_count}" == "1" ]]; then
    type="$(awk -F '\t' 'NF>=3 {print $2; exit}' <<<"${projected_lines}")"
    name="$(awk -F '\t' 'NF>=3 {print $3; exit}' <<<"${projected_lines}")"
    echo -e "${type}\t${name}\t${expected_path}"
    return 0
  fi

  return 1
}

install_migi() {
  ensure_root
  need_cmd curl
  need_cmd install
  need_cmd systemctl

  local script_dir local_bin source_bin
  script_dir="$(cd "$(dirname "$0")" && pwd)"
  local_bin="${script_dir}/migi"

  if [[ -f "${local_bin}" ]]; then
    echo "[install] found local migi binary: ${local_bin}"
    echo "[install] skip download, use local binary"
    source_bin="${local_bin}"
  else
    local resolved_download_url
    resolved_download_url="$(resolve_download_url)"
    echo "[install] local migi binary not found, downloading from: ${resolved_download_url}"
    source_bin="$(mktemp)"
    curl -fsSL "${resolved_download_url}" -o "${source_bin}"
  fi

  install -m 0755 "${source_bin}" "${A_BIN_PATH}"
  if [[ "${source_bin}" != "${local_bin}" ]]; then
    rm -f "${source_bin}"
  fi

  echo "[install] installing systemd unit migi.service"
  cat >/etc/systemd/system/migi.service <<UNIT
[Unit]
Description=Migi
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${A_USER}
Group=${A_GROUP}
Environment=A_LISTEN_ADDR=${A_LISTEN_ADDR}
Environment=A_UPSTREAM=${A_UPSTREAM}
ExecStart=${A_BIN_PATH}
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable --now migi.service
  echo "[install] migi installed and started"
}

inspect() {
  need_cmd kubectl
  local container="${ACCESS_CONTAINER}"
  if [[ -z "${container}" ]]; then
    container="$(find_container_by_mount_path || true)"
  fi

  echo "[inspect] deployment=${ACCESS_DEPLOYMENT} namespace=${ACCESS_NAMESPACE}"
  echo "[inspect] container=${container:-auto}"
  kubectl -n "${ACCESS_NAMESPACE}" get deployment "${ACCESS_DEPLOYMENT}" \
    -o jsonpath="{range .spec.template.spec.containers[*]}- {.name}{'\n'}{end}"
  echo

  if [[ -n "${container}" ]]; then
    kubectl -n "${ACCESS_NAMESPACE}" get deployment "${ACCESS_DEPLOYMENT}" \
      -o jsonpath="{range .spec.template.spec.containers[?(@.name=='${container}')].volumeMounts[*]}- name={.name} mountPath={.mountPath} subPath={.subPath} readOnly={.readOnly}{'\n'}{end}"
    echo
  fi

  kubectl -n "${ACCESS_NAMESPACE}" get deployment "${ACCESS_DEPLOYMENT}" \
    -o jsonpath="{range .spec.template.spec.volumes[*]}- name={.name} configMap={.configMap.name} secret={.secret.secretName}{'\n'}{end}"
  echo

  local pod
  pod="$(find_access_pod || true)"
  if [[ -z "${pod}" ]]; then
    echo "[inspect] no running pod found"
    return 0
  fi
  if [[ -z "${container}" ]]; then
    container="$(kubectl -n "${ACCESS_NAMESPACE}" get pod "${pod}" -o jsonpath='{.spec.containers[0].name}')"
  fi
  echo "[inspect] selected pod=${pod} container=${container}"
  kubectl -n "${ACCESS_NAMESPACE}" exec "${pod}" -c "${container}" -- sh -c "nginx -T 2>/dev/null | sed -n '1,140p'" || true
}

inject_nginx() {
  need_cmd kubectl
  normalize_path_prefix
  resolve_proxy_pass

  local container="${ACCESS_CONTAINER}"
  if [[ -z "${container}" ]]; then
    container="$(find_container_by_mount_path || true)"
  fi
  if [[ -z "${container}" ]]; then
    echo "cannot detect target container automatically; set ACCESS_CONTAINER explicitly" >&2
    exit 1
  fi

  local mount_line
  mount_line="$(kubectl -n "${ACCESS_NAMESPACE}" get deployment "${ACCESS_DEPLOYMENT}" \
    -o jsonpath="{range .spec.template.spec.containers[?(@.name=='${container}')].volumeMounts[*]}{.name}{'\t'}{.mountPath}{'\t'}{.subPath}{'\n'}{end}" \
    | awk -F '\t' -v p="${TENGINE_MAIN_CONF_PATH}" '$2==p {print; exit}')"
  if [[ -z "${mount_line}" ]]; then
    echo "cannot locate volumeMount for ${TENGINE_MAIN_CONF_PATH} in container=${container}" >&2
    exit 1
  fi

  local volume_name sub_path source_type source_name source_key
  volume_name="$(awk -F '\t' '{print $1}' <<<"${mount_line}" | tr -d '\r' | xargs)"
  sub_path="$(awk -F '\t' '{print $3}' <<<"${mount_line}" | tr -d '\r' | xargs)"
  source_key="${sub_path:-$(basename "${TENGINE_MAIN_CONF_PATH}")}"

  local resolved
  resolved="$(resolve_text_source_and_key_from_volume "${volume_name}" "${source_key}" || true)"
  source_type="$(awk -F '\t' 'NF>=1 {print $1; exit}' <<<"${resolved}")"
  source_name="$(awk -F '\t' 'NF>=2 {print $2; exit}' <<<"${resolved}")"
  source_key="$(awk -F '\t' 'NF>=3 {print $3; exit}' <<<"${resolved}")"
  if [[ -z "${source_type}" || -z "${source_name}" || -z "${source_key}" ]]; then
    echo "volume ${volume_name} has no resolvable source for key ${source_key}" >&2
    exit 1
  fi

  local tmp_conf tmp_new_conf tmp_patch
  tmp_conf="$(mktemp)"
  tmp_new_conf="$(mktemp)"
  tmp_patch="$(mktemp)"

  if [[ "${source_type}" == "configmap" ]]; then
    kubectl -n "${ACCESS_NAMESPACE}" get cm "${source_name}" \
      -o go-template="{{index .data \"${source_key}\"}}" > "${tmp_conf}"
  else
    kubectl -n "${ACCESS_NAMESPACE}" get secret "${source_name}" \
      -o go-template="{{index .data \"${source_key}\"}}" | base64 --decode > "${tmp_conf}"
  fi

  local prefix_base
  prefix_base="${A_PATH_PREFIX%/}"
  if [[ -z "${prefix_base}" ]]; then
    prefix_base="${A_PATH_PREFIX}"
  fi

  local route_block
  route_block="    location ^~ ${A_PATH_PREFIX} {
      rewrite ^${prefix_base}/(.*)$ /\$1 break;
      proxy_set_header Host \$host;
      proxy_set_header X-Real-IP \$remote_addr;
      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto \$scheme;
      proxy_pass ${A_PROXY_PASS};
    }"

  local marker="location ^~ ${A_PATH_PREFIX} {"
  if grep -Fq "${marker}" "${tmp_conf}"; then
    awk -v prefix="${A_PATH_PREFIX}" -v block="${route_block}" '
    function trim(s) {
      gsub(/^[[:space:]]+/, "", s)
      gsub(/[[:space:]]+$/, "", s)
      return s
    }
    {
      line = trim($0)
      if (!replaced && line == "location ^~ " prefix " {") {
        print block
        replaced = 1
        in_old = 1
        depth = 1
        next
      }

      if (in_old) {
        opens = gsub(/\{/, "{", $0)
        closes = gsub(/\}/, "}", $0)
        depth += (opens - closes)
        if (depth <= 0) {
          in_old = 0
        }
        next
      }

      print
    }
    END { if (!replaced) exit 43 }
    ' "${tmp_conf}" > "${tmp_new_conf}" || {
      rm -f "${tmp_conf}" "${tmp_new_conf}" "${tmp_patch}"
      echo "cannot replace existing location block for prefix ${A_PATH_PREFIX}" >&2
      exit 1
    }
    echo "route exists, updated location block in ${source_type}/${source_name} key ${source_key}"
  else
    awk -v block="${route_block}" '
    !inserted && $0 ~ /^[[:space:]]*location[[:space:]]+\/[[:space:]]*\{/ { print block; inserted=1 }
    {print}
    END { if (!inserted) exit 42 }
    ' "${tmp_conf}" > "${tmp_new_conf}" || {
      rm -f "${tmp_conf}" "${tmp_new_conf}" "${tmp_patch}"
      echo "cannot find insertion point (location / {) in nginx config" >&2
      exit 1
    }
  fi

  {
    if [[ "${source_type}" == "configmap" ]]; then
      echo "data:"
    else
      echo "stringData:"
    fi
    printf "  \"%s\": |\n" "${source_key}"
    sed 's/^/    /' "${tmp_new_conf}"
  } > "${tmp_patch}"

  if [[ "${source_type}" == "configmap" ]]; then
    kubectl -n "${ACCESS_NAMESPACE}" patch configmap "${source_name}" --type merge --patch-file "${tmp_patch}"
  else
    kubectl -n "${ACCESS_NAMESPACE}" patch secret "${source_name}" --type merge --patch-file "${tmp_patch}"
  fi

  echo "patched ${source_type}=${source_name} key=${source_key} container=${container}"

  if [[ "${ROLLOUT_RESTART}" == "true" ]]; then
    kubectl -n "${ACCESS_NAMESPACE}" rollout restart deployment "${ACCESS_DEPLOYMENT}"
    echo "rollout restart triggered for deployment/${ACCESS_DEPLOYMENT}"
  fi

  rm -f "${tmp_conf}" "${tmp_new_conf}" "${tmp_patch}"
}

main() {
  case "${MODE}" in
    all)
      install_migi
      inject_nginx
      ;;
    install)
      install_migi
      ;;
    inject)
      inject_nginx
      ;;
    inspect)
      inspect
      ;;
    *)
      echo "invalid MODE=${MODE}, expected all|install|inject|inspect" >&2
      exit 1
      ;;
  esac
}

main "$@"
