#!/usr/bin/env bash
# ============================================================================
# 26-apply-grafana-dashboards.sh —— 应用 3 个定制 Grafana 仪表盘（幂等）
#
# 用法： 在控制面执行  bash 26-apply-grafana-dashboards.sh
#
# 做什么：
#   1. 应用 09-grafana-dashboards.yaml（3 个 ConfigMap：overview / demo-sli / aiops-chain）
#   2. 应用 07-grafana.yaml（数据源加固定 uid + 把仪表盘挂到 /var/lib/grafana/dashboards）
#   3. 重启 Grafana，等待就绪，然后用 Grafana API 逐个验证仪表盘已加载
#
# 为什么数据源要固定 uid：仪表盘 JSON 里用 {"type":"prometheus","uid":"prometheus"} 引用数据源；
#   如果数据源 uid 是随机生成的，面板会显示 "No data"（这是 Grafana 供给式配置的常见坑）。
# ============================================================================
set -uo pipefail
D="/opt/aisre/manifests/observability"
NS="observability"
C_R=$'\033[0;31m'; C_G=$'\033[0;32m'; C_Y=$'\033[0;33m'; C_B=$'\033[0;36m'; C_0=$'\033[0m'
ok()   { printf '  %s✔%s %s\n' "$C_G" "$C_0" "$*"; }
bad()  { printf '  %s✘%s %s\n' "$C_R" "$C_0" "$*"; }
step() { printf '\n%s== %s ==%s\n' "$C_B" "$*" "$C_0"; }

[ "$(id -u)" -eq 0 ] || { echo "必须以 root 执行"; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "未找到 kubectl"; exit 1; }

step "1/4 应用仪表盘与 Grafana 清单"
for f in 09-grafana-dashboards.yaml 07-grafana.yaml; do
  printf '  %-28s ' "$f"
  OUT="$(kubectl apply -f "$D/$f" 2>&1)"
  if printf '%s' "$OUT" | grep -qiE 'Error from server|^error'; then echo "${C_R}✘${C_0}"; echo "$OUT" | head -3 | sed 's/^/      /'; exit 1
  else echo "✔ $(printf '%s' "$OUT" | grep -c 'created\|configured\|unchanged') 个资源"; fi
done

step "2/4 重启 Grafana 并等待就绪"
kubectl -n "$NS" rollout restart deployment/grafana >/dev/null
kubectl -n "$NS" rollout status deployment/grafana --timeout=180s 2>&1 | tail -1 | sed 's/^/  /'

step "3/4 用 Grafana API 验证仪表盘已加载"
# 【踩坑】不要用 `wget -U user:pass` —— busybox wget 的 -U 是 User-Agent，不是认证，
# 结果会 401，看起来像"仪表盘没加载"（实测误报过一次）。这里用 curl -u 走 NodePort 校验。
sleep 15
for uid in aisre-overview aisre-demo-sli aisre-aiops-chain; do
  printf '  %-20s ' "$uid"
  BODY=$(curl -s -u admin:aisre-lab-admin "http://127.0.0.1:30030/api/dashboards/uid/$uid")
  echo "$BODY" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    if 'dashboard' in d: print('✔ 面板数=%d  标题=%s' % (len(d['dashboard'].get('panels',[])), d['dashboard'].get('title')))
    else: print('✘', str(d)[:80])
except Exception as e:
    print('✘ 解析失败:', e)
"
done
printf '  %-20s ' "数据源 uid"
curl -s -u admin:aisre-lab-admin http://127.0.0.1:30030/api/datasources | python3 -c "
import json,sys
ds=json.load(sys.stdin); print('✔ ' + ', '.join('%s=%s' % (d['name'], d['uid']) for d in ds))
"
printf '  %-20s ' "数据是否通"
curl -s -u admin:aisre-lab-admin --get 'http://127.0.0.1:30030/api/datasources/proxy/uid/prometheus/api/v1/query' \
  --data-urlencode 'query=sum(rate(http_requests_total{job="demo-app"}[1m]))' \
  | python3 -c "import json,sys;d=json.load(sys.stdin);r=d['data']['result'];print('✔ 业务 QPS = %s' % (round(float(r[0]['value'][1]),3) if r else 0))"

step "4/4 提示"
printf '  访问：http://<节点IP>:30030  (admin / aisre-lab-admin)\n'
printf '  三个盘：AISRE · 总览 ／ AISRE · 业务 SLI（demo-app）／ AISRE · AIOPS 自愈链路\n'
printf '  %s改法：编辑 manifests/observability/dashboards/*.json → 重新生成 09 清单 → 再跑本脚本%s\n' "$C_Y" "$C_0"