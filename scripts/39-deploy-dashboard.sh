#!/usr/bin/env bash
# ============================================================================
# 39-deploy-dashboard.sh —— 部署 / 更新 AI SRE 图形化控制台（集群内）
#
# 用法（在控制面执行）：
#     bash 39-deploy-dashboard.sh
#
# 它做四件事：
#   ① 用 /opt/aisre/scripts/38-dashboard.py 生成/更新代码 ConfigMap
#   ② 用 /opt/aisre/dashboard-data/* 生成/更新数据快照 ConfigMap
#   ③ apply 清单（SA / RBAC / Deployment / NodePort Service）
#   ④ 滚动重启 + 等就绪 + 打印访问地址
#
# 之所以用 ConfigMap 而不是自建镜像：
#   节点上没有 Docker/构建环境，而 python:3.12-alpine 已在业务节点（demo-app 同款）。
#   改控制台代码只需要更新 ConfigMap 并重启 —— 免镜像分发（P36 的同思路：单一事实来源）。
# ============================================================================
set -uo pipefail

NS=aiops
CODE_CM=aisre-dashboard-code
DATA_CM=aisre-dashboard-data
MANIFEST=/opt/aisre/manifests/aiops/03-dashboard.yaml
DATA_DIR=/opt/aisre/dashboard-data
NODEPORT=30088

C_R=$'\033[0;31m'; C_G=$'\033[0;32m'; C_B=$'\033[0;36m'; C_0=$'\033[0m'
ok()   { printf '  %s✔%s %s\n' "$C_G" "$C_0" "$*"; }
bad()  { printf '  %s✘%s %s\n' "$C_R" "$C_0" "$*"; }
step() { printf '\n%s══ %s ══%s\n' "$C_B" "$*" "$C_0"; }

command -v kubectl >/dev/null 2>&1 || { echo "需要 kubectl（控制面执行）"; exit 1; }
[ -f /opt/aisre/scripts/38-dashboard.py ] || { echo "缺 /opt/aisre/scripts/38-dashboard.py"; exit 1; }
[ -f "$MANIFEST" ] || { echo "缺 $MANIFEST"; exit 1; }

step "1/4 更新代码 ConfigMap"
kubectl -n "$NS" create configmap "$CODE_CM" \
  --from-file=dashboard.py=/opt/aisre/scripts/38-dashboard.py \
  --dry-run=client -o yaml 2>/dev/null | kubectl apply -f - | sed 's/^/  /'
ok "代码：$(wc -l < /opt/aisre/scripts/38-dashboard.py) 行"

step "2/4 更新数据快照 ConfigMap"
ARGS=()
for f in matrix.jsonl matrix_eval.json matrix_eval.md rca_records.json repeats_summary.json rag_ab_summary.json extra_datasets.json; do
  if [ -f "$DATA_DIR/$f" ]; then ARGS+=("--from-file=$f=$DATA_DIR/$f"); fi
done
if [ "${#ARGS[@]}" -eq 0 ]; then
  bad "没有可用的数据文件（$DATA_DIR 为空）—— 建一个占位，避免 Pod 起不来"
  mkdir -p "$DATA_DIR"; echo "{}" > "$DATA_DIR/empty.json"; ARGS+=("--from-file=empty.json=$DATA_DIR/empty.json")
fi
kubectl -n "$NS" create configmap "$DATA_CM" "${ARGS[@]}" \
  --dry-run=client -o yaml 2>/dev/null | kubectl apply -f - | sed 's/^/  /'
printf '  快照内容：%s\n' "$(ls -1 "$DATA_DIR" 2>/dev/null | tr '\n' ' ')"

step "3/4 应用清单（SA / RBAC / Deployment / Service）"
kubectl apply -f "$MANIFEST" 2>&1 | sed 's/^/  /'

step "4/4 滚动重启并等待就绪"
kubectl -n "$NS" rollout restart deploy/aisre-dashboard >/dev/null 2>&1
if kubectl -n "$NS" rollout status deploy/aisre-dashboard --timeout=180s >/dev/null 2>&1; then
  ok "dashboard 就绪"
else
  bad "未在 180s 内就绪"
  kubectl -n "$NS" logs deploy/aisre-dashboard --tail=20 2>&1 | sed 's/^/      /'
  exit 1
fi

POD=$(kubectl -n "$NS" get pod -l app=aisre-dashboard -o jsonpath='{.items[0].metadata.name}')
NODE=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.spec.nodeName}')
NODEIP=$(kubectl get node "$NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
if kubectl -n "$NS" exec "$POD" -- wget -qO- "http://127.0.0.1:8787/healthz" >/dev/null 2>&1; then
  ok "自检 /healthz 通过（Pod=$POD Node=$NODE）"
else
  bad "自检失败"
fi

echo
printf '%s══ 访问地址 ══%s\n' "$C_B" "$C_0"
printf '%s  主推：  http://172.29.20.21:%s  （控制面 k8s-cp）%s\n' "$C_G" "$NODEPORT" "$C_0"
echo  "  备用（NodePort 在任意节点都可达）："
for ip in 172.29.20.22 172.29.20.23 172.29.20.24 172.29.20.25; do
  printf '          http://%s:%s\n' "$ip" "$NODEPORT"
done
printf '  （Pod 实际在 %s；标签页：总览 / 大模型 / Agent / 实验 / 图表）\n' "$NODE"
echo
echo "  更新数据快照： 把新文件放进 $DATA_DIR 后重跑本脚本"
