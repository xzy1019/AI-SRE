#!/usr/bin/env bash
# ============================================================================
# 24-deploy-agent.sh —— 部署 aisre-agent（自愈执行层：策略引擎 + 执行器 + 审计链，幂等）
#
# 用法： 在控制面执行  bash 24-deploy-agent.sh
#
# 部署内容（命名空间 aiops）：
#   ServiceAccount aisre-agent + Role/RoleBinding（仅 demo-app 的 deployments get/list/patch）
#   ConfigMap aisre-agent-src（Go 源码）+ Deployment + Service
#
# 为什么权限只给这么点：
#   自愈服务的风险不在"能不能改"，而在"改错了怎么办"。所以：
#     · RBAC 层最小授权（只有 demo-app 的 deployments）
#     · 策略层再挡一道（8 条校验，含白名单/冷却/频率/爆炸半径/前置条件）
#     · 审计层留痕（哈希链，可验证是否被篡改）
#   三者缺一，自动修复都不该被允许进入生产。
# ============================================================================
set -uo pipefail

D="/opt/aisre/manifests/aiops"
NS="aiops"
DEPLOY="aisre-agent"
C_R=$'\033[0;31m'; C_G=$'\033[0;32m'; C_Y=$'\033[0;33m'; C_B=$'\033[0;36m'; C_0=$'\033[0m'
ok()   { printf '  %s✔%s %s\n' "$C_G" "$C_0" "$*"; }
bad()  { printf '  %s✘%s %s\n' "$C_R" "$C_0" "$*"; }
step() { printf '\n%s== %s ==%s\n' "$C_B" "$*" "$C_0"; }

[ "$(id -u)" -eq 0 ] || { echo "必须以 root 执行"; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "未找到 kubectl（本脚本需在控制面执行）"; exit 1; }
[ -f "$D/02-agent.yaml" ] || { echo "清单不存在: $D/02-agent.yaml"; exit 1; }

step "1/4 命名空间与清单"
kubectl apply -f "$D/00-namespace.yaml" 2>&1 | sed 's/^/  /'
OUT="$(kubectl apply -f "$D/02-agent.yaml" 2>&1)"
printf '%s\n' "$OUT" | sed 's/^/  /'
printf '%s' "$OUT" | grep -qiE 'Error from server|^error' && { bad "应用失败"; exit 1; }

step "2/4 等待就绪（容器内编译，最多 360s）"
kubectl -n "$NS" rollout status "deploy/$DEPLOY" --timeout=360s 2>&1 | tail -2 | sed 's/^/  /'

step "3/4 自检：策略清单 + 审计链"
kubectl -n "$NS" exec "deploy/$DEPLOY" -- sh -c '
  echo "  ── 策略（GET /policies）──"
  wget -qO- http://127.0.0.1:8080/policies | head -c 600; echo
  echo "  ── 审计链完整性（GET /audit/verify）──"
  wget -qO- http://127.0.0.1:8080/audit/verify; echo
' 2>&1 | sed 's/^/  /'

step "4/4 提示"
printf '  %s下一步：跑 bash 25-agent-selftest.sh 做 8 项策略的正/反用例验证%s\n' "$C_B" "$C_0"
printf '  审计文件（宿主机）：k8s-ai:/var/lib/aisre/aiops/agent/audit.jsonl\n'