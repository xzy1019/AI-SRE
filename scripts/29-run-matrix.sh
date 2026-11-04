#!/usr/bin/env bash
# ============================================================================
# 29-run-matrix.sh —— 批量跑故障实验矩阵并落盘数据集（可重复执行）
#
# 用法（在控制面执行）：
#     bash 29-run-matrix.sh                       # 跑默认矩阵（F01~F06）
#     bash 29-run-matrix.sh F03 F04 F05 F06       # 只跑指定实验
#     WAIT_FIRING=180 bash 29-run-matrix.sh ...   # 调等待 firing 的上限
#
# 每个实验的固定流程（尽量短、可重复）：
#   ① 逐类型清空混沌对象（避免 P27：一个类型不存在会导致整条命令中止）
#   ② 给整条链打 ground truth 标签（P18：只打根因 Pod 不够）
#   ③ 记基线读数（ready / 5xx / 告警数 / ingest 计数）
#   ④ 注入（T0）→ 轮询等 firing（最多 WAIT_FIRING 秒）
#   ⑤ 导出数据集（15-export-dataset.sh）
#   ⑥ 追加一行汇总到 /opt/aisre/datasets/matrix.jsonl（供 30-eval-matrix.py 汇总）
#   ⑦ 清理：清 GT 标签 + 逐类型清混沌对象（**含 P28：若 Pod 卡在 pause 镜像，删 Pod 让 Deployment 重建**）
#
# 产物：
#   /opt/aisre/datasets/<EXP>-<时间戳>/   每个实验一个自包含数据集
#   /opt/aisre/datasets/matrix.jsonl      批量汇总（每实验一行）
# ============================================================================
set -uo pipefail

WAIT_FIRING="${WAIT_FIRING:-170}"
DRAIN_MAX="${DRAIN_MAX:-420}"     # 每轮注入前等"告警窗口排空"的上限秒数（P31）
CHAIN="payment,order,frontend"
C_R=$'\033[0;31m'; C_G=$'\033[0;32m'; C_Y=$'\033[0;33m'; C_B=$'\033[0;36m'; C_0=$'\033[0m'
ts() { date +%H:%M:%S; }
ok() { printf '    %s✔%s [%s] %s\n' "$C_G" "$C_0" "$(ts)" "$*"; }
bad(){ printf '    %s✘%s [%s] %s\n' "$C_R" "$C_0" "$(ts)" "$*"; }
info(){ printf '    %s·%s %s\n' "$C_B" "$C_0" "$*"; }

