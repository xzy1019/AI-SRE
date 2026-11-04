#!/usr/bin/env bash
# ============================================================================
# 28-selfheal-loop.sh —— 端到端自愈闭环演示（两阶段，可重复执行）
#
# 闭环链路：
#   注入故障 → 告警(firing) → 事件落盘 → 数据集导出 → 降噪/RCA → 策略校验
#            → 自动执行（滚动重启）→ SLI 恢复 → 审计哈希链
#
# 两阶段设计（因为 LLM RCA 跑在开发机、不在集群里）：
#   --stage prepare   集群侧：清混沌 → 打 GT 标签 → 基线 → 注入 → 等 firing → 导出数据集 → 降噪算 Top-1
#   --stage heal      集群侧：策略校验 → 执行 → 观察 SLI 恢复 → 审计校验 → 清理（GT 标签 + 混沌对象）
#
# 用法：
#   bash 28-selfheal-loop.sh --stage prepare --target payment --duration 90s
#   # （开发机侧跑 LLM RCA：python3 scripts/19-rca-llm.py <数据集> --topology topology/topology.json）
#   bash 28-selfheal-loop.sh --stage heal --dataset /opt/aisre/datasets/F02-xxxx --root-cause payment
#
# 不传 --root-cause 时用规则基线（correlation.json）的 Top-1；传了就用传入值（例如 LLM 的结论）。
# ============================================================================
set -uo pipefail

STAGE=""; TARGET="payment"; DURATION="90s"; DATASET=""; ROOT_CAUSE=""
CHAIN="payment,order,frontend"      # GT 标签打给整条链（只打根因 Pod 不够，见 P18）
OBSERVE_MAX=300                      # 等 firing 的最长秒数
RECOVER_MAX=420                      # 等恢复的最长秒数

while [ $# -gt 0 ]; do
  case "$1" in
    --stage) STAGE="$2"; shift 2;;
    --target) TARGET="$2"; shift 2;;
    --duration) DURATION="$2"; shift 2;;
    --dataset) DATASET="$2"; shift 2;;
    --root-cause) ROOT_CAUSE="$2"; shift 2;;
    *) echo "未知参数: $1"; exit 1;;
  esac
done

