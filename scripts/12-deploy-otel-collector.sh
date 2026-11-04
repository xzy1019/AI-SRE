#!/usr/bin/env bash
# ============================================================================
# 12-deploy-otel-collector.sh —— 部署 OpenTelemetry Collector（幂等）
#
# 用法： 在控制面执行  bash 12-deploy-otel-collector.sh
#
# 作用：为全集群提供统一 OTLP 接收端（gRPC 4317 / HTTP 4318），
#       收到的日志经 k8sattributes 补全元数据后写入 Loki。
#
# 为什么需要它：
#   没有 Collector 时，每个组件都要自己适配后端（Loki 的推送格式、标签规则、
#   批量与重试策略）。加了 Collector 之后，aiops 各组件只面向 OTLP 一个协议，
#   换后端（Loki→Tempo、加采样、加脱敏）只改一处配置。
#
# 与 Promtail 的分工（重要，避免重复入库）：
#   Promtail  → 采集容器文件日志（/var/log/pods），job="promtail"
#   OTel      → 只接收应用主动上报的 OTLP 数据
#   两者不要同时对同一份文件日志采集，否则 Loki 里会出现双份数据。
#
# 前置：镜像已分发（07-distribute-images.ps1，含 otel-collector）
# ============================================================================
set -uo pipefail

D="/opt/aisre/manifests/observability"
F="$D/08-otel-collector.yaml"
C_R=$'\033[0;31m'; C_G=$'\033[0;32m'; C_Y=$'\033[0;33m'; C_B=$'\033[0;36m'; C_0=$'\033[0m'
ok()   { printf '  %s✔%s %s\n' "$C_G" "$C_0" "$*"; }
bad()  { printf '  %s✘%s %s\n' "$C_R" "$C_0" "$*"; }
step() { printf '\n%s== %s ==%s\n' "$C_B" "$*" "$C_0"; }

[ "$(id -u)" -eq 0 ] || { echo "必须以 root 执行"; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "未找到 kubectl（本脚本需在控制面执行）"; exit 1; }
[ -f "$F" ] || { echo "清单不存在: $F"; exit 1; }

step "1/3 应用清单"
OUT="$(kubectl apply -f "$F" 2>&1)"
printf '%s\n' "$OUT" | sed 's/^/  /'
if printf '%s' "$OUT" | grep -qiE '^error|Error from server'; then
  bad "应用失败"; exit 1
fi

step "2/3 等待就绪（最多 180s）"
kubectl -n observability rollout status deploy/otel-collector --timeout=180s 2>&1 | sed 's/^/  /'
for i in $(seq 1 36); do
  RDY=$(kubectl -n observability get pod -l app=otel-collector --no-headers 2>/dev/null | awk '$2=="1/1"{c++} END{print c+0}')
  [ "${RDY:-0}" -ge 1 ] && break
  sleep 5
done

step "3/3 健康检查与 OTLP 自检"

# 【为什么不在 Collector 自己的容器里 curl/wget】
# otelcol-contrib 镜像里**没有 shell、没有 wget/curl**（distroless 风格），
# 所以在它自己容器里 `exec sh/wget` 必然失败：
#   exec: "sh": executable file not found in $PATH
# 这会让"健康检查"永远为红。正确做法是**从外部探测它的 Service**——
# 这里借用业务 Pod（python:3.12-alpine，自带 python3）做探针。
POD="$(kubectl -n observability get pod -l app=otel-collector -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
READY="$(kubectl -n observability get pod -l app=otel-collector -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null)"
if [ "${READY:-false}" = "true" ]; then ok "collector Pod $POD ready=true（readiness 探针已通过）"
else bad "collector Pod $POD ready=${READY:-未知}"; fi

PROBE="$(kubectl -n demo-app get pod -l app=frontend -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
if [ -z "$PROBE" ]; then
  warn_ports="未找到业务 Pod（demo-app/frontend），跳过端口探测：先跑 11-deploy-demo-app.sh"
  printf '  %s!%s %s\n' "$C_Y" "$C_0" "$warn_ports"
else
  RES="$(kubectl -n demo-app exec "$PROBE" -- python3 -c "
import socket, urllib.request
h='otel-collector.observability.svc'
for p in (4317,4318,13133):
    s=socket.socket(); s.settimeout(4)
    try:
        s.connect((h,p)); print('  ✔ %-6d listening'%p)
    except Exception as e:
        print('  ✘ %-6d %s'%(p,e))
    finally:
        s.close()
try:
    print('  health_check 响应:', urllib.request.urlopen('http://%s:13133/'%h, timeout=5).read().decode().strip())
except Exception as e:
    print('  health_check 失败:', e)
" 2>/dev/null)"
  printf '%s\n' "$RES"
  if printf '%s' "$RES" | grep -q 'listening' && printf '%s' "$RES" | grep -q 'health_check 响应'; then
    ok "OTLP 端口与健康端点均可达"
  else
    bad "Collector 端口/健康端点异常"
  fi

  # OTLP → Loki 端到端自检：发一条带标记的日志，再从 Loki 查回来
  kubectl -n demo-app exec "$PROBE" -- python3 -c "
import json,time,urllib.request
ts=str(int(time.time()*1e9))
payload={'resourceLogs':[{'resource':{'attributes':[
  {'key':'service.name','value':{'stringValue':'aisre-selftest'}},
  {'key':'k8s.pod.name','value':{'stringValue':'$PROBE'}},
  {'key':'k8s.namespace.name','value':{'stringValue':'demo-app'}}]},
 'scopeLogs':[{'scope':{'name':'aisre.selftest'},'logRecords':[
  {'timeUnixNano':ts,'severityText':'INFO','body':{'stringValue':'otlp-selftest-ok'}}]}]}]}
req=urllib.request.Request('http://otel-collector.observability.svc:4318/v1/logs',
  data=json.dumps(payload).encode(), headers={'Content-Type':'application/json'})
print('  OTLP 上报状态码:', urllib.request.urlopen(req, timeout=6).status)
" 2>/dev/null

  sleep 10
  L="$(kubectl -n observability get pod -l app=loki -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  S="$(date -d '-5 minutes' +%s)000000000"
  HIT="$(kubectl -n observability exec "$L" -c loki -- wget -qO- \
    "http://localhost:3100/loki/api/v1/query_range?query=%7Bjob%3D~%22.%2B%22%7D%20%7C%3D%20%22otlp-selftest-ok%22&limit=1&start=$S" 2>/dev/null)"
  if printf '%s' "$HIT" | grep -q 'otlp-selftest-ok'; then
    ok "OTLP 端到端链路打通（Collector → Loki 已查到自检日志）"
  else
    bad "Loki 中未查到自检日志（Collector 可能未转发成功）"
  fi
fi

echo
printf '%s业务侧接入方式（示例）：%s\n' "$C_B" "$C_0"
printf '  OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.observability.svc:4318\n'
printf '  本地调试：kubectl -n observability port-forward svc/otel-collector 4318:4318\n'