PROM=http://127.0.0.1:30090; AM=http://127.0.0.1:30093
q() { curl -s --get "$PROM/api/v1/query" --data-urlencode "query=$1" | python3 -c "import json,sys;r=json.load(sys.stdin)['data']['result'];print(r[0]['value'][1] if r else 0)" 2>/dev/null; }
ready() { kubectl -n demo-app get pods --no-headers 2>/dev/null | awk '{split($2,a,"/"); if(a[1]==a[2]) c++} END{print c+0}'; }
alerts() { curl -s $AM/api/v2/alerts | python3 -c "import json,sys;print(len(json.load(sys.stdin)))"; }
ingest_n() { kubectl -n aiops exec deploy/aisre-ingest -- wget -qO- http://127.0.0.1:8080/stats 2>/dev/null | python3 -c "import json,sys;print(json.load(sys.stdin)['alerts_received_total'])" 2>/dev/null || echo 0; }
clean_chaos() { for t in podchaos networkchaos stresschaos iochaos httpchaos timechaos; do kubectl -n chaos-mesh delete $t --all --ignore-not-found >/dev/null 2>&1; done; }
# 逐类型统计混沌对象（不能一次 get 多个类型：任一个类型不存在会让整条命令失败 —— P27）
chaos_count() { local n=0 c=0; for t in podchaos networkchaos stresschaos iochaos httpchaos timechaos; do c=$(kubectl -n chaos-mesh get $t --no-headers 2>/dev/null | wc -l); n=$((n+c)); done; echo "$n"; }

# 等"告警窗口排空"再开始下一轮（P31）
# 规则用 rate(...[5m]) + for: 2m —— 停止注入后告警仍会响约 5 分钟。
# 若不等（例如只 sleep 固定秒数），下一轮会在"上一轮还在 firing"的状态下开跑：
#   · T_firing 变成 0~1s（捕到的是上一轮的告警，不是本次注入）
#   · 导出的数据集混入上一轮告警 → ground truth 标签跟着错配
#   · 指标虚高（拿旧答案对旧题，看起来 100% 命中）
wait_drain() {
  local i F A
  info "等待告警窗口排空（要求 firing=0 且 AM=0，最多 ${DRAIN_MAX}s）..."
  for i in $(seq 1 $((DRAIN_MAX/15))); do
    F=$(q 'count(ALERTS{alertstate="firing"})'); A=$(alerts)
    if [ "${F%.*}" = "0" ] 2>/dev/null && [ "$A" = "0" ]; then
      ok "告警已排空（用时约 $((i*15))s）"
      return 0
    fi
    sleep 15
  done
  bad "等待 ${DRAIN_MAX}s 仍未排空（firing=$F AM=$A）—— 本轮数据可能串味"
  return 1
}

# 实验清单：文件名|标签|真实根因|目标 Deployment（用于事后修复 pause 镜像）
# 格式：文件名|实验号|真实根因|目标Deployment|故障时长(秒)
# 第 5 列用于两件事：① 等"故障结束 + 余量"再导出；② 计算导出窗口 [T0, T0+DUR+60]（P35）
MATRIX=(
  "f01-pod-kill-payment.yaml|F01|payment-service|payment|30"
  "f02-pod-failure-payment.yaml|F02|payment-service|payment|300"
  "f03-net-delay-order.yaml|F03|order-service|order|360"
  "f04-stress-postgres.yaml|F04|postgres-service|postgres|360"
  "f05-net-partition-payment.yaml|F05|payment-service|payment|360"
  "f06-stress-memory-payment.yaml|F06|payment-service|payment|360"
  "f07-net-partition-payment-long.yaml|F07|payment-service|payment|300"
  # 多根因实验：GT 用逗号分隔（第 3 列），会原样写进 ground_truth.json；
  # 第 4 列（受影响 Deployment）也支持逗号分隔，用于 P28 的 pause-image 修复。
  "f13-cascading.yaml|F13|payment-service,redis-service|payment,redis|360"
  "f14-multi-root.yaml|F14|payment-service,redis-service,postgres-service|payment,redis,postgres|360"
)

want() { # want <EXP> <过滤项...> -> 该实验是否要跑
  local exp="$1"; shift
  [ $# -eq 0 ] && return 0          # 没传过滤项 => 全跑
  for w in "$@"; do [ "$w" = "$exp" ] && return 0; done
  return 1
}

echo "══════════════════════════════════════════════════════════"
printf '  故障实验矩阵 · 批量执行  (WAIT_FIRING=%ss)\n' "$WAIT_FIRING"
echo "══════════════════════════════════════════════════════════"
OUT_ROOT=/opt/aisre/datasets
touch "$OUT_ROOT/matrix.jsonl"

for row in "${MATRIX[@]}"; do
  IFS='|' read -r FILE EXP GT DEPLOY DUR <<< "$row"
  DUR="${DUR:-120}"
  want "$EXP" "$@" || continue
  echo
  printf '%s━━━ %s（%s）根因=%s ━━━%s\n' "$C_B" "$EXP" "$FILE" "$GT" "$C_0"

  clean_chaos
  ok "混沌对象已清零"
  wait_drain

  # 【多根因的处理】K8s 标签值**不允许逗号**，所以多根因时不能把 "a-service,b-service" 写进标签。
  #   策略：标签只打**第一个**根因当"提示"；**权威 GT 走矩阵定义**（第 3 列），
  #   由 30/35 号评测脚本用 --gt 覆盖事件标签（--gt 优先级最高，见 16 号文档）。
  GT_LABEL="${GT%%,*}"
  for a in $(echo "$CHAIN" | tr ',' ' '); do bash /opt/aisre/scripts/18-tag-ground-truth.sh set "$a" "$GT_LABEL" >/dev/null 2>&1; done
  B_READY=$(ready); B_5XX=$(q 'sum(rate(http_requests_total{status=~"5.."}[1m]))'); B_AM=$(alerts)
  B_ING=$(ingest_n)   # 用于后面等"Alertmanager 真的投递到了"（P34）
  info "基线: ready=$B_READY/9 5xx=$B_5XX 告警=$B_AM"

  T0=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # 【注入必须被证实】apply 返回成功 ≠ 故障真的注入了（P41 实测）
  # 曾经这里写成 `kubectl apply ... >/dev/null 2>&1`：YAML 缩进错误导致 apply 失败，
  # 错误被丢掉，脚本照样打印"已注入"，于是整轮实验"没有故障却有结论"。
  OUT=$(kubectl apply -f "/opt/aisre/experiments/$FILE" 2>&1); RC=$?
  if [ "$RC" -ne 0 ]; then
    bad "注入失败（apply rc=$RC）：$(echo "$OUT" | head -2 | tr '\n' ' ')"
    info "跳过本轮"
    continue
  fi
  sleep 3
  NCHAOS=$(chaos_count)
  if [ "$NCHAOS" -eq 0 ]; then
    bad "apply 返回成功，但 chaos-mesh 里没有任何对象 —— 注入未生效（P41）"
    info "跳过本轮"
    continue
  fi
  ok "T0=$T0 已注入（chaos 对象 $NCHAOS 个）"

  T_FIRE=""; LAST_AM=0
  for i in $(seq 1 $((WAIT_FIRING/15))); do
    F=$(q 'count(ALERTS{alertstate="firing"})'); A=$(alerts)
    LAST_AM=$A
    if [ "${F%.*}" -ge 1 ] 2>/dev/null; then T_FIRE=$(date -u +%Y-%m-%dT%H:%M:%SZ); break; fi
    sleep 15
  done
  if [ -n "$T_FIRE" ]; then
    LAG=$(( $(date -u -d "$T_FIRE" +%s) - $(date -u -d "$T0" +%s) ))
    ok "T_firing=$T_FIRE（注入后 ${LAG}s）"
  else
    bad "未在 ${WAIT_FIRING}s 内 firing（可能只产生 pending 或该故障不触发这些规则）"
  fi

  # 等故障真正结束 + 余量，再导出（P35）
  # 为什么：若在"首次 firing"就截止，指标曲线只有 15~31s，看不到完整故障演化与恢复过程
  #         （F01 实测窗口仅 31s、F06 仅 15s，见 docs/09 §5.3）。
  # 窗口定为 [T0, T0 + DUR + 60]，与故障定义对齐，且不越过下一轮的起点。
  T_END_EPOCH=$(( $(date -u -d "$T0" +%s) + DUR + 60 ))
  NOW_EPOCH=$(date +%s)
  if [ "$NOW_EPOCH" -lt "$T_END_EPOCH" ]; then
    W=$(( T_END_EPOCH - NOW_EPOCH ))
    info "等故障结束 + 60s 余量（还需 ${W}s）后再导出，让指标覆盖完整恢复过程（P35）"
    sleep "$W"
  fi

  # 等 Alertmanager 把告警投递到 ingest（P34）
  # 现象：Prometheus 里已经 firing，但导出立刻执行时 events.jsonl 还是空的 ——
  #       Alertmanager 有 group_wait/group_interval，投递比"变成 firing"晚一拍。
  info "等待 Alertmanager 投递到 ingest（基线 ingest=$B_ING）..."
  for i in $(seq 1 12); do
    N=$(ingest_n)
    [ "${N:-0}" -gt "${B_ING:-0}" ] 2>/dev/null && { ok "ingest 已收到新告警（$B_ING → $N）"; break; }
    sleep 5
  done

  # 导出数据集：用**精确时间窗 [T0, now]**，不要用"回看 N 分钟"（P33）
  # 回看窗口会越过 T0，把上一轮实验的告警事件（status=firing 的历史记录）卷进来 ——
  # 表现为"实时轮询 170s 内从没 firing，导出的数据集却有一堆 firing"，且 GT 标签跟着错配。
  T_END=$(date -u -d "@$T_END_EPOCH" +%Y-%m-%dT%H:%M:%SZ)
  LOOKBACK=$(( (DUR + 60 + 59) / 60 ))
  bash /opt/aisre/scripts/15-export-dataset.sh "$EXP" "$GT" "$LOOKBACK" "$T0" "$T_END" >/dev/null 2>&1
  D=$(ls -1dt $OUT_ROOT/$EXP-*/ | head -1)
  EV=$(wc -l < "$D/events.jsonl"); FIR=$(python3 -c "
import json
n=0
for l in open('$D/events.jsonl'):
    l=l.strip()
    if l and json.loads(l)['status']=='firing': n+=1
print(n)")
  ok "数据集=$D（事件 $EV / firing $FIR）"

  # 拉一件不算：把本次实验的关键读数写进 matrix.jsonl
  python3 - "$OUT_ROOT/matrix.jsonl" "$EXP" "$GT" "$FILE" "$T0" "${T_FIRE:-}" "$D" "$B_READY" "$B_5XX" "$EV" "$FIR" "$LAST_AM" <<'PY'
import json,sys
out,exp,gt,f,t0,tf,d,b_ready,b_5xx,ev,fir,am = sys.argv[1:13]
with open(out,"a",encoding="utf-8") as fh:
    json.dump({"experiment_id":exp,"ground_truth":gt,"file":f,"injected_at":t0,"firing_at":tf,
               "dataset":d,"baseline_ready":b_ready,"baseline_5xx":b_5xx,
               "events":int(ev),"firing_alerts":int(fir),"alertmanager_active":int(am)},
              fh, ensure_ascii=False)
    fh.write("\n")   # JSONL：每条记录必须以换行结尾，否则后续行无法解析（P29）
PY

  # 清理：GT 标签 + 混沌对象 + （必要时）重建 Pod 修复 pause 镜像
  for a in $(echo "$CHAIN" | tr ',' ' '); do bash /opt/aisre/scripts/18-tag-ground-truth.sh clean "$a" >/dev/null 2>&1; done
  clean_chaos
  sleep 10
  R=$(ready); IMG=$(kubectl -n demo-app get pods -l app="${DEPLOY%%,*}" -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null)
  if [ "$R" != "9" ] || echo "$IMG" | grep -q pause; then
    info "检测到未恢复（ready=$R/9 image=$IMG）→ 删 Pod 让 Deployment 用正确模板重建"
    for _d in $(echo "$DEPLOY" | tr ',' ' '); do
      kubectl -n demo-app delete pod -l app="$_d" --wait=false >/dev/null 2>&1
    done
    for i in $(seq 1 12); do [ "$(ready)" = "9" ] && break; sleep 10; done
  fi
  ok "清理完成：ready=$(ready)/9 混沌对象=$(kubectl -n chaos-mesh get podchaos,networkchaos --no-headers 2>/dev/null | wc -l) GT残留=$(kubectl -n demo-app get pods -o jsonpath='{range .items[*]}{.metadata.labels.ground-truth}{"\n"}{end}' | grep -c service || true)"
done   # 每轮开头由 wait_drain 负责等上一轮告警排空（P31）

echo
printf '%s════ 矩阵执行完成 ════%s\n' "$C_B" "$C_0"
printf '  收尾检查：chaos 对象剩余 %s 个\n' "$(chaos_count)"
printf '  汇总文件: %s/matrix.jsonl\n' "$OUT_ROOT"
python3 -c "
import json
for l in open('$OUT_ROOT/matrix.jsonl'):
    d=json.loads(l); print('  %-4s %-18s events=%-3s firing=%-3s 数据集=%s' % (d['experiment_id'], d['ground_truth'], d['events'], d['firing_alerts'], d['dataset'].split('/')[-2]))
" 2>/dev/null | tail -12