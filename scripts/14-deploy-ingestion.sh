#!/usr/bin/env bash
# ============================================================================
# 14-deploy-ingestion.sh —— 部署 aisre-ingest（告警接入与归一化，幂等）
#
# 用法： 在控制面执行  bash 14-deploy-ingestion.sh
#
# 它在链路里的位置：
#   Prometheus(规则) → Alertmanager(receiver=aisre-webhook) → aisre-ingest → Event → JSONL
#
# 部署前的问题（本脚本要修的）：
#   Alertmanager 日志里一直是
#     err="aisre-webhook/webhook[0]: notify retry canceled after 10 attempts: Post \"...\""
#   因为 receiver 指向的 aisre-ingest 根本不存在 —— 告警"能产生、发不出去"。
#
# 前置：
#   - 集群就绪（03/04），Alertmanager 已部署（09）
#   - 节点上有 docker.io/library/golang:1.23-alpine（源码挂载 + 容器内编译，无需构建镜像）
#     拉取命令（国内镜像站，实测 48s / 74.5MB）：
#       ctr -n k8s.io images pull --platform linux/amd64 docker.m.daocloud.io/library/golang:1.23-alpine
#       ctr -n k8s.io images tag docker.m.daocloud.io/library/golang:1.23-alpine docker.io/library/golang:1.23-alpine
# ============================================================================
set -uo pipefail

D="/opt/aisre/manifests/aiops"
NS="aiops"
DEPLOY="aisre-ingest"
C_R=$'\033[0;31m'; C_G=$'\033[0;32m'; C_Y=$'\033[0;33m'; C_B=$'\033[0;36m'; C_0=$'\033[0m'
ok()   { printf '  %s✔%s %s\n' "$C_G" "$C_0" "$*"; }
bad()  { printf '  %s✘%s %s\n' "$C_R" "$C_0" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_Y" "$C_0" "$*"; }
step() { printf '\n%s== %s ==%s\n' "$C_B" "$*" "$C_0"; }

[ "$(id -u)" -eq 0 ] || { echo "必须以 root 执行"; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "未找到 kubectl（本脚本需在控制面执行）"; exit 1; }
[ -f "$D/01-ingest.yaml" ] || { echo "清单不存在: $D/01-ingest.yaml"; exit 1; }

step "1/4 命名空间"
kubectl apply -f "$D/00-namespace.yaml" 2>&1 | sed 's/^/  /'

step "2/4 应用清单（ConfigMap 源码 / Deployment / Service）"
OUT="$(kubectl apply -f "$D/01-ingest.yaml" 2>&1)"
printf '%s\n' "$OUT" | sed 's/^/  /'
if printf '%s' "$OUT" | grep -qiE 'Error from server|^error'; then bad "应用失败"; exit 1; fi

step "3/4 等待就绪（镜像内要先编译，最多 360s）"
kubectl -n "$NS" rollout status "deploy/$DEPLOY" --timeout=360s 2>&1 | tail -2 | sed 's/^/  /'
for i in $(seq 1 60); do
  RDY=$(kubectl -n "$NS" get pod -l app=$DEPLOY -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null)
  [ "$RDY" = "true" ] && break
  sleep 5
done

step "4/4 自检：从业务 Pod 侧 POST 一条合成 webhook"
POD=$(kubectl -n "$NS" get pod -l app=$DEPLOY -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
READY=$(kubectl -n "$NS" get pod -l app=$DEPLOY -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null)
if [ "$READY" = "true" ]; then ok "Pod $POD ready=true"; else bad "Pod $POD ready=${READY:-未知}"; fi

echo "  ── 存活/就绪端点（镜像自带 busybox wget）──"
kubectl -n "$NS" exec "deploy/$DEPLOY" -- sh -c 'wget -qO- http://127.0.0.1:8080/healthz; wget -qO- http://127.0.0.1:8080/readyz' 2>&1 | sed 's/^/    /'

echo "  ── 从业务 Pod 发一条合成告警 ──"
FE=$(kubectl -n demo-app get pod -l app=frontend -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$FE" ]; then
  kubectl -n demo-app exec "$FE" -- python3 -c "
import json,time,urllib.request
now=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
payload={'version':'4','status':'firing','receiver':'aisre-webhook',
 'groupKey':'{}:{alertname=\"DeploySelfTest\"}',
 'alerts':[{'status':'firing',
   'labels':{'alertname':'DeploySelfTest','severity':'info','namespace':'aiops',
             'service':'deploy-check','alertstatus':'firing','ground-truth':'self-test'},
   'annotations':{'summary':'部署自检告警'},
   'startsAt':now,'endsAt':now,'fingerprint':'deploy-selftest'}]}
req=urllib.request.Request('http://aisre-ingest.aiops.svc:8080/webhook/alertmanager',
  data=json.dumps(payload).encode(), headers={'Content-Type':'application/json'})
print('    POST /webhook/alertmanager ->', urllib.request.urlopen(req, timeout=6).read().decode().strip())
print('    GET  /stats              ->', urllib.request.urlopen('http://aisre-ingest.aiops.svc:8080/stats', timeout=6).read().decode().strip())
" 2>&1 | sed 's/^/  /'
else
  warn "未找到业务 Pod（demo-app/frontend），跳过合成告警自检"
fi

echo "  ── 事件文件 ──"
kubectl -n "$NS" exec "deploy/$DEPLOY" -- sh -c 'ls -l /data/events.jsonl 2>/dev/null && tail -1 /data/events.jsonl' 2>&1 | sed 's/^/    /'

echo
printf '%s链路说明：%s\n' "$C_B" "$C_0"
printf '  · Alertmanager receiver: http://aisre-ingest.aiops.svc:8080/webhook/alertmanager\n'
printf '  · 事件落盘（宿主机）  : k8s-ai:/var/lib/aisre/aiops/ingest/events.jsonl\n'
printf '  · 查看最近事件        : kubectl -n aiops exec deploy/aisre-ingest -- wget -qO- http://127.0.0.1:8080/events?limit=5\n'
printf '  · 验证通知是否真的发出去了：\n'
printf '      kubectl -n observability logs deploy/alertmanager --tail=50 | grep -iE "notify|failed"\n'
printf '      curl -s --get "http://127.0.0.1:30090/api/v1/query" --data-urlencode "query=increase(alertmanager_notifications_failed_total[10m])"\n'