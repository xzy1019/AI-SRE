#!/usr/bin/env bash
# ============================================================================
# 32-apply-prometheus-config.sh —— 应用 Prometheus 配置/规则（备份 + 校验 + 可回滚）
#
# 用法（在控制面执行）：
#     bash 32-apply-prometheus-config.sh
#
# 为什么单独写一个脚本（而不是直接 kubectl apply）：
#   改告警规则是"改完当场生效、错了没人告诉你"的典型场景。
#   本脚本强制三步：先备份 → 再 apply → 最后**必须验证**（就绪 + 规则条数 + 新规则在不在），
#   任一步失败就打印回滚命令。与 P01/P29 同源：配置写了 ≠ 生效。
# ============================================================================
set -uo pipefail

D="/opt/aisre/manifests/observability"
NS=observability
CM=prometheus-config
BACKUP_DIR=/opt/aisre/backup
C_R=$'\033[0;31m'; C_G=$'\033[0;32m'; C_Y=$'\033[0;33m'; C_B=$'\033[0;36m'; C_0=$'\033[0m'
ok()   { printf '  %s✔%s %s\n' "$C_G" "$C_0" "$*"; }
bad()  { printf '  %s✘%s %s\n' "$C_R" "$C_0" "$*"; }
info() { printf '  %s·%s %s\n' "$C_B" "$C_0" "$*"; }
step() { printf '\n%s══ %s ══%s\n' "$C_B" "$*" "$C_0"; }

command -v kubectl >/dev/null 2>&1 || { echo "未找到 kubectl"; exit 1; }
[ -f "$D/03-prometheus.yaml" ] || { echo "找不到 $D/03-prometheus.yaml"; exit 1; }

# 期待存在的规则名（用于验证"新规则真的加载了"，不是"apply 返回成功"）
EXPECT_RULES="DemoAppHighErrorRateFast DemoAppDownstreamFailureFast DemoAppTrafficCollapse DemoAppDownstreamLatencyHigh ContainerCPUHigh"

step "1/5 备份当前运行的 ConfigMap"
mkdir -p "$BACKUP_DIR"
TS=$(date +%Y%m%d-%H%M%S)
BK="$BACKUP_DIR/prometheus-config-$TS.yaml"
kubectl -n "$NS" get cm "$CM" -o yaml > "$BK" 2>/dev/null && ok "已备份 → $BK" || bad "备份失败（继续，但无法一键回滚）"
echo "     回滚命令： kubectl apply -f $BK && kubectl -n $NS rollout restart deploy/prometheus"

step "2/5 计算配置指纹（改动前后对比）"
BEFORE_PROM=$(kubectl -n "$NS" get cm "$CM" -o jsonpath='{.data.prometheus\.yml}' | md5sum | awk '{print $1}')
BEFORE_RULES=$(kubectl -n "$NS" get cm "$CM" -o jsonpath='{.data.rules\.yml}' | md5sum | awk '{print $1}')
info "改动前 prometheus.yml=$BEFORE_PROM  rules.yml=$BEFORE_RULES"

step "3/5 应用清单"
OUT=$(kubectl apply -f "$D/03-prometheus.yaml" 2>&1)
echo "$OUT" | sed 's/^/     /'

step "4/5 滚动重启 Prometheus 并等待就绪"
kubectl -n "$NS" rollout restart deploy/prometheus >/dev/null 2>&1
if kubectl -n "$NS" rollout status deploy/prometheus --timeout=180s >/dev/null 2>&1; then
  ok "prometheus 就绪"
else
  bad "prometheus 未在 180s 内就绪 —— 配置可能不合法"
  echo "     排查： kubectl -n $NS logs deploy/prometheus --tail=30"
  echo "     回滚： kubectl apply -f $BK && kubectl -n $NS rollout restart deploy/prometheus"
  exit 1
fi

step "5/5 验证（就绪 ≠ 生效，必须查运行时状态）"
AFTER_PROM=$(kubectl -n "$NS" get cm "$CM" -o jsonpath='{.data.prometheus\.yml}' | md5sum | awk '{print $1}')
AFTER_RULES=$(kubectl -n "$NS" get cm "$CM" -o jsonpath='{.data.rules\.yml}' | md5sum | awk '{print $1}')
info "改动后 prometheus.yml=$AFTER_PROM  rules.yml=$AFTER_RULES"
[ "$BEFORE_RULES" != "$AFTER_RULES" ] && ok "rules.yml 已变化（说明确实写进去了）" || info "rules.yml 未变化（可能是重复应用）"

# 等 Prometheus 真正开始服务
for i in $(seq 1 30); do
  curl -sf http://127.0.0.1:30090/-/ready >/dev/null 2>&1 && break
  sleep 2
done

FAIL=0
# ① 规则是否加载
LOADED=$(curl -s http://127.0.0.1:30090/api/v1/rules | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    names=[r['name'] for g in d['data']['groups'] for r in g['rules']]
    print('\n'.join(names))
except Exception:
    pass" 2>/dev/null)
TOTAL=$(echo "$LOADED" | grep -c . || true)
info "Prometheus 已加载规则数：$TOTAL"
for r in $EXPECT_RULES; do
  if echo "$LOADED" | grep -qx "$r"; then ok "规则已加载：$r"
  else bad "规则未加载：$r"; FAIL=$((FAIL+1)); fi
done

# ② 新增抓取 job 是否真的抓到（up=1 才算数，P04 教训）
CAD=$(curl -s --get http://127.0.0.1:30090/api/v1/query --data-urlencode 'query=count(up{job="kubelet-cadvisor"}==1)' | python3 -c "
import json,sys
try:
    r=json.load(sys.stdin)['data']['result']; print(r[0]['value'][1] if r else 0)
except Exception: print(0)")
if [ "${CAD%.*}" -ge 1 ] 2>/dev/null; then ok "cAdvisor 抓取正常：$CAD 个 target up"
else bad "cAdvisor 未抓到（up!=1）→ ContainerCPUHigh 不会有数据"; FAIL=$((FAIL+1)); fi

echo
if [ "$FAIL" -eq 0 ]; then
  printf '%s全部验证通过。%s\n' "$C_G" "$C_0"
  echo "  查看告警： http://<节点IP>:30090/alerts"
  echo "  回滚：     kubectl apply -f $BK && kubectl -n $NS rollout restart deploy/prometheus"
  exit 0
else
  printf '%s有 %d 项验证未通过，请按上面提示排查/回滚。%s\n' "$C_R" "$FAIL" "$C_0"
  exit 1
fi
