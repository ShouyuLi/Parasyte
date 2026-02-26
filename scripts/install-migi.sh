#!/usr/bin/env bash
set -euo pipefail

A_DOWNLOAD_URL="${A_DOWNLOAD_URL:-https://example.com/migi-linux-amd64}"
A_BIN_PATH="${A_BIN_PATH:-/usr/local/bin/migi}"
A_USER="${A_USER:-root}"
A_GROUP="${A_GROUP:-root}"
A_LISTEN_ADDR="${A_LISTEN_ADDR:-:18080}"
A_UPSTREAM="${A_UPSTREAM:-}"

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

install_a_binary() {
  echo "[1/2] downloading migi from: ${A_DOWNLOAD_URL}"
  local tmp_bin
  tmp_bin="$(mktemp)"
  curl -fsSL "${A_DOWNLOAD_URL}" -o "${tmp_bin}"
  install -m 0755 "${tmp_bin}" "${A_BIN_PATH}"
  rm -f "${tmp_bin}"
}

install_systemd_service() {
  echo "[2/2] installing systemd unit"
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
}

main() {
  ensure_root
  need_cmd curl
  need_cmd install
  need_cmd systemctl

  install_a_binary
  install_systemd_service

  echo "done. migi installed and started"
}

main "$@"
