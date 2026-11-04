#!/usr/bin/env bash
# ============================================================================
# 13-verify-e2e.sh —— 端到端链路验证（只读，不修改任何资源）
#
# 用法： 在控制面执行  bash 13-verify-e2e.sh
#
# 验证「业务 → 指标/日志 → 告警」这条链路的七个环节：
#   ① 集群节点就绪        ② 命名空间与工作负载
#   ③ Prometheus 抓取     ④ Loki 日志
#   ⑤ Alertmanager 可达   ⑥ Chaos Mesh 可用
#   ⑦ OTel Collector 健康
#
# 输出最后给出 PASS/FAIL 汇总，任一项失败返回非零退出码（可用于 CI）。
# ============================================================================
set -uo pipefail

C_R=$'\033[0;31m'; C_G=$'\033[0;32m'; C_Y=$'\033[0;33m'; C_B=$'\033[0;36m'; C_0=$'\033[0m'
PASS=0; FAIL=0
ok()   { printf '  %s✔%s %s\n' "$C_G" "$C_0" "$*"; PASS=$((PASS+1)); }
bad()  { printf '  %s✘%s %s\n' "$C_R" "$C_0" "$*"; FAIL=$((FAIL+1)); }
step() { printf '\n%s== %s ==%s\n' "$C_B" "$*" "$C_0"; }

command -v kubectl >/dev/null 2>&1 || { echo "未找到 kubectl（本脚本需在控制面执行）"; exit 1; }

step "① 集群节点"
READY=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"{c++} END{print c+0}')
TOT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
[ "$READY" = "$TOT" ] && [ "$TOT" -ge 5 ] && ok "$READY/$TOT 节点 Ready" || bad "$READY/$TOT 节点 Ready"

step "② 命名空间与工作负载"
for ns in demo-app observability chaos-mesh; do
  if kubectl get ns "$ns" >/dev/null 2>&1; then ok "命名空间 $ns 存在"; else bad "命名空间 $ns 缺失"; fi
