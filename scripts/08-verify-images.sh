#!/usr/bin/env bash
# ============================================================================
# 08-verify-images.sh —— 核对节点上的预置镜像（只读）
#
# 用法：
#   bash 08-verify-images.sh node   # 所有节点应具备的基础镜像
#   bash 08-verify-images.sh full   # k8s-obs 应具备的完整镜像集
#
# 与 07-distribute-images.ps1 配合使用：分发后用本脚本核对结果。
# ============================================================================
set -uo pipefail

EXPECT_NODE=(
  "quay.io/prometheus/node-exporter:v1.8.2"
  "ghcr.io/chaos-mesh/chaos-daemon:v2.8.7"
)
EXPECT_FULL=(
  "${EXPECT_NODE[@]}"
  "quay.io/prometheus/prometheus:v2.55.0"
  "quay.io/prometheus/alertmanager:v0.28.1"
  "registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.14.0"
  "docker.io/grafana/grafana:11.4.0"
  "docker.io/grafana/loki:3.3.2"
  "docker.io/otel/opentelemetry-collector-contrib:0.116.0"
  "ghcr.io/chaos-mesh/chaos-mesh:v2.8.7"
  "ghcr.io/chaos-mesh/chaos-dashboard:v2.8.7"
  "ghcr.io/chaos-mesh/chaos-coredns:v0.2.8"
)

C_R=$'\033[0;31m'; C_G=$'\033[0;32m'; C_Y=$'\033[0;33m'; C_B=$'\033[0;36m'; C_0=$'\033[0m'

command -v crictl >/dev/null 2>&1 || { echo "未找到 crictl"; exit 1; }

GROUP="${1:-node}"
case "$GROUP" in
  node) LIST=("${EXPECT_NODE[@]}") ;;
  full) LIST=("${EXPECT_FULL[@]}") ;;
  *) echo "用法: bash 08-verify-images.sh {node|full}"; exit 1 ;;
esac

printf '%s节点 %s —— 镜像核对（%s 组，应有 %d 张）%s\n\n' \
  "$C_B" "$(hostname)" "$GROUP" "${#LIST[@]}" "$C_0"

HAVE="$(crictl images 2>/dev/null | awk 'NR>1 {print $1":"$2}')"
MISS=0
for item in "${LIST[@]}"; do
  repo="${item%:*}"
  tag="${item##*:}"
  if printf '%s\n' "$HAVE" | grep -qxF "${repo}:${tag}"; then
    printf '  %s✔%s %s\n' "$C_G" "$C_0" "$item"
  else
    printf '  %s✘%s %s  %s缺失%s\n' "$C_R" "$C_0" "$item" "$C_Y" "$C_0"
    MISS=$((MISS+1))
  fi
done

printf '\n'
if [ "$MISS" -eq 0 ]; then
  printf '%s全部就绪（%d/%d）%s\n' "$C_G" "${#LIST[@]}" "${#LIST[@]}" "$C_0"
else
  printf '%s缺失 %d 张。可从开发机执行 07-distribute-images.ps1 补齐%s\n' "$C_R" "$MISS" "$C_0"
  exit 1
fi