C_R=$'\033[0;31m'; C_G=$'\033[0;32m'; C_Y=$'\033[0;33m'; C_B=$'\033[0;36m'; C_0=$'\033[0m'
ts()  { date +%H:%M:%S; }
ok()  { printf '  %s✔%s [%s] %s\n' "$C_G" "$C_0" "$(ts)" "$*"; }
bad() { printf '  %s✘%s [%s] %s\n' "$C_R" "$C_0" "$(ts)" "$*"; }
step(){ printf '\n%s══ %s ══%s\n' "$C_B" "$*" "$C_0"; }
PROM=http://127.0.0.1:30090; AM=http://127.0.0.1:30093
q() { curl -s --get "$PROM/api/v1/query" --data-urlencode "query=$1" | python3 -c "import json,sys;r=json.load(sys.stdin)['data']['result'];print(r[0]['value'][1] if r else 0)" 2>/dev/null; }
ready() { kubectl -n demo-app get pods --no-headers 2>/dev/null | awk '{split($2,a,"/"); if(a[1]==a[2]) c++} END{print c+0}'; }
alerts() { curl -s $AM/api/v2/alerts | python3 -c "import json,sys;print(len(json.load(sys.stdin)))"; }
ingest_n() { kubectl -n aiops exec deploy/aisre-ingest -- wget -qO- http://127.0.0.1:8080/stats 2>/dev/null | python3 -c "import json,sys;print(json.load(sys.stdin)['alerts_received_total'])"; }
agent() { # agent <path> <json>
  FE=$(kubectl -n demo-app get pod -l app=frontend -o jsonpath='{.items[0].metadata.name}')
  kubectl -n demo-app exec "$FE" -- python3 -c "
import json,urllib.request,sys
path, body = sys.argv[1], sys.argv[2]
req=urllib.request.Request('http://aisre-agent.aiops.svc:8080'+path, data=body.encode(), headers={'Content-Type':'application/json'}, method='POST')
try:
    r=urllib.request.urlopen(req, timeout=30); print(r.read().decode())
except urllib.error.HTTPError as e:
    print(e.read().decode())
" "$1" "$2"
}
clean_chaos() { for t in podchaos networkchaos stresschaos iochaos httpchaos timechaos; do kubectl -n chaos-mesh delete $t --all --ignore-not-found >/dev/null 2>&1; done; }
sec() { date -u -d "$1" +%s 2>/dev/null || echo 0; }

# ============================ 阶段一：prepare ============================
if [ "$STAGE" = "prepare" ]; then
  echo "══════════════════════════════════════════════"
  printf '  端到端自愈闭环 · 阶段一（注入与取证）\n  目标=%s 时长=%s\n' "$TARGET" "$DURATION"
  echo "══════════════════════════════════════════════"

  step "0. 清理混沌对象（逐类型删除，避免 P27 的坑：一个类型不存在会导致整条命令中止）"
  clean_chaos
  ok "混沌对象剩余 $(kubectl -n chaos-mesh get podchaos,networkchaos --no-headers 2>/dev/null | wc -l) 个"

  step "1. 打 ground truth 标签（整条链，见 P18）"
  for a in $(echo "$CHAIN" | tr ',' ' '); do
    bash /opt/aisre/scripts/18-tag-ground-truth.sh set "$a" "$TARGET-service" >/dev/null 2>&1
  done
  ok "已给 $CHAIN 打上 ground-truth=$TARGET-service"

  step "2. 基线读数（注入前）"
  B_READY=$(ready); B_5XX=$(q 'sum(rate(http_requests_total{status=~"5.."}[1m]))'); B_AM=$(alerts); B_ING=$(ingest_n)
  printf '  [%s] ready=%s/9  5xx=%s  活动告警=%s  ingest=%s\n' "$(ts)" "$B_READY" "$B_5XX" "$B_AM" "$B_ING"

  step "3. 注入故障（T0）"
  T0=$(ts)
  cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: chaos-mesh.org/v1alpha1
kind: PodChaos
metadata:
  name: selfheal-demo-pod-failure
  namespace: chaos-mesh
spec:
  action: pod-failure
  mode: all
  selector:
    namespaces: [demo-app]
    labelSelectors: { app: $TARGET }
  duration: '$DURATION'
YAML
  ok "T0=$T0 已注入 pod-failure（$TARGET，$DURATION）"

  step "4. 观察直到告警 firing（每 15s 采样，最长 ${OBSERVE_MAX}s）"
  T_FIRE=""
  for i in $(seq 1 $((OBSERVE_MAX/15))); do
    R=$(ready); F=$(q 'count(ALERTS{alertstate="firing"})'); P=$(q 'count(ALERTS{alertstate="pending"})'); A=$(alerts); I=$(ingest_n)
    printf '  [%s] ready=%-4s pending=%-3s firing=%-3s AM=%-3s ingest=%s\n' "$(ts)" "$R/9" "$P" "$F" "$A" "$I"
    if [ "${F%.*}" -ge 1 ] 2>/dev/null; then T_FIRE=$(ts); break; fi
    sleep 15
  done
  [ -n "$T_FIRE" ] && ok "T_firing=$T_FIRE（从注入到 firing 约 $(( $(sec "$(date -u -d "$T_FIRE" +%Y-%m-%dT%H:%M:%SZ)") - $(sec "$(date -u -d "$T0" +%Y-%m-%dT%H:%M:%SZ)") )) s）" || bad "未在 ${OBSERVE_MAX}s 内看到 firing"

  step "5. 导出数据集（事件+指标+日志+GT）"
  bash /opt/aisre/scripts/15-export-dataset.sh "${TARGET^^}" "$TARGET-service" 20 2>&1 | tail -3
  DATASET=$(ls -1dt /opt/aisre/datasets/${TARGET^^}-*/ | head -1)
  ok "数据集 = $DATASET"

  step "6. 降噪 + 根因候选（规则基线）"
  python3 /opt/aisre/scripts/16-correlation-baseline.py "$DATASET" --window 90 --topology /opt/aisre/topology/topology.json 2>&1 | grep -E 'firing|事件簇|降噪率|候选精确率|候选召回率|排序=' | sed 's/^/  /'
  TOP1=$(python3 -c "
import json
d=json.load(open('$DATASET/correlation.json'))
best=None
for c in d['clusters']:
    for r in c.get('root_causes',[]):
        if r['service']!='unknown' and (best is None or r['score']>best[1]): best=(r['service'], r['score'])
print(best[0] if best else 'unknown')
")
  ok "规则基线 Top-1 根因 = $TOP1"

  echo
  printf '%s阶段一完成。下一步（开发机跑 LLM RCA，可选但推荐）：%s\n' "$C_B" "$C_0"
  printf '  python3 scripts/19-rca-llm.py <本地数据集副本> --topology topology/topology.json\n'
  printf '  然后执行阶段二（把 LLM 结论传进去）：\n'
  printf '  bash %s --stage heal --dataset %s --root-cause %s\n' "$0" "$DATASET" "$TOP1"
  exit 0
fi

# ============================ 阶段二：heal ============================
if [ "$STAGE" = "heal" ]; then
  [ -n "$DATASET" ] || { echo "缺少 --dataset"; exit 1; }
  [ -d "$DATASET" ] || { echo "数据集不存在: $DATASET"; exit 1; }
  if [ -z "$ROOT_CAUSE" ]; then
    ROOT_CAUSE=$(python3 -c "
import json
d=json.load(open('$DATASET/correlation.json'))
best=None
for c in d['clusters']:
    for r in c.get('root_causes',[]):
        if r['service']!='unknown' and (best is None or r['score']>best[1]): best=(r['service'], r['score'])
print(best[0] if best else 'unknown')
")
    ok "未指定 --root-cause，采用规则基线 Top-1 = $ROOT_CAUSE"
  else
    ok "采用传入的根因（例如 LLM RCA 的结论）= $ROOT_CAUSE"
  fi

  INC="selfheal-$(date +%s)"
  FE=$(kubectl -n demo-app get pod -l app=frontend -o jsonpath='{.items[0].metadata.name}')

  step "7. 策略校验（dry-run：8 条 check 逐条看）"
  T_POLICY=$(ts)
  OUT=$(agent /propose "{\"incident_id\":\"$INC\",\"action\":\"restart\",\"level\":\"L1\",\"target\":{\"namespace\":\"demo-app\",\"deployment\":\"$ROOT_CAUSE\"},\"reason\":\"RCA Top-1 root cause\",\"dry_run\":true}")
  echo "$OUT" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print('  allow=%s  violations=%s' % (d['allow'], d['violations'] or '无'))
for c in d['checks']: print('    %s %-18s %s' % ('✔' if c['pass'] else '✘', c['name'], c['detail'][:64]))
"
  ok "T_policy=$T_POLICY 策略校验完成"

  step "8. 自动执行（真实滚动重启）"
  T_EXEC=$(ts)
  BEFORE_ANN=$(kubectl -n demo-app get deploy "$ROOT_CAUSE" -o jsonpath='{.spec.template.metadata.annotations.kubectl\.kubernetes\.io/restartedAt}' 2>/dev/null)
  OUT=$(agent /execute "{\"incident_id\":\"$INC\",\"action\":\"restart\",\"level\":\"L1\",\"target\":{\"namespace\":\"demo-app\",\"deployment\":\"$ROOT_CAUSE\"},\"reason\":\"RCA Top-1 root cause\",\"dry_run\":false}")
  echo "$OUT" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print('  executed=%s detail=%s' % (d.get('executed'), d.get('detail')))
a=d.get('audit') or {}
if a: print('  审计: seq=%s hash=%s… prev=%s…' % (a.get('seq'), (a.get('hash') or '')[:12], (a.get('prev_hash') or '')[:12]))
"
  sleep 5
  AFTER_ANN=$(kubectl -n demo-app get deploy "$ROOT_CAUSE" -o jsonpath='{.spec.template.metadata.annotations.kubectl\.kubernetes\.io/restartedAt}' 2>/dev/null)
  [ -n "$AFTER_ANN" ] && [ "$AFTER_ANN" != "$BEFORE_ANN" ] && ok "T_exec=$T_EXEC 滚动重启已下发（restartedAt=$AFTER_ANN）" || bad "未观察到 restart 生效"

  step "9. 观察 SLI 恢复（每 20s 采样，最长 ${RECOVER_MAX}s）"
  T_RECOVER=""
  for i in $(seq 1 $((RECOVER_MAX/20))); do
    R=$(ready); F=$(q 'count(ALERTS{alertstate="firing"})'); X=$(q 'sum(rate(http_requests_total{status=~"5.."}[1m]))'); A=$(alerts)
    printf '  [%s] ready=%-4s firing=%-3s 5xx=%-6s AM=%-3s\n' "$(ts)" "$R/9" "$F" "$X" "$A"
    if [ "$R" = "9" ] && [ "${F%.*}" = "0" ] 2>/dev/null; then T_RECOVER=$(ts); break; fi
    sleep 20
  done
  [ -n "$T_RECOVER" ] && ok "T_recovered=$T_RECOVER（ready=9/9 且 firing=0）" || bad "未在 ${RECOVER_MAX}s 内完全恢复（可能是 5 分钟 rate 窗口残留）"

  step "10. 审计留痕校验"
  kubectl -n aiops exec deploy/aisre-agent -- wget -qO- http://127.0.0.1:8080/audit/verify 2>/dev/null | sed 's/^/  /'
  echo "  ── 独立复算（直接读 audit.jsonl 校验 prev_hash 链）──"
  kubectl -n aiops exec deploy/aisre-agent -- cat /data/audit.jsonl 2>/dev/null | python3 -c "
import json,sys
rows=[json.loads(l) for l in sys.stdin if l.strip()]
prev='0'*64; bad=[]
for i,r in enumerate(rows,1):
    if r['prev_hash']!=prev: bad.append(i)
    prev=r['hash']
print('  记录=%d 链式=%s 决策分布=%s' % (len(rows), 'OK' if not bad else '异常@%s'%bad,
      {k: sum(1 for r in rows if r['decision']==k) for k in set(r['decision'] for r in rows)}))
"

  step "11. 清理（GT 标签 + 混沌对象）"
  for a in $(echo "$CHAIN" | tr ',' ' '); do bash /opt/aisre/scripts/18-tag-ground-truth.sh clean "$a" >/dev/null 2>&1; done
  clean_chaos
  ok "GT 标签与混沌对象已清理（剩余混沌对象 $(kubectl -n chaos-mesh get podchaos,networkchaos --no-headers 2>/dev/null | wc -l) 个）"

  echo
  printf '%s══════ 闭环时间线 ══════%s\n' "$C_B" "$C_0"
  printf '  策略校验 T_policy   : %s\n' "$T_POLICY"
  printf '  执行      T_exec    : %s（restartedAt=%s）\n' "$T_EXEC" "${AFTER_ANN:-未变化}"
  printf '  恢复      T_recover : %s\n' "${T_RECOVER:-未在窗口内归零}"
  printf '  根因来源            : %s\n' "${ROOT_CAUSE}（规则基线 Top-1 或传入的 LLM 结论）"
  printf '  数据集              : %s\n' "$DATASET"
  exit 0
fi

echo "用法: $0 --stage prepare [--target payment] [--duration 90s]"
echo "      $0 --stage heal --dataset <数据集目录> [--root-cause <服务名>]"
exit 1