#!/usr/bin/env bash
# ============================================================================
# 15-export-dataset.sh —— 把一次实验导出成自包含数据集（datasets/<EXP>-<时间戳>/）
#
# 用法（在控制面执行）：
#     bash 15-export-dataset.sh <实验编号> <根因服务> [回看分钟数] [起始ISO] [结束ISO]
#   例：
#     bash 15-export-dataset.sh F02 payment-service 60
#
# 产出（默认写到 /opt/aisre/datasets/）：
#   ground_truth.json  这次故障的标准答案（编号/根因服务/时间窗/来源）
#   events.jsonl       时间窗内的告警事件（来自 aisre-ingest 的 /data/events.jsonl）
#   metrics.json       关键 SLI 的窗口采样（PromQL 原始返回，附查询语句）
#   logs.txt           涉及服务的日志片段
#   manifest.sha256    各文件哈希
#   README.md          本次实验的结论与局限
#
# 设计原则：
#   · 只读：不修改集群任何资源，只把数据"搬出来"
#   · 自包含：拿到这个目录就能离线算指标，不需要再连集群
# ============================================================================
set -uo pipefail

EXP="${1:?用法: 15-export-dataset.sh <实验编号> <根因服务> [回看分钟数]}"
GT="${2:?缺少根因服务，例如 payment-service}"
BACK="${3:-60}"
FROM="${4:-}"
TO="${5:-}"

C_R=$'\033[0;31m'; C_G=$'\033[0;32m'; C_Y=$'\033[0;33m'; C_B=$'\033[0;36m'; C_0=$'\033[0m'
ok()   { printf '  %s✔%s %s\n' "$C_G" "$C_0" "$*"; }
bad()  { printf '  %s✘%s %s\n' "$C_R" "$C_0" "$*"; }
info() { printf '  %s·%s %s\n' "$C_B" "$C_0" "$*"; }

OUT_ROOT="${OUT_ROOT:-/opt/aisre/datasets}"
TS=$(date +%Y%m%d-%H%M)
OUT="$OUT_ROOT/${EXP}-${TS}"
mkdir -p "$OUT"

# 时间窗：给了 FROM/TO 就用精确窗口（推荐，用于复现某次故障），否则按"回看 N 分钟"
if [ -n "$FROM" ] && [ -n "$TO" ]; then
  SINCE_ISO="$FROM"; NOW_ISO="$TO"
  SINCE_EPOCH=$(date -u -d "$FROM" +%s)
  UNTIL_EPOCH=$(date -u -d "$TO" +%s)
else
  SINCE_EPOCH=$(( $(date +%s) - BACK*60 ))
  UNTIL_EPOCH=$(date +%s)
  SINCE_ISO=$(date -u -d "@$SINCE_EPOCH" +%Y-%m-%dT%H:%M:%SZ)
  NOW_ISO=$(date -u -d "@$UNTIL_EPOCH" +%Y-%m-%dT%H:%M:%SZ)
fi

info "实验编号 : $EXP"
info "根因服务 : $GT"
info "时间窗   : $SINCE_ISO  →  $NOW_ISO（回看 ${BACK} 分钟）"
info "输出目录 : $OUT"
echo

# ---------- 1) 事件流 ----------
echo "== 1/5 导出告警事件 =="
kubectl -n aiops exec deploy/aisre-ingest -- cat /data/events.jsonl > "$OUT/events_all.jsonl" 2>/dev/null \
  || { bad "读取 /data/events.jsonl 失败"; exit 1; }
python3 - "$OUT/events_all.jsonl" "$OUT/events.jsonl" "$SINCE_EPOCH" "$UNTIL_EPOCH" <<'PY'
import json, sys, io
src, dst, since, until = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
n_all = n_keep = 0
with io.open(src, encoding="utf-8") as fi, io.open(dst, "w", encoding="utf-8", newline="\n") as fo:
    for line in fi:
        line = line.strip()
        if not line:
            continue
        n_all += 1
        try:
            e = json.loads(line)
        except Exception:
            continue
        rcv = e.get("received_at", "")
        # received_at 是 RFC3339 UTC
        import calendar, time
        try:
            t = calendar.timegm(time.strptime(rcv, "%Y-%m-%dT%H:%M:%SZ"))
        except Exception:
            t = 0
        if since <= t <= until:
            fo.write(json.dumps(e, ensure_ascii=False) + "\n")
            n_keep += 1
print("  总事件 %d 条，窗口内 %d 条" % (n_all, n_keep))
PY
rm -f "$OUT/events_all.jsonl"

