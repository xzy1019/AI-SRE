#!/usr/bin/env bash
# ============================================================================
# 05-verify-cluster.sh —— 集群就绪验证（只读）
#
# 用法： 在控制面执行  bash 05-verify-cluster.sh
# ============================================================================
set -uo pipefail

C_R=$'\033[0;31m'; C_G=$'\033[0;32m'; C_Y=$'\033[0;33m'; C_B=$'\033[0;36m'; C_0=$'\033[0m'
PASS=0; FAIL=0
ok()  { printf '  %s✔%s %s\n' "$C_G" "$C_0" "$*"; PASS=$((PASS+1)); }
bad() { printf '  %s✘%s %s\n' "$C_R" "$C_0" "$*"; FAIL=$((FAIL+1)); }
sec() { printf '\n%s── %s ──%s\n' "$C_B" "$*" "$C_0"; }

command -v kubectl >/dev/null 2>&1 || { echo "未找到 kubectl"; exit 1; }

sec "集群节点（期望 5 台 Ready）"
OUT="$(kubectl get nodes --no-headers 2>/dev/null)"
if [ -z "$OUT" ]; then
  bad "无法获取节点列表"
else
  printf '%s\n' "$OUT" | awk '{printf "     %-12s %-10s %-14s %s\n", $1, $2, $3, $6}'
  T="$(printf '%s\n' "$OUT" | grep -c .)"
  R="$(printf '%s\n' "$OUT" | grep -c ' Ready ')"
  [ "$T" = "5" ] && ok "节点总数 = 5" || bad "节点总数 = ${T}（期望 5）"
  [ "$R" = "5" ] && ok "Ready 节点数 = 5" || bad "Ready 节点数 = ${R}（期望 5）"
fi

sec "系统组件"
for ns in kube-system kube-flannel; do
  N="$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep -vcE 'Running|Completed')"
  [ "${N:-1}" = "0" ] && ok "${ns} 无异常 Pod" || bad "${ns} 有 ${N} 个异常 Pod"
done

sec "CNI"
if ls /etc/cni/net.d/ 2>/dev/null | grep -q flannel; then ok "flannel 配置文件存在"; else bad "未找到 flannel 配置"; fi
DS="$(kubectl get ds -n kube-flannel --no-headers 2>/dev/null | awk '{print $4"/"$2}' | head -1)"
[ "$DS" = "5/5" ] && ok "flannel DaemonSet = 5/5" || bad "flannel DaemonSet = ${DS:-无}（期望 5/5）"

sec "控制面组件"
for c in etcd kube-apiserver kube-controller-manager kube-scheduler; do
  CNT="$(kubectl get pods -n kube-system -l component=$c --no-headers 2>/dev/null | grep -c Running)"
  [ "${CNT:-0}" -ge 1 ] && ok "$c 运行中" || bad "$c 未运行"
done

sec "CNI 插件"
for b in loopback bridge host-local portmap flannel; do
  [ -x "/opt/cni/bin/$b" ] && ok "插件 ${b} 存在" || bad "插件 ${b} 缺失"
done
sec "资源占用"
if kubectl top nodes >/dev/null 2>&1; then
  kubectl top nodes | sed 's/^/     /'
else
  printf '     metrics-server 未安装，跳过（kubectl top 不可用）\n'
fi

printf '\n%s════════════════════════════════════%s\n' "$C_B" "$C_0"
printf '  通过 %s%d%s   失败 %s%d%s\n' "$C_G" "$PASS" "$C_0" "$C_R" "$FAIL" "$C_0"
printf '%s════════════════════════════════════%s\n' "$C_B" "$C_0"
[ "$FAIL" -eq 0 ] && printf '%s集群验证通过%s\n' "$C_G" "$C_0" || printf '%s存在未通过项%s\n' "$C_R" "$C_0"
exit 0