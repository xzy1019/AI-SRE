#!/usr/bin/env bash
# ============================================================================
# 06-preload-images.sh —— 预拉取镜像并从国内源改名（幂等）
#
# 用法：
#   bash 06-preload-images.sh node      # 每台节点都需要（DaemonSet 类）
#   bash 06-preload-images.sh full      # 仅 k8s-obs（含 node 组全部镜像）
#
# 背景：quay.io / ghcr.io 的 manifest API 可达，但镜像层重定向到 AWS S3 /
#       GitHub CDN，国内 TLS 握手超时。因此从国内镜像源拉取，再用 ctr 改回
#       原始名称，使 k8s 清单可以保持上游原名不变。
#
# 前置：需先执行 02-node-runtime.sh（含 ghcr.io / docker.io 镜像加速配置）
# ============================================================================
set -uo pipefail

# 格式：目标镜像名|候选源1;候选源2;...
# 候选源按顺序尝试，第一个成功的用于改名。
IMAGES_NODE=(
  "quay.io/prometheus/node-exporter:v1.8.2|quay.m.daocloud.io/prometheus/node-exporter:v1.8.2;quay.io/prometheus/node-exporter:v1.8.2"
  "ghcr.io/chaos-mesh/chaos-daemon:v2.8.7|ghcr.m.daocloud.io/chaos-mesh/chaos-daemon:v2.8.7;ghcr.io/chaos-mesh/chaos-daemon:v2.8.7"
)
IMAGES_FULL=(
  "${IMAGES_NODE[@]}"
  "quay.io/prometheus/prometheus:v2.55.0|quay.m.daocloud.io/prometheus/prometheus:v2.55.0;quay.io/prometheus/prometheus:v2.55.0"
  "quay.io/prometheus/alertmanager:v0.28.1|quay.m.daocloud.io/prometheus/alertmanager:v0.28.1;quay.io/prometheus/alertmanager:v0.28.1"
  "registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.14.0|k8s.m.daocloud.io/kube-state-metrics/kube-state-metrics:v2.14.0;registry.cn-hangzhou.aliyuncs.com/google_containers/kube-state-metrics:v2.14.0;registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.14.0"
  "docker.io/grafana/grafana:11.4.0|docker.m.daocloud.io/grafana/grafana:11.4.0"
  "docker.io/grafana/loki:3.3.2|docker.m.daocloud.io/grafana/loki:3.3.2"
  "docker.io/otel/opentelemetry-collector-contrib:0.116.0|docker.m.daocloud.io/otel/opentelemetry-collector-contrib:0.116.0"
  "ghcr.io/chaos-mesh/chaos-mesh:v2.8.7|ghcr.m.daocloud.io/chaos-mesh/chaos-mesh:v2.8.7;ghcr.io/chaos-mesh/chaos-mesh:v2.8.7"
  "ghcr.io/chaos-mesh/chaos-dashboard:v2.8.7|ghcr.m.daocloud.io/chaos-mesh/chaos-dashboard:v2.8.7;ghcr.io/chaos-mesh/chaos-dashboard:v2.8.7"
  "ghcr.io/chaos-mesh/chaos-coredns:v0.2.8|ghcr.m.daocloud.io/chaos-mesh/chaos-coredns:v0.2.8;ghcr.io/chaos-mesh/chaos-coredns:v0.2.8"
)

PULL_TIMEOUT=${PULL_TIMEOUT:-1200}   # 单张镜像拉取上限（秒）

C_R=$'\033[0;31m'; C_G=$'\033[0;32m'; C_Y=$'\033[0;33m'; C_B=$'\033[0;36m'; C_0=$'\033[0m'
OK=0; SKIP=0; FAIL=0
ok()   { printf '  %s✔%s %s\n' "$C_G" "$C_0" "$*"; }
skip() { printf '  %s-%s %s\n' "$C_Y" "$C_0" "$*"; }
bad()  { printf '  %s✘%s %s\n' "$C_R" "$C_0" "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "必须以 root 执行"; exit 1; }
command -v crictl >/dev/null 2>&1 || { echo "未找到 crictl，请先执行 02-node-runtime.sh"; exit 1; }
command -v ctr    >/dev/null 2>&1 || { echo "未找到 ctr，请先执行 02-node-runtime.sh"; exit 1; }

GROUP="${1:-}"
case "$GROUP" in
  node) LIST=("${IMAGES_NODE[@]}") ;;
  full) LIST=("${IMAGES_FULL[@]}") ;;
  *) echo "用法: bash 06-preload-images.sh {node|full}"; exit 1 ;;
esac

printf '%s节点 %s —— 预拉取镜像（分组: %s，共 %d 张）%s\n' \
  "$C_B" "$(hostname)" "$GROUP" "${#LIST[@]}" "$C_0"

# 已存在的镜像名集合（用于幂等判断）
EXISTING="$(ctr -n k8s.io images ls -q 2>/dev/null || true)"

i=0
for entry in "${LIST[@]}"; do
  i=$((i+1))
  TARGET="${entry%%|*}"
  SOURCES="${entry#*|}"

  printf '\n[%d/%d] %s\n' "$i" "${#LIST[@]}" "$TARGET"

  if printf '%s\n' "$EXISTING" | grep -qxF "$TARGET"; then
    skip "已存在，跳过"
    SKIP=$((SKIP+1)); continue
  fi

  pulled=0
  IFS=';' read -r -a cands <<< "$SOURCES"
  for src in "${cands[@]}"; do
    printf '  → 尝试源: %s\n' "$src"
    t0=$(date +%s)
    if timeout "$PULL_TIMEOUT" crictl pull "$src" >/tmp/preload.log 2>&1; then
      printf '    拉取成功（%ds）\n' "$(( $(date +%s) - t0 ))"
      pulled=1
      break
    else
      reason=$(grep -oiE 'TLS handshake timeout|connection reset|context deadline exceeded|no such host|manifest unknown|not found|denied|unauthorized' /tmp/preload.log | head -1)
      printf '    失败（%ds）%s\n' "$(( $(date +%s) - t0 ))" "${reason:+  [$reason]}"
    fi
  done

  if [ "$pulled" -eq 1 ]; then
    if [ "$src" = "$TARGET" ]; then
      ok "已是目标名，无需改名"
    elif ctr -n k8s.io images tag "$src" "$TARGET" >/dev/null 2>&1; then
      ok "已改名 → $TARGET"
    else
      bad "改名失败（源: $src）"
      FAIL=$((FAIL+1)); continue
    fi
    OK=$((OK+1))
  else
    bad "所有候选源均失败"
    FAIL=$((FAIL+1))
  fi
done

printf '\n%s────────────────────────────────────%s\n' "$C_B" "$C_0"
printf '  成功 %s%d%s   跳过 %s%d%s   失败 %s%d%s\n' \
  "$C_G" "$OK" "$C_0" "$C_Y" "$SKIP" "$C_0" "$C_R" "$FAIL" "$C_0"
printf '%s────────────────────────────────────%s\n' "$C_B" "$C_0"
[ "$FAIL" -gt 0 ] && { printf '%s存在失败项，可重跑本脚本续传%s\n' "$C_R" "$C_0"; exit 1; }
printf '%s镜像预拉取完成%s\n' "$C_G" "$C_0"