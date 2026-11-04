#!/usr/bin/env bash
# ============================================================
# run-experiment.sh —— 执行一次混沌实验并采集数据（含 ground truth）
#
# 用法: bash run-experiment.sh <实验文件名> [观察时长秒]
#   例: bash run-experiment.sh 01-pod-chaos.yaml 120
#
# 输出: /var/lib/aisre/experiments/<实验名>-<时间戳>/
#         meta.json      实验元数据（含 ground truth）
#         baseline.json  注入前基线
#         samples.jsonl  观察期采样（每 10s 一条）
#         summary.json   汇总指标
# ============================================================
set -uo pipefail

EXP_FILE="${1:?用法: run-experiment.sh <实验文件> [观察秒数]}"
OBSERVE_SEC="${2:-120}"
OUT_ROOT="/var/lib/aisre/experiments"

C_R=$'\033[0;31m'; C_G=$'\033[0;32m'; C_Y=$'\033[0;33m'; C_B=$'\033[0;36m'; C_0=$'\033[0m'
step() { printf '\n%s== %s ==%s\n' "$C_B" "$*" "$C_0"; }
ok()   { printf '  %s✔%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_Y" "$C_0" "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "必须以 root 执行"; exit 1; }
[ -f "$EXP_FILE" ] || { echo "实验文件不存在: $EXP_FILE"; exit 1; }

PIP=$(kubectl -n observability get pods -l app=prometheus --field-selector=status.phase=Running \
      --no-headers 2>/dev/null | awk '$2=="1/1"{print $1}' | head -1)
[ -n "$PIP" ] || { echo "未找到运行中的 Prometheus"; exit 1; }
PIP=$(kubectl -n observability get pod "$PIP" -o jsonpath='{.status.podIP}')
PROM="http://$PIP:9090/api/v1/query"

# 从 YAML 提取元数据
# 注意：清单里标签可能写成 inline 形式 labels: { experiment-id: F14, ground-truth: payment-service }，
# 直接 sed 掉前缀会把 "F14, ground-truth: payment-service }" 整串当编号（实测踩到，产物目录名变脏）。
# 所以统一在第一个逗号或右花括号处截断。
EXP_ID=$(grep -m1 'experiment-id:' "$EXP_FILE" | sed 's/.*experiment-id: *//' | sed 's/[,}].*//' | tr -d ' \r')
GT=$(grep -m1 'ground-truth:' "$EXP_FILE" | sed 's/.*ground-truth: *//' | sed 's/[,}].*//' | tr -d ' \r')
EXP_NAME=$(grep -m1 '  name: ' "$EXP_FILE" | sed 's/.*name: *//' | sed 's/[,}].*//' | tr -d ' \r')
TS=$(date +%Y%m%d-%H%M%S)
OUT="$OUT_ROOT/${EXP_ID:-EXP}-${EXP_NAME}-${TS}"
mkdir -p "$OUT"

echo "════════════════════════════════════════════"
printf '  实验: %s\n' "$EXP_NAME"
printf '  编号: %s\n' "$EXP_ID"
printf '  真实根因(ground truth): %s\n' "$GT"
printf '  输出: %s\n' "$OUT"
echo "════════════════════════════════════════════"

cat > "$OUT/meta.json" <<EOF
{
  "experiment_id": "${EXP_ID:-}",
  "experiment_name": "${EXP_NAME:-}",
  "ground_truth": "${GT:-}",
  "file": "$(basename "$EXP_FILE")",
  "observe_seconds": $OBSERVE_SEC,
  "started_at": "$(date -Iseconds)",
  "injected_at": null,
  "recovered_at": null
}
EOF

q() {   # q <promql> -> 标量
  # 【坑】Prometheus 对"纯标量表达式"返回的是 resultType=scalar，
  # 此时 data.result 是 [<时间戳>, "<值>"]，不是 [[{value:[ts,val]}]]。
  # 只按 vector 解析会抛 TypeError: 'float' object is not subscriptable，
  # 于是所有采样都变成 null，实验数据看起来"什么都没发生"。
  # 这里两种都兼容。
  timeout 15 curl -s -G "$PROM" --data-urlencode "query=$1" 2>/dev/null \
    | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)['data']
    rt=d.get('resultType'); r=d.get('result')
    if rt=='scalar':
        print(r[1])
    elif rt=='vector' and r:
        print(r[0]['value'][1])
    else:
        print('null')
except Exception:
    print('null')
"
}

snapshot() {   # 采集一次指标快照
  # 【坑】samples.jsonl 是"一行一条记录"的 JSONL 格式，
  # 多行美化过的 JSON 虽然本身合法，但逐行 json.loads 会直接报错，
  # 后续所有分析脚本都会崩。这里统一压成单行输出。
  local t="$1"
  compact() { python3 -c "import json,sys;print(json.dumps(json.loads(sys.stdin.read()),ensure_ascii=False,separators=(',',':')))"; }
  compact <<EOF
{"t":"$t","t_unix":$(date +%s),
 "req_total":$(q 'sum(increase(http_requests_total{namespace="demo-app"}[1m]))'),
 "req_5xx":$(q 'sum(increase(http_requests_total{namespace="demo-app",status=~"5.."}[1m]))'),
 "p95_frontend":$(q 'histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket{namespace="demo-app",app="frontend"}[1m])) by (le))'),
 "p95_order":$(q 'histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket{namespace="demo-app",app="order"}[1m])) by (le))'),
 "p95_payment":$(q 'histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket{namespace="demo-app",app="payment"}[1m])) by (le))'),
 "down_err_total":$(q 'sum(increase(downstream_requests_total{namespace="demo-app",result="error"}[1m]))'),
 "pods_ready":$(q 'count(kube_pod_status_ready{namespace="demo-app",condition="true"}==1)'),
 "restarts":$(q 'sum(kube_pod_container_status_restarts_total{namespace="demo-app"})')}
EOF
}

