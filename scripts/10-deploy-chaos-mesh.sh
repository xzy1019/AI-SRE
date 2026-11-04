#!/usr/bin/env bash
# ============================================================================
# 10-deploy-chaos-mesh.sh —— 部署 Chaos Mesh（幂等）
#
# 用法： 在控制面执行  bash 10-deploy-chaos-mesh.sh
#
# 前置：
#   - 集群已就绪（03/04）
#   - 镜像已分发（开发机执行 07-distribute-images.ps1）
#
# 注意：manifests/chaos-mesh/chaos-mesh.yaml 已做过三处修改，
#       直接使用上游原始清单会导致容器级混沌静默失败。详见 docs 第 5.9 节。
# ============================================================================
set -uo pipefail

M="/opt/aisre/manifests/chaos-mesh/chaos-mesh.yaml"
C_R=$'\033[0;31m'; C_G=$'\033[0;32m'; C_Y=$'\033[0;33m'; C_B=$'\033[0;36m'; C_0=$'\033[0m'
ok()   { printf '  %s✔%s %s\n' "$C_G" "$C_0" "$*"; }
bad()  { printf '  %s✘%s %s\n' "$C_R" "$C_0" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_Y" "$C_0" "$*"; }
step() { printf '\n%s== %s ==%s\n' "$C_B" "$*" "$C_0"; }

[ "$(id -u)" -eq 0 ] || { echo "必须以 root 执行"; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "未找到 kubectl"; exit 1; }
[ -f "$M" ] || { echo "清单不存在: $M"; exit 1; }

step "0/4 校验清单关键配置"
if grep -A1 '^            - --runtime$' "$M" | grep -q 'containerd'; then
  ok "chaos-daemon 运行时 = containerd"
else
  bad "chaos-daemon 运行时不是 containerd —— 容器级混沌会静默失败！"
  exit 1
fi
if grep -q 'tolerations' "$M"; then
  ok "chaos-daemon 含 tolerations（可覆盖控制面污点）"
else
  warn "未检测到 tolerations，chaos-daemon 可能不会部署到控制面"
fi

step "1/4 命名空间"
kubectl create namespace chaos-mesh --dry-run=client -o yaml | kubectl apply -f - 2>&1 | sed 's/^/  /'

step "2/4 应用 CRD（需服务端应用，避免 annotation 超限）"
if [ ! -f /tmp/chaos-crds.yaml ]; then
  python3 - "$M" > /tmp/chaos-crds.yaml <<'PY'
import sys, re
docs = open(sys.argv[1]).read().split('\n---\n')
out = [d for d in docs if re.search(r'^kind:\s*CustomResourceDefinition\s*$', d, re.M)]
print('\n---\n'.join(out))
PY
fi
CRDN=$(grep -c '^kind: CustomResourceDefinition' /tmp/chaos-crds.yaml)
warn "共 ${CRDN} 个 CRD。客户端 apply 对超大 CRD 会报 annotation 超限，故用服务端应用"
kubectl apply --server-side=true --force-conflicts -f /tmp/chaos-crds.yaml >/dev/null 2>&1
sleep 10
HAVE=$(kubectl get crd --no-headers 2>/dev/null | grep -c 'chaos-mesh.org')
if [ "$HAVE" = "$CRDN" ]; then ok "CRD 就绪 ${HAVE}/${CRDN}"; else bad "CRD 仅 ${HAVE}/${CRDN}"; fi

step "3/4 应用其余资源"
if [ ! -f /tmp/chaos-rest.yaml ]; then
  python3 - "$M" > /tmp/chaos-rest.yaml <<'PY'
import sys, re
docs = open(sys.argv[1]).read().split('\n---\n')
out = [d for d in docs if not re.search(r'^kind:\s*CustomResourceDefinition\s*$', d, re.M)]
print('\n---\n'.join(out))
PY
fi
kubectl apply -f /tmp/chaos-rest.yaml 2>&1 | grep -cE 'created|configured|unchanged' | xargs -I{} echo "  {} 个资源已应用"

step "4/4 等待就绪（最多 300s）"
for i in $(seq 1 60); do
  TOT=$(kubectl -n chaos-mesh get pods --no-headers 2>/dev/null | wc -l)
  RDY=$(kubectl -n chaos-mesh get pods --no-headers 2>/dev/null | awk '$2=="1/1"' | wc -l)
  [ "$TOT" -gt 0 ] && [ "$TOT" = "$RDY" ] && break
  sleep 5
done
kubectl -n chaos-mesh get pods -o wide --no-headers 2>&1 | awk '{printf "  %-42s %-6s %s\n", $1, $2, $7}'
echo
kubectl -n chaos-mesh get ds chaos-daemon --no-headers 2>&1 | awk '{printf "  chaos-daemon 覆盖: %s/%s 就绪\n", $4, $2}'

echo
printf '%s访问方式：%s\n' "$C_B" "$C_0"
printf '  Chaos Dashboard  kubectl -n chaos-mesh port-forward svc/chaos-dashboard 2333:2333\n'
printf '                   然后浏览器打开 http://localhost:2333\n'
echo
printf '%s提示：chaos-daemon 必须覆盖全部节点（含控制面）才能做节点级故障实验。%s\n' "$C_Y" "$C_0"