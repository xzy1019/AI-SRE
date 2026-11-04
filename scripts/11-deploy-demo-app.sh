#!/usr/bin/env bash
# ============================================================================
# 11-deploy-demo-app.sh —— 部署被测业务 demo-app（幂等）
#
# 用法： 在控制面执行  bash 11-deploy-demo-app.sh
#
# 部署内容（命名空间 demo-app）：
#   postgres(StatefulSet) / redis / frontend×2 / order×2 / payment×2 / loadgen
#
# 调用链路：loadgen → frontend → order → payment → postgres + redis
#   · frontend 在 k8s-app1，payment 在 k8s-app2：故意跨节点，便于做网络类混沌
#   · 每个服务暴露 /metrics（Prometheus 注解发现）、/healthz（探针）
#   · 应用代码放在 ConfigMap 里挂载，不依赖私有镜像仓库（见 README 脚本索引）
#
# 前置：
#   - 集群已就绪（03/04）
#   - 镜像已分发（07-distribute-images.ps1：postgres/redis/python/busybox）
#   - 可观测性栈已部署（09）：demo-app 的指标靠 Prometheus 注解发现
# ============================================================================
set -uo pipefail

D="/opt/aisre/manifests/demo-app"
C_R=$'\033[0;31m'; C_G=$'\033[0;32m'; C_Y=$'\033[0;33m'; C_B=$'\033[0;36m'; C_0=$'\033[0m'
ok()   { printf '  %s✔%s %s\n' "$C_G" "$C_0" "$*"; }
bad()  { printf '  %s✘%s %s\n' "$C_R" "$C_0" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_Y" "$C_0" "$*"; }
step() { printf '\n%s== %s ==%s\n' "$C_B" "$*" "$C_0"; }

[ "$(id -u)" -eq 0 ] || { echo "必须以 root 执行"; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "未找到 kubectl（本脚本需在控制面执行）"; exit 1; }
[ -d "$D" ] || { echo "目录不存在: $D"; exit 1; }

step "1/4 命名空间与配额"
kubectl apply -f "$D/00-namespace.yaml" 2>&1 | sed 's/^/  /'

step "2/4 数据层与应用层"
FAIL=0
for f in "$D"/0[1-5]-*.yaml; do
  printf '  %-30s ' "$(basename "$f")"
  OUT="$(kubectl apply -f "$f" 2>&1)"
  if echo "$OUT" | grep -qiE '^error'; then
    echo "${C_R}✘${C_0}"; echo "$OUT" | head -3 | sed 's/^/      /'; FAIL=$((FAIL+1))
  else
    echo "✔ $(echo "$OUT" | grep -c 'created\|configured\|unchanged') 个资源"
  fi
done
[ "$FAIL" -gt 0 ] && { echo; echo "有 $FAIL 个文件应用失败"; exit 1; }

step "3/4 等待工作负载就绪（最多 240s）"
# 说明：就绪判定写成 awk 时不要用反向引用（\1）—— awk 用的是 ERE，
# 不支持反向引用，表达式会永远为假、循环白等满超时。这里改成 split 比较。
for w in postgres redis frontend order payment loadgen; do
  kubectl -n demo-app rollout status "deploy/$w" --timeout=120s >/dev/null 2>&1 \
    || kubectl -n demo-app rollout status "statefulset/$w" --timeout=120s >/dev/null 2>&1 \
    || true
done
for i in $(seq 1 36); do
  TOT=$(kubectl -n demo-app get pods --no-headers 2>/dev/null | grep -vc 'Completed')
  RDY=$(kubectl -n demo-app get pods --no-headers 2>/dev/null \
        | awk '{split($2,a,"/"); if (a[1]==a[2] && a[2]>0) c++} END{print c+0}')
  [ "$TOT" -gt 0 ] && [ "$TOT" = "$RDY" ] && break
  sleep 5
done
if [ "${TOT:-0}" != "${RDY:-0}" ]; then
  bad "仍有 $((TOT-RDY)) 个 Pod 未就绪，最近事件："
  kubectl -n demo-app get events --sort-by=.lastTimestamp --no-headers 2>/dev/null | tail -5 | sed 's/^/      /'
fi

kubectl -n demo-app get pods -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[0].ready,NODE:.spec.nodeName,RESTARTS:.status.containerStatuses[0].restartCount --no-headers 2>&1 \
  | awk '{printf "  %-34s ready=%-6s node=%-10s restarts=%s\n", $1,$2,$3,$4}'

step "4/4 业务连通性自检"
POD="$(kubectl -n demo-app get pod -l app=frontend -o jsonpath='{.items[0].metadata.name}')"
if [ -n "$POD" ]; then
  CODE="$(kubectl -n demo-app exec "$POD" -- python3 -c "
import urllib.request
try:
    r = urllib.request.urlopen('http://order.demo-app.svc:8080/healthz', timeout=5)
    print(r.status)
except Exception as e:
    print('ERR', e)
" 2>/dev/null)"
  if [ "$CODE" = "200" ]; then ok "frontend → order 链路返回 200"
  else bad "frontend → order 返回: $CODE"; fi
fi

echo
printf '%s业务入口（集群内）：%s\n' "$C_B" "$C_0"
printf '  http://frontend.demo-app.svc:8080/     （loadgen 已在持续压测）\n'
printf '  服务发现：frontend / order / payment / postgres / redis\n'
echo
printf '%s提示：完整链路验证见 scripts/13-verify-e2e.sh%s\n' "$C_Y" "$C_0"