step "1/4 采集基线（30s）"
sleep 30
snapshot "$(date -Iseconds)" > "$OUT/baseline.json"
cat "$OUT/baseline.json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for k,v in d.items():
    if k not in ('t','t_unix'): print('    %-16s %s' % (k, v))
"
ok "基线已记录"

step "2/4 注入故障并记录 T0"
T0=$(date +%s)
T0_ISO=$(date -Iseconds)
kubectl apply -f "$EXP_FILE" 2>&1 | sed 's/^/    /'
python3 - "$OUT" "$T0_ISO" <<'PY'
import json,sys
p=sys.argv[1]+'/meta.json'
d=json.load(open(p)); d['injected_at']=sys.argv[2]
json.dump(d, open(p,'w'), indent=2)
PY
ok "注入时间 T0 = $T0_ISO"

step "3/4 观察期采样（每 10s，共 ${OBSERVE_SEC}s）"
: > "$OUT/samples.jsonl"
ELAPSED=0
while [ "$ELAPSED" -lt "$OBSERVE_SEC" ]; do
  SNAP=$(snapshot "$((ELAPSED))s")
  echo "$SNAP" >> "$OUT/samples.jsonl"
  echo "$SNAP" | python3 -c "
import json,sys
d=json.load(sys.stdin)
def f(x):                      # 数值直接切字符串会报 'float' object is not subscriptable
    return '-' if x in (None,'null') else ('%.3g' % float(x))
print('    [%4s] 5xx=%-8s p95(f/o/p)=%s/%s/%s  ready=%s  restarts=%s' % (
  d['t'], f(d['req_5xx']), f(d['p95_frontend']), f(d['p95_order']), f(d['p95_payment']),
  d['pods_ready'], d['restarts']))
"
  sleep 10
  ELAPSED=$((ELAPSED+10))
done

step "4/4 等待恢复并汇总"
sleep 20
T1=$(date +%s)
T1_ISO=$(date -Iseconds)
python3 - "$OUT" "$T1_ISO" $T0 $T1 <<'PY'
import json,sys
out, t1iso, t0, t1 = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
d=json.load(open(out+'/meta.json')); d['recovered_at']=t1iso; d['duration_seconds']=t1-t0
json.dump(d, open(out+'/meta.json','w'), indent=2)

final=json.load(open(out+'/baseline.json'))
final['phase']='final'; final['t']=t1iso
import subprocess
PY
snapshot "$(date -Iseconds)" > "$OUT/final.json"

python3 - "$OUT" <<'PY'
import json,sys,os
out=sys.argv[1]
base=json.load(open(out+'/baseline.json'))
final=json.load(open(out+'/final.json'))
meta=json.load(open(out+'/meta.json'))
samples=[json.loads(l) for l in open(out+'/samples.jsonl') if l.strip()]
def f(x):
    try: return float(x)
    except: return None
peak_5xx=max([f(s.get('req_5xx')) or 0 for s in samples]+[0])
peak_p95p=max([f(s.get('p95_payment')) or 0 for s in samples]+[0])
summary={
 'experiment_id':meta.get('experiment_id'),
 'ground_truth':meta.get('ground_truth'),
 'duration_seconds':meta.get('duration_seconds'),
 'baseline':{k:base.get(k) for k in ('req_total','req_5xx','p95_payment','down_err_total','pods_ready')},
 'peak':{'req_5xx_max':peak_5xx,'p95_payment_max':peak_p95p},
 'final':{k:final.get(k) for k in ('req_5xx','p95_payment','pods_ready','restarts')},
 'sample_count':len(samples)
}
json.dump(summary, open(out+'/summary.json','w'), indent=2, ensure_ascii=False)
print()
print('  ┌──────────── 实验汇总 ────────────')
print('  │ 实验编号   : %s' % summary['experiment_id'])
print('  │ 真实根因   : %s' % summary['ground_truth'])
print('  │ 实验时长   : %ss' % summary['duration_seconds'])
print('  │ 基线 5xx   : %s' % summary['baseline']['req_5xx'])
print('  │ 峰值 5xx   : %s' % summary['peak']['req_5xx_max'])
print('  │ 峰值 p95   : %ss (payment)' % round(summary['peak']['p95_payment_max'], 3))
print('  │ 最终 ready : %s' % summary['final']['pods_ready'])
print('  │ 累计重启   : %s' % summary['final']['restarts'])
print('  └──────────────────────────────────')
PY

echo
echo "  产物: $OUT"
ls -la "$OUT" | sed 's/^/    /'