# ---------- 2) 指标采样 ----------
echo "== 2/5 采样关键 SLI =="
PROM="http://127.0.0.1:30090"
python3 - "$OUT/metrics.json" "$PROM" "$SINCE_EPOCH" "$UNTIL_EPOCH" <<'PY'
import json, sys, time, urllib.parse, urllib.request
out, prom, since, until = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
queries = {
  "5xx_rate":   'sum(rate(http_requests_total{job="demo-app",status=~"5.."}[1m]))',
  "qps":        'sum(rate(http_requests_total{job="demo-app"}[1m]))',
  "p95_payment":'histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket{job="demo-app",service="payment",endpoint="/"}[1m])))',
  "pods_ready": 'count(kube_pod_status_ready{namespace="demo-app",condition="true"}==1)',
  "downstream_err": 'sum(rate(downstream_requests_total{job="demo-app",result="error"}[1m]))',
}
data = {"window": {"from": since, "to": until}, "series": {}}
for name, q in queries.items():
    url = prom + "/api/v1/query_range?" + urllib.parse.urlencode({
        "query": q, "start": since, "end": until, "step": "30"})
    try:
        with urllib.request.urlopen(url, timeout=15) as r:
            d = json.loads(r.read().decode())
        data["series"][name] = {"query": q, "result": d.get("data", {}).get("result", [])}
    except Exception as e:
        data["series"][name] = {"query": q, "error": str(e)}
json.dump(data, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
print("  已采样 %d 条 SLI 序列" % len(queries))
PY

# ---------- 3) 日志 ----------
echo "== 3/5 抓取日志片段 =="
: > "$OUT/logs.txt"
for w in frontend order payment; do
  echo "===== $w =====" >> "$OUT/logs.txt"
  kubectl -n demo-app logs -l app="$w" --tail=200 --prefix 2>/dev/null >> "$OUT/logs.txt" || true
done
info "日志行数: $(wc -l < "$OUT/logs.txt")"

# ---------- 4) ground truth ----------
echo "== 4/5 写 ground_truth.json =="
python3 - "$OUT/ground_truth.json" "$EXP" "$GT" "$SINCE_ISO" "$NOW_ISO" "$BACK" <<'PY'
import json, sys
out, exp, gt, frm, to, back = sys.argv[1:7]
# 支持多根因：GT 传 "payment-service,redis-service"
parts = [x.strip() for x in gt.split(",") if x.strip()]
json.dump({
  "experiment_id": exp,
  "ground_truth_service": parts[0] if parts else gt,
  "ground_truth_services": parts,
  "window_from": frm,
  "window_to": to,
  "lookback_minutes": int(back),
  "association_method": "time-window",   # 待升级为标签传播，见 datasets/README.md §3
  "note": "时间窗内的告警整体标注为这些根因服务；多根因实验（如 F13）给出列表",
}, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY
ok "ground truth 已关联（方式：时间窗）"

# ---------- 5) README + 哈希 ----------
echo "== 5/5 生成 README 与哈希 =="
EV=$(wc -l < "$OUT/events.jsonl")
FR=$(python3 -c "
import json
n=0
for l in open('$OUT/events.jsonl'):
    l=l.strip()
    if l and json.loads(l).get('status')=='firing': n+=1
print(n)")
cat > "$OUT/README.md" <<EOF
# 数据集 $EXP-$TS

| 项 | 值 |
|---|---|
| 实验编号 | $EXP |
| 根因服务（ground truth） | $GT |
| 采样窗口 | $SINCE_ISO → $NOW_ISO |
| 事件条数 | $EV（其中 firing $FR） |
| 关联方式 | 时间窗（见 datasets/README.md §3） |

## 本次结论

（实验结束后手写：现象 → 告警 → 是否指向正确根因 → 局限）

## 文件

- \`events.jsonl\` 告警事件流（统一 Event 模型）
- \`metrics.json\` SLI 窗口采样（附 PromQL 原文）
- \`logs.txt\` 涉及服务的日志片段
- \`ground_truth.json\` 标准答案
- \`correlation.json\` 降噪结果（运行 \`scripts/16-correlation-baseline.py\` 生成）
EOF

( cd "$OUT" && sha256sum events.jsonl metrics.json logs.txt ground_truth.json README.md > manifest.sha256 )
ok "数据集已生成: $OUT"
echo
ls -l "$OUT" | sed 's/^/  /'
echo
printf '%s下一步：把目录拷回开发机，或直接算降噪指标%s\n' "$C_B" "$C_0"
printf '  python3 /opt/aisre/scripts/16-correlation-baseline.py %s\n' "$OUT"