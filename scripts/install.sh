#!/usr/bin/env bash
set -euo pipefail

# 兼容入口：按顺序执行两个独立脚本
"$(dirname "$0")/install-migi.sh"
"$(dirname "$0")/inject-nginx-config.sh"
