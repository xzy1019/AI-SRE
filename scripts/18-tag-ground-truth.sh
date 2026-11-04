#!/usr/bin/env bash
# ============================================================================
# 18-tag-ground-truth.sh —— ground truth 标签传播（注入前打标 / 跑完清标）
#
# 为什么需要它：
#   之前数据集的 ground truth 是"按时间窗事后贴"的（窗口里所有告警都算这次故障的），
#   这是个假设，不是事实。本脚本在**注入前**给目标服务的 Pod 打上
#       ground-truth: <service>
#   标签，配合 Prometheus 的 relabel（已加：
#       source_labels: [__meta_kubernetes_pod_label_ground_truth] → target_label: ground_truth）
#   让**指标自带答案**，一路流到告警标签 → Alertmanager → aisre-ingest → events.jsonl 的
#   ground_truth 字段。数据自己带标注，事后分析不需要再猜。
#
# 用法（在控制面执行）：
#     bash 18-tag-ground-truth.sh set   payment payment-service     # 注入前打标
#     bash 18-tag-ground-truth.sh clean payment                     # 跑完清理
#     bash 18-tag-ground-truth.sh list                              # 看当前打了哪些标
#
# 注意：只改 Deployment 的 pod 模板（新 Pod 自动继承）+ 现有 Pod（立即生效），
#       不重启 Pod，所以不会干扰正在进行的实验。
# ============================================================================
set -uo pipefail

NS="${NS:-demo-app}"
DEPLOY="${DEPLOY:-}"          # 由参数覆盖
ACTION="${1:-}"
APP="${2:-}"
SVC="${3:-}"
C_G=$'\033[0;32m'; C_Y=$'\033[0;33m'; C_0=$'\033[0m'

case "$ACTION" in
  set)
    [ -n "$APP" ] && [ -n "$SVC" ] || { echo "用法: $0 set <app1,app2,...> <service>"; exit 1; }
    echo "  给 $NS/$APP 打标 ground-truth=$SVC（支持逗号分隔多个 app）"
    # 1) 只补 Pod 标签，不动 pod 模板 → 避免触发滚动更新（实验期间不能让业务重启）
    #    代价：Pod 被重建后标签会丢（pod-kill 场景需重打），这一点在文档里写明
    for a in $(echo "$APP" | tr ',' ' '); do
      kubectl -n "$NS" label pod -l "app=$a" "ground-truth=$SVC" --overwrite 2>&1 | sed 's/^/    /'
      kubectl -n "$NS" label svc "$a" "ground-truth=$SVC" --overwrite 2>&1 | sed 's/^/    /'
    done
    echo "  ${C_G}✔${C_0} 已打标（指标将在下一次抓取时带上 ground_truth 标签）"
    ;;
  clean)
    [ -n "$APP" ] || { echo "用法: $0 clean <app>"; exit 1; }
    for a in $(echo "$APP" | tr ',' ' '); do
      kubectl -n "$NS" label pod -l "app=$a" 'ground-truth-' 2>&1 | sed 's/^/    /'
      kubectl -n "$NS" label svc "$a" 'ground-truth-' 2>&1 | sed 's/^/    /'
    done
    echo "  ${C_G}✔${C_0} 已清理 $APP 的 ground-truth 标签"
    ;;
  list)
    echo "  ── Pod 上的 ground-truth 标签 ──"
    kubectl -n "$NS" get pod -o custom-columns=POD:.metadata.name,APP:.metadata.labels.app,GT:.metadata.labels.ground-truth --no-headers 2>/dev/null | sed 's/^/    /'
    ;;
  *)
    echo "用法:"
    echo "  $0 set   <app1,app2> <service>   # 注入前打标（建议整条链都打）"
    echo "  $0 clean <app1,app2>             # 跑完清理"
    echo "  $0 list                     # 查看当前标签"
    exit 1
    ;;
esac