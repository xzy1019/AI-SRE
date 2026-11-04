#!/usr/bin/env bash
# ============================================================================
# 04-join-cluster.sh —— 将 worker 节点加入集群（幂等）
#
# 用法：
#   bash 04-join-cluster.sh "kubeadm join 172.29.20.21:6443 --token ... "
#   或  bash 04-join-cluster.sh          # 从 /tmp/join.sh 读取
#
# 前置：已执行 01-baseline.sh 与 02-node-runtime.sh
# ============================================================================
set -uo pipefail

CP_IP="172.29.20.21"
CRI_SOCK="unix:///run/containerd/containerd.sock"

C_R=$'\033[0;31m'; C_G=$'\033[0;32m'; C_Y=$'\033[0;33m'; C_B=$'\033[0;36m'; C_0=$'\033[0m'
PASS=0; WARN=0; FAIL=0
step() { printf '\n%s== %s ==%s\n' "$C_B" "$*" "$C_0"; }
ok()   { printf '  %s✔%s %s\n' "$C_G" "$C_0" "$*"; PASS=$((PASS+1)); }
warn() { printf '  %s!%s %s\n' "$C_Y" "$C_0" "$*"; WARN=$((WARN+1)); }
err()  { printf '  %s✘%s %s\n' "$C_R" "$C_0" "$*"; FAIL=$((FAIL+1)); }
die()  { printf '\n%s%s%s\n' "$C_R" "$*" "$C_0"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "必须以 root 执行"

MY_IP="$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1)"
printf '%s节点加入：%s (%s)%s\n' "$C_B" "$(hostname)" "$MY_IP" "$C_0"

# ---------------------------------------------------------------- 前置检查
step "0/4 前置检查"
[ "$MY_IP" = "$CP_IP" ] && die "本脚本用于 worker 节点，不能在控制面执行"
ok "确认非控制面节点"
command -v kubeadm >/dev/null 2>&1 || die "未找到 kubeadm，请先执行 02-node-runtime.sh"
ok "kubeadm 存在"
systemctl is-active --quiet containerd && ok "containerd 运行中" || die "containerd 未运行"
[ -S /run/containerd/containerd.sock ] && ok "CRI socket 存在" || die "CRI socket 不存在"

# ---------------------------------------------------------------- 是否已加入
step "1/4 集群状态"
if [ -f /etc/kubernetes/kubelet.conf ]; then
  ok "本节点已加入集群，跳过"
  ALREADY=1
else
  ALREADY=0
  ok "未加入，继续"
fi

# ---------------------------------------------------------------- 取加入命令
step "2/4 获取加入命令"
JOIN_CMD="${1:-}"
if [ "$ALREADY" -eq 1 ]; then
  ok "跳过"
elif [ -n "$JOIN_CMD" ]; then
  ok "使用命令行参数"
elif [ -f /tmp/join.sh ]; then
  JOIN_CMD="$(cat /tmp/join.sh)"
  ok "从 /tmp/join.sh 读取"
else
  die "未提供加入命令。用法：bash 04-join-cluster.sh \"kubeadm join ...\""
fi

# ---------------------------------------------------------------- 执行 join
step "3/4 加入集群"
if [ "$ALREADY" -eq 1 ]; then
  ok "跳过"
else
  JOIN_LOG=/tmp/kubeadm-join.log
  if eval "$JOIN_CMD --cri-socket ${CRI_SOCK}" > "$JOIN_LOG" 2>&1; then
    ok "加入成功"
  else
    err "加入失败，日志末尾："
    tail -25 "$JOIN_LOG" | sed 's/^/      /'
    printf '\n  常见原因：token 过期 / 控制面不可达 / 6443 被防火墙拦截\n'
    printf '  重新生成 token：在控制面执行  kubeadm token create --print-join-command\n'
    exit 1
  fi
fi

# ---------------------------------------------------------------- 验证
step "4/4 服务状态"
systemctl enable --now kubelet >/dev/null 2>&1
sleep 5
systemctl is-active --quiet kubelet && ok "kubelet 运行中" || err "kubelet 未运行"

# kubelet 客户端证书生成后该文件才出现，作为加入成功的判据
CNT=0
while [ "$CNT" -lt 12 ]; do
  [ -f /etc/kubernetes/kubelet.conf ] && break
  sleep 5; CNT=$((CNT+1))
done
[ -f /etc/kubernetes/kubelet.conf ] && ok "kubelet.conf 已生成" || err "kubelet.conf 未生成"

printf '\n%s────────────────────────────────────%s\n' "$C_B" "$C_0"
printf '%s完成：%s\n' "$C_B" "$(hostname)"
printf '  通过 %s%d%s   提示 %s%d%s   失败 %s%d%s\n' "$C_G" "$PASS" "$C_0" "$C_Y" "$WARN" "$C_0" "$C_R" "$FAIL" "$C_0"
printf '%s────────────────────────────────────%s\n' "$C_B" "$C_0"
[ "$FAIL" -gt 0 ] && { printf '%s存在失败项%s\n' "$C_R" "$C_0"; exit 1; }
printf '%s节点已加入集群%s\n' "$C_G" "$C_0"