done
for w in frontend order payment; do
  N=$(kubectl -n demo-app get deploy "$w" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  [ "${N:-0}" -ge 2 ] && ok "$w 就绪副本 $N/2" || bad "$w 就绪副本 ${N:-0}/2"
done
for w in postgres redis loadgen; do
  N=$(kubectl -n demo-app get deploy,statefulset "$w" -o jsonpath='{.items[0].status.readyReplicas}' 2>/dev/null)
  [ "${N:-0}" -ge 1 ] && ok "$w 就绪副本 $N" || bad "$w 未就绪"
done

step "③ Prometheus 指标"
P=$(kubectl -n observability get pod -l app=prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$P" ]; then bad "Prometheus Pod 不存在"; else
  # 用 python3 解析返回值：标量结果的结构是 data.result=[<ts>,"<值>"]，
  # 用 tr/awk 拼字符串很容易取错位置（踩过一次：把时间戳当成了值）。
  N=$(kubectl -n observability exec "$P" -c prometheus -- \
      wget -qO- 'http://localhost:9090/api/v1/query?query=count(up%7Bjob%3D%22demo-app%22%7D%3D%3D1)' 2>/dev/null \
      | python3 -c "
import json,sys
try:
    r=json.load(sys.stdin)['data']['result']
    print(int(float(r[0]['value'][1])) if r else 0)
except Exception:
    print(0)
")
  [ "${N:-0}" -ge 6 ] && ok "demo-app 抓取成功实例数 = $N（期望 6）" || bad "demo-app 抓取成功实例数 = ${N:-0}（期望 6）"
  printf '  · 规则文件加载数：'
  kubectl -n observability exec "$P" -c prometheus -- \
    wget -qO- 'http://localhost:9090/api/v1/rules' 2>/dev/null | grep -o '"name":"aisre-lab.rules"' | head -1 || echo '(未匹配)'
  ok "Prometheus 查询接口可用"
fi

step "④ Loki 日志"
L=$(kubectl -n observability get pod -l app=loki -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$L" ]; then bad "Loki Pod 不存在"; else
  NS=$(kubectl -n observability exec "$L" -c loki -- wget -qO- 'http://localhost:3100/loki/api/v1/label/namespace/values' 2>/dev/null)
  if printf '%s' "$NS" | grep -q 'demo-app'; then ok "Loki 中已有 demo-app 命名空间日志"
  else bad "Loki 中未见 demo-app 日志"; fi
fi

step "⑤ Alertmanager"
A=$(kubectl -n observability get pod -l app=alertmanager -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$A" ]; then bad "Alertmanager Pod 不存在"; else
  AL=$(kubectl -n observability exec "$A" -c alertmanager -- wget -qO- http://localhost:9093/api/v2/status 2>/dev/null | head -c 60)
  [ -n "$AL" ] && ok "Alertmanager API 可达" || bad "Alertmanager API 无响应"
  N=$(kubectl -n observability exec "$A" -c alertmanager -- wget -qO- http://localhost:9093/api/v2/alerts 2>/dev/null | grep -o '"fingerprint"' | wc -l)
  ok "当前活动告警数 = $N"
fi

step "⑥ Chaos Mesh"
CRD=$(kubectl get crd -o name 2>/dev/null | grep -c 'chaos-mesh.org')
[ "$CRD" -ge 20 ] && ok "Chaos Mesh CRD $CRD 个" || bad "Chaos Mesh CRD 数量异常（$CRD）"
CD=$(kubectl -n chaos-mesh get ds chaos-daemon -o jsonpath='{.status.numberReady}' 2>/dev/null)
[ "${CD:-0}" -ge 5 ] && ok "chaos-daemon 就绪 $CD/5" || bad "chaos-daemon 就绪 ${CD:-0}/5"

step "⑦ OTel Collector"
POD=$(kubectl -n observability get pod -l app=otel-collector -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$POD" ]; then
  printf '  %s!%s OTel Collector 未部署（bash 12-deploy-otel-collector.sh 可补）\n' "$C_Y" "$C_0"
else
  READY=$(kubectl -n observability get pod -l app=otel-collector -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null)
  [ "$READY" = "true" ] && ok "collector Pod ready（镜像内无 shell，探针走 K8s readiness）" || bad "collector Pod 未就绪"
  # 从业务 Pod 侧探测 Service（借 python3 做探针，避免依赖镜像内工具）
  PROBE=$(kubectl -n demo-app get pod -l app=frontend -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ -n "$PROBE" ]; then
    if kubectl -n demo-app exec "$PROBE" -- python3 -c "
import urllib.request,sys
try:
    urllib.request.urlopen('http://otel-collector.observability.svc:13133/', timeout=5); sys.exit(0)
except Exception:
    sys.exit(1)
" >/dev/null 2>&1; then ok "OTLP 接收端健康端点可达（4318/4317 同 Service）"
    else bad "OTLP 接收端健康端点不可达"; fi
  fi
fi

step "⑧ 告警规则"
if [ -n "$P" ]; then
  N=$(kubectl -n observability exec "$P" -c prometheus -- wget -qO- 'http://localhost:9090/api/v1/rules' 2>/dev/null | grep -o '"type":"alerting"' | wc -l)
  [ "${N:-0}" -ge 13 ] && ok "已加载 $N 条告警规则（期望 ≥13：8 基础 + 5 业务）" \
                       || bad "已加载 ${N:-0} 条告警规则，期望 ≥13 —— 检查 rule_files 路径是否指向实际挂载的文件"
fi

step "⑨ AIOps 接入层（aisre-ingest）"
RDY=$(kubectl -n aiops get pod -l app=aisre-ingest -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null)
if [ -z "$RDY" ]; then
  printf '  %s!%s aisre-ingest 未部署（bash 14-deploy-ingestion.sh 可补）\n' "$C_Y" "$C_0"
else
  [ "$RDY" = "true" ] && ok "aisre-ingest Pod ready" || bad "aisre-ingest Pod 未就绪"
  S=$(kubectl -n aiops exec deploy/aisre-ingest -- wget -qO- http://127.0.0.1:8080/stats 2>/dev/null)
  RECV=$(printf '%s' "$S" | python3 -c "import json,sys;print(json.load(sys.stdin).get('alerts_received_total',0))" 2>/dev/null)
  WRITTEN=$(printf '%s' "$S" | python3 -c "import json,sys;print(json.load(sys.stdin).get('events_written_total',0))" 2>/dev/null)
  DEDUP=$(printf '%s' "$S" | python3 -c "import json,sys;print(json.load(sys.stdin).get('alerts_deduplicated_total',0))" 2>/dev/null)
  LAST=$(printf '%s' "$S" | python3 -c "import json,sys;print(json.load(sys.stdin).get('last_received_rfc3339','-'))" 2>/dev/null)
  ok "累计接收告警 ${RECV:-0} 条 / 落盘 ${WRITTEN:-0} 条 / 去重 ${DEDUP:-0} 条"
  ok "最近一次接收时间: ${LAST:-未收到过}"
  F=$(kubectl -n aiops exec deploy/aisre-ingest -- sh -c 'wc -l < /data/events.jsonl 2>/dev/null' 2>/dev/null | tr -d ' ')
  [ -n "$F" ] && ok "事件文件行数 = $F" || bad "事件文件不可读"
fi

step "⑪ AIOps 自监控覆盖（每个组件都必须被抓取）"
# 【为什么单独做这一组检查】本项目踩过两次同类问题：
#   · P10：Alertmanager 自己没被抓取 → "通知失败"在指标层完全不可见
#   · P29：新部署 aisre-agent 时漏加抓取 job → Grafana"审计记录数"面板 No data
# 结论：**"组件能跑"和"组件能被观测"是两件事**，必须一起验收。
if [ -n "$P" ]; then
  for j in alertmanager loki grafana aisre-ingest aisre-agent; do
    printf '  %-16s ' "$j"
    curl -s --get 'http://127.0.0.1:30090/api/v1/query' --data-urlencode "query=up{job=\"$j\"}" 2>/dev/null \
      | python3 -c "
import json,sys
d=json.load(sys.stdin); r=d['data']['result']
print('✔ 已抓取' if r and r[0]['value'][1]=='1' else '✘ 未抓取/不健康 —— 检查 Prometheus 的 scrape_configs')
" 2>/dev/null || echo "✘ 查询失败"
  done
fi

step "⑩ 通知链路（Alertmanager → Ingest）"
NF=$(kubectl -n observability exec deploy/prometheus -c prometheus -- wget -qO- 'http://localhost:9090/api/v1/query?query=increase(alertmanager_notifications_failed_total%5B30m%5D)' 2>/dev/null \
     | python3 -c "
import json,sys
try:
    r=json.load(sys.stdin)['data']['result']; print(int(float(r[0]['value'][1])) if r else 0)
except Exception: print(-1)
" 2>/dev/null)
if [ "${NF:- -1}" = "0" ]; then ok "近 30 分钟 Alertmanager 通知失败 0 次"
elif [ "${NF:- -1}" = "-1" ]; then printf '  %s!%s 查不到 alertmanager 自监控指标（检查 scrape job）\n' "$C_Y" "$C_0"
else bad "近 30 分钟 Alertmanager 通知失败 ${NF} 次 —— 检查 receiver 指向的服务"; fi
printf '\n%s===== 汇总 =====%s\n' "$C_B" "$C_0"
printf '  %s通过 %d 项%s，%s失败 %d 项%s\n' "$C_G" "$PASS" "$C_0" "$C_R" "$FAIL" "$C_0"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1