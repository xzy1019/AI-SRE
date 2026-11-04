#!/usr/bin/env bash
# ============================================================================
# 09-deploy-observability.sh —— 部署可观测性栈（幂等）
#
# 用法： 在控制面执行  bash 09-deploy-observability.sh
#
# 部署内容（命名空间 observability）：
#   node-exporter(DS) / kube-state-metrics / prometheus / alertmanager
#   loki / promtail(DS) / grafana
#
# 前置：
#   - 集群已就绪（03/04）
#   - 镜像已分发（开发机执行 07-distribute-images.ps1）
# ============================================================================
set -uo pipefail

D="/opt/aisre/manifests/observability"
C_R=$'\033[0;31m'; C_G=$'\033[0;32m'; C_Y=$'\033[0;33m'; C_B=$'\033[0;36m'; C_0=$'\033[0m'
ok()   { printf '  %s✔%s %s\n' "$C_G" "$C_0" "$*"; }
bad()  { printf '  %s✘%s %s\n' "$C_R" "$C_0" "$*"; }
step() { printf '\n%s== %s ==%s\n' "$C_B" "$*" "$C_0"; }

[ "$(id -u)" -eq 0 ] || { echo "必须以 root 执行"; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "未找到 kubectl（本脚本需在控制面执行）"; exit 1; }
[ -d "$D" ] || { echo "目录不存在: $D"; exit 1; }

step "1/3 命名空间与配额"
kubectl apply -f "$D/00-namespace.yaml" 2>&1 | sed 's/^/  /'

step "2/3 部署组件"
FAIL=0
for f in "$D"/0[1-7]-*.yaml; do
  printf '  %-30s ' "$(basename "$f")"
  OUT="$(kubectl apply -f "$f" 2>&1)"
  if echo "$OUT" | grep -qiE '^error'; then
    echo "${C_R}✘${C_0}"; echo "$OUT" | head -3 | sed 's/^/      /'; FAIL=$((FAIL+1))
  else
    echo "✔ $(echo "$OUT" | grep -c 'created\|configured\|unchanged') 个资源"
  fi
done
[ "$FAIL" -gt 0 ] && { echo; echo "有 $FAIL 个文件应用失败"; exit 1; }

step "3/3 等待就绪（最多 300s）"
for i in $(seq 1 60); do
  TOT=$(kubectl -n observability get pods --no-headers 2>/dev/null | wc -l)
  RDY=$(kubectl -n observability get pods --no-headers 2>/dev/null | awk '$2=="1/1"' | wc -l)
  [ "$TOT" -gt 0 ] && [ "$TOT" = "$RDY" ] && break
  sleep 5
done

echo
kubectl -n observability get pods --no-headers -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount 2>&1 | awk '{printf "  %-40s ready=%-6s restarts=%s\n", $1, $2, $3}'
echo
kubectl -n observability get svc --no-headers 2>&1 | awk '{printf "  svc: %-22s %-10s %s\n", $1, $2, $5}'

echo
printf '%s注意：promtail 在「没有业务 Pod 可采集」的节点上会显示 ready=false，这是正常行为。%s\n' "$C_Y" "$C_0"
printf '      部署业务负载后会自动转为就绪。\n'

echo
printf '%s访问方式（NodePort，在任意节点 IP 上）：%s\n' "$C_B" "$C_0"
printf '  Grafana       http://<节点IP>:30030   (admin / aisre-lab-admin)\n'
printf '  Prometheus    http://<节点IP>:30090\n'
printf '  Alertmanager  http://<节点IP>:30093\n'