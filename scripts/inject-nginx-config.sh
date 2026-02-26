#!/usr/bin/env bash
set -euo pipefail

MODE="${MODE:-inject}" # inject | inspect
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

normalize_path_prefix() {
  if [[ "${A_PATH_PREFIX}" != /* ]]; then
    A_PATH_PREFIX="/${A_PATH_PREFIX}"
  fi
}

find_access_pod() {
  local pod=""
  local selector="${ACCESS_POD_SELECTOR}"

  # Default: derive selector from deployment.spec.selector.matchLabels.
  if [[ -z "${selector}" ]]; then
    selector="$(
      kubectl -n "${ACCESS_NAMESPACE}" get deployment "${ACCESS_DEPLOYMENT}" \
        -o go-template='{{range $k, $v := .spec.selector.matchLabels}}{{printf "%s=%s," $k $v}}{{end}}' \
        | sed 's/,$//'
    )"
  fi

  # First try selector (derived from deployment unless explicitly provided).
  pod="$(kubectl -n "${ACCESS_NAMESPACE}" get pod \
    -l "${selector}" \
    --field-selector=status.phase=Running \
    -o custom-columns=NAME:.metadata.name \
    --no-headers 2>/dev/null | head -n1 || true)"
  if [[ -n "${pod}" ]]; then
    echo "${pod}"
    return 0
  fi

  # Fallback 1: historical convention: app=<deployment-name>
  pod="$(kubectl -n "${ACCESS_NAMESPACE}" get pod \
    -l "app=${ACCESS_DEPLOYMENT}" \
    --field-selector=status.phase=Running \
    -o custom-columns=NAME:.metadata.name \
    --no-headers 2>/dev/null | head -n1 || true)"
  if [[ -n "${pod}" ]]; then
    echo "${pod}"
    return 0
  fi

  # Fallback 2: build selector from deployment.spec.selector.matchLabels
  local selector
  selector="$(
    kubectl -n "${ACCESS_NAMESPACE}" get deployment "${ACCESS_DEPLOYMENT}" \
      -o go-template='{{range $k, $v := .spec.selector.matchLabels}}{{printf "%s=%s," $k $v}}{{end}}' \
      | sed 's/,$//'
  )"

  if [[ -z "${selector}" ]]; then
    return 1
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
    echo "hint: check deployment selector and pod status: kubectl -n ${ACCESS_NAMESPACE} get deploy ${ACCESS_DEPLOYMENT} -o yaml | sed -n '/selector:/,/template:/p'" >&2
    exit 1
  fi

  node_name="$(kubectl -n "${ACCESS_NAMESPACE}" get pod "${pod}" -o jsonpath='{.spec.nodeName}')"
  if [[ -z "${node_name}" ]]; then
    echo "cannot auto-detect node IP: pod ${pod} has no nodeName" >&2
    exit 1
  fi

  node_ip="$(kubectl get node "${node_name}" \
    -o jsonpath="{.status.addresses[?(@.type=='InternalIP')].address}")"
  if [[ -z "${node_ip}" ]]; then
    echo "cannot auto-detect node IP: node ${node_name} has no InternalIP" >&2
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
    if [[ -n "${has_match}" ]]; then
      echo "${container}"
      return 0
    fi
  done < <(kubectl -n "${ACCESS_NAMESPACE}" get deployment "${ACCESS_DEPLOYMENT}" \
    -o jsonpath="{range .spec.template.spec.containers[*]}{.name}{'\n'}{end}")

  return 1
}

resolve_text_source_and_key_from_volume() {
  local volume_name="$1"
  local expected_path="$2"

  # 1) Direct configMap volume.
  local direct_cm_jsonpath
  direct_cm_jsonpath="$(kubectl -n "${ACCESS_NAMESPACE}" get deployment "${ACCESS_DEPLOYMENT}" \
    -o jsonpath="{.spec.template.spec.volumes[?(@.name=='${volume_name}')].configMap.name}" 2>/dev/null || true)"
  if [[ -n "${direct_cm_jsonpath}" ]]; then
    echo -e "configmap\t${direct_cm_jsonpath}\t${expected_path}"
    return 0
  fi

  # 1.1) Direct secret volume.
  local direct_secret_jsonpath
  direct_secret_jsonpath="$(kubectl -n "${ACCESS_NAMESPACE}" get deployment "${ACCESS_DEPLOYMENT}" \
    -o jsonpath="{.spec.template.spec.volumes[?(@.name=='${volume_name}')].secret.secretName}" 2>/dev/null || true)"
  if [[ -n "${direct_secret_jsonpath}" ]]; then
    echo -e "secret\t${direct_secret_jsonpath}\t${expected_path}"
    return 0
  fi

  # Fallback direct parsing with go-template (configMap / secret + items mapping).
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

    # No items mapping: file path is key name.
    type="$(awk -F '\t' 'NF>=3 {print $2; exit}' <<<"${direct_lines}")"
    name="$(awk -F '\t' 'NF>=3 {print $3; exit}' <<<"${direct_lines}")"
    if [[ -n "${type}" && -n "${name}" ]]; then
      echo -e "${type}\t${name}\t${expected_path}"
      return 0
    fi
  fi

  # 2) Projected volume with one or more configMap/secret sources.
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

  # If no explicit path mapping, fallback to key==expected_path.
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    type="$(awk -F '\t' '{print $2}' <<<"${line}")"
    name="$(awk -F '\t' '{print $3}' <<<"${line}")"
    [[ -z "${type}" || -z "${name}" ]] && continue
    if [[ "${type}" == "configmap" ]]; then
      if kubectl -n "${ACCESS_NAMESPACE}" get cm "${name}" \
        -o go-template="{{if index .data \"${expected_path}\"}}yes{{end}}" 2>/dev/null | grep -q '^yes$'; then
        echo -e "${type}\t${name}\t${expected_path}"
        return 0
      fi
    else
      if kubectl -n "${ACCESS_NAMESPACE}" get secret "${name}" \
        -o go-template="{{if index .data \"${expected_path}\"}}yes{{end}}" 2>/dev/null | grep -q '^yes$'; then
        echo -e "${type}\t${name}\t${expected_path}"
        return 0
      fi
    fi
  done <<<"${projected_lines}"

  # If single candidate source exists, fallback with expected path as key.
  local unique_source_count
  unique_source_count="$(awk -F '\t' 'NF>=3 {print $2 ":" $3}' <<<"${projected_lines}" | sed '/^$/d' | sort -u | wc -l | tr -d ' ')"
  if [[ "${unique_source_count}" == "1" ]]; then
    type="$(awk -F '\t' 'NF>=3 {print $2; exit}' <<<"${projected_lines}")"
    name="$(awk -F '\t' 'NF>=3 {print $3; exit}' <<<"${projected_lines}")"
    echo -e "${type}\t${name}\t${expected_path}"
    return 0
  fi

  echo "cannot resolve source key by projected items for volume ${volume_name}, expected path=${expected_path}" >&2
  echo "${projected_lines}" >&2
  return 1
}

inspect() {
  local container="${ACCESS_CONTAINER}"
  if [[ -z "${container}" ]]; then
    container="$(find_container_by_mount_path || true)"
  fi

  echo "[inspect] deployment=${ACCESS_DEPLOYMENT} namespace=${ACCESS_NAMESPACE}"
  if [[ -n "${container}" ]]; then
    echo "[inspect] container=${container}"
  fi
  echo

  echo "[inspect] all containers:"
  kubectl -n "${ACCESS_NAMESPACE}" get deployment "${ACCESS_DEPLOYMENT}" \
    -o jsonpath="{range .spec.template.spec.containers[*]}- {.name}{'\n'}{end}"
  echo

  if [[ -n "${container}" ]]; then
    echo "[inspect] container volumeMounts:"
    kubectl -n "${ACCESS_NAMESPACE}" get deployment "${ACCESS_DEPLOYMENT}" \
      -o jsonpath="{range .spec.template.spec.containers[?(@.name=='${container}')].volumeMounts[*]}- name={.name} mountPath={.mountPath} subPath={.subPath} readOnly={.readOnly}{'\n'}{end}"
    echo
  fi

  echo "[inspect] deployment volumes:"
  kubectl -n "${ACCESS_NAMESPACE}" get deployment "${ACCESS_DEPLOYMENT}" \
    -o jsonpath="{range .spec.template.spec.volumes[*]}- name={.name} configMap={.configMap.name} projectedConfigMaps={range .projected.sources[*]}{.configMap.name},{end} secret={.secret.secretName} hostPath={.hostPath.path} pvc={.persistentVolumeClaim.claimName}{'\n'}{end}"
  echo
  echo "[inspect] projected configMap items(key->path):"
  kubectl -n "${ACCESS_NAMESPACE}" get deployment "${ACCESS_DEPLOYMENT}" \
    -o go-template='{{range .spec.template.spec.volumes}}{{if .projected}}volume={{.name}}{{"\n"}}{{range .projected.sources}}{{if .configMap}}  cm={{.configMap.name}}{{"\n"}}{{if .configMap.items}}{{range .configMap.items}}    key={{.key}} -> path={{.path}}{{"\n"}}{{end}}{{else}}    (all keys projected as-is){{"\n"}}{{end}}{{end}}{{end}}{{end}}{{end}}'
  echo

  local pod
  pod="$(find_access_pod)"
  if [[ -z "${pod}" ]]; then
    echo "[inspect] cannot find running pod for deployment=${ACCESS_DEPLOYMENT}"
    return 0
  fi

  if [[ -z "${container}" ]]; then
    container="$(kubectl -n "${ACCESS_NAMESPACE}" get pod "${pod}" -o jsonpath='{.spec.containers[0].name}')"
  fi

  echo "[inspect] selected pod=${pod}"
  echo "[inspect] using container=${container}"
  echo
  echo "[inspect] nginx -T (first 140 lines):"
  kubectl -n "${ACCESS_NAMESPACE}" exec "${pod}" -c "${container}" -- sh -c "nginx -T 2>/dev/null | sed -n '1,140p'" || true
  echo
  echo "[inspect] mounts related to nginx/conf in container:"
  kubectl -n "${ACCESS_NAMESPACE}" exec "${pod}" -c "${container}" -- sh -c "cat /proc/mounts | grep -E 'nginx|conf' || true"
}

inject() {
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
  source_key="${sub_path:-}"
  if [[ -z "${source_key}" ]]; then
    source_key="$(basename "${TENGINE_MAIN_CONF_PATH}")"
  fi

  local resolved
  resolved="$(resolve_text_source_and_key_from_volume "${volume_name}" "${source_key}" || true)"
  source_type="$(awk -F '\t' 'NF>=1 {print $1; exit}' <<<"${resolved}")"
  source_name="$(awk -F '\t' 'NF>=2 {print $2; exit}' <<<"${resolved}")"
  source_key="$(awk -F '\t' 'NF>=3 {print $3; exit}' <<<"${resolved}")"

  if [[ -z "${source_type}" || -z "${source_name}" || -z "${source_key}" ]]; then
    echo "volume ${volume_name} has no resolvable source for key ${source_key}" >&2
    echo "debug: container=${container}" >&2
    echo "debug: mount_line=${mount_line}" >&2
    echo "debug: volume candidates:" >&2
    kubectl -n "${ACCESS_NAMESPACE}" get deployment "${ACCESS_DEPLOYMENT}" \
      -o jsonpath="{range .spec.template.spec.volumes[*]}- {.name} cm={.configMap.name}{'\n'}{end}" >&2 || true
    echo "hint: run MODE=inspect to check projected configMap items/path mapping" >&2
    exit 1
  fi

  local tmp_conf tmp_new_conf
  local tmp_patch
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

  local marker
  marker="location ^~ ${A_PATH_PREFIX} {"
  if grep -Fq "${marker}" "${tmp_conf}"; then
    echo "route already exists in ${source_type}/${source_name} key ${source_key}, skip"
    rm -f "${tmp_conf}" "${tmp_new_conf}" "${tmp_patch}"
    return 0
  fi

  local route_block
  route_block="    location ^~ ${A_PATH_PREFIX} {
      proxy_set_header Host \$host;
      proxy_set_header X-Real-IP \$remote_addr;
      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto \$scheme;
      proxy_pass ${A_PROXY_PASS};
    }"

  awk -v block="${route_block}" '
    !inserted && $0 ~ /^[[:space:]]*location[[:space:]]+\/[[:space:]]*\{/ {
      print block
      inserted=1
    }
    {print}
    END {
      if (!inserted) {
        exit 42
      }
    }
  ' "${tmp_conf}" > "${tmp_new_conf}" || {
    rm -f "${tmp_conf}" "${tmp_new_conf}" "${tmp_patch}"
    echo "cannot find insertion point (location / {) in nginx config" >&2
    exit 1
  }

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
  need_cmd kubectl

  case "${MODE}" in
    inspect)
      inspect
      ;;
    inject)
      inject
      ;;
    *)
      echo "invalid MODE=${MODE}, expected inspect|inject" >&2
      exit 1
      ;;
  esac
}

main "$@"
