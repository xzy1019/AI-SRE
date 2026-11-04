#!/usr/bin/env bash
# ============================================================================
# 03-init-cluster.sh —— 初始化 Kubernetes 控制面（幂等）
#
# 用法： 仅在 k8s-cp 上执行  bash 03-init-cluster.sh
#
# 内容：
#   1. 前置检查（CRI、端口、容器运行时）
#   2. 预拉取控制面镜像
#   3. kubeadm init
#   4. 配置 kubeconfig
#   5. 安装 Flannel CNI（使用本地清单，集群侧无需访问 GitHub）
#   6. 生成节点加入命令
#
# 前置：所有节点需先执行 01-baseline.sh 与 02-node-runtime.sh
# ============================================================================
set -uo pipefail

CP_IP="172.29.20.21"
POD_CIDR="10.244.0.0/16"
SERVICE_CIDR="10.96.0.0/12"
IMAGE_REPO="registry.cn-hangzhou.aliyuncs.com/google_containers"
CRI_SOCK="unix:///run/containerd/containerd.sock"
JOIN_FILE="/opt/cluster-join.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CNI_MANIFEST="${SCRIPT_DIR}/../manifests/kube-flannel.yml"

C_R=$'\033[0;31m'; C_G=$'\033[0;32m'; C_Y=$'\033[0;33m'; C_B=$'\033[0;36m'; C_0=$'\033[0m'
PASS=0; WARN=0; FAIL=0
step() { printf '\n%s== %s ==%s\n' "$C_B" "$*" "$C_0"; }
ok()   { printf '  %s✔%s %s\n' "$C_G" "$C_0" "$*"; PASS=$((PASS+1)); }
warn() { printf '  %s!%s %s\n' "$C_Y" "$C_0" "$*"; WARN=$((WARN+1)); }
err()  { printf '  %s✘%s %s\n' "$C_R" "$C_0" "$*"; FAIL=$((FAIL+1)); }
die()  { printf '\n%s%s%s\n' "$C_R" "$*" "$C_0"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "必须以 root 执行"

MY_IP="$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1)"
printf '%s初始化控制面：%s (%s)%s\n' "$C_B" "$(hostname)" "$MY_IP" "$C_0"
[ "$MY_IP" = "$CP_IP" ] || die "本脚本只能在控制面 ${CP_IP} 上执行（当前 ${MY_IP}）"

# ---------------------------------------------------------------- 前置检查
step "0/7 前置检查"
command -v kubeadm >/dev/null 2>&1 || die "未找到 kubeadm，请先执行 02-node-runtime.sh"
ok "kubeadm 存在（$(kubeadm version -o short 2>/dev/null)）"
systemctl is-active --quiet containerd && ok "containerd 运行中" || die "containerd 未运行"
[ -S /run/containerd/containerd.sock ] && ok "CRI socket 存在" || die "CRI socket 不存在"
if ss -lntp 2>/dev/null | grep -q ':6443 '; then
  err "端口 6443 已被占用"
else
  ok "端口 6443 空闲"
fi
[ -f "$CNI_MANIFEST" ] && ok "CNI 清单存在" || err "CNI 清单缺失：${CNI_MANIFEST}"

# ---------------------------------------------------------------- 是否已初始化
step "1/7 集群状态"
if [ -f /etc/kubernetes/admin.conf ]; then
  warn "检测到已初始化的集群，跳过 kubeadm init"
  ALREADY=1
else
  ALREADY=0
  if [ -d /etc/kubernetes ] && [ -n "$(ls -A /etc/kubernetes 2>/dev/null)" ]; then
    warn "/etc/kubernetes 存在残留内容，init 可能失败；如有问题请先执行 kubeadm reset -f"
  fi
  ok "未初始化，继续"
fi

# ---------------------------------------------------------------- 预拉镜像
step "2/7 预拉取控制面镜像"
if [ "$ALREADY" -eq 0 ]; then
  if kubeadm config images pull --image-repository "$IMAGE_REPO" --cri-socket "$CRI_SOCK" 2>&1 | tail -3; then
    ok "镜像拉取完成"
  else
    warn "镜像拉取未完全成功，kubeadm init 时会自动重试"
  fi
else
  ok "已初始化，跳过"
fi

# ---------------------------------------------------------------- init
step "3/7 kubeadm init"
if [ "$ALREADY" -eq 1 ]; then
  ok "跳过"
else
  INIT_LOG=/tmp/kubeadm-init.log
  if kubeadm init \
      --control-plane-endpoint="${CP_IP}:6443" \
      --apiserver-advertise-address="${MY_IP}" \
      --pod-network-cidr="${POD_CIDR}" \
      --service-cidr="${SERVICE_CIDR}" \
      --image-repository="${IMAGE_REPO}" \
      --cri-socket "${CRI_SOCK}" > "$INIT_LOG" 2>&1; then
    ok "kubeadm init 成功"
    grep -E '^\s*(Your Kubernetes control-plane|Then you can join)' "$INIT_LOG" >/dev/null 2>&1 || true
  else
    err "kubeadm init 失败，日志末尾："
    tail -25 "$INIT_LOG" | sed 's/^/      /'
    printf '\n  完整日志：%s\n' "$INIT_LOG"
    exit 1
  fi
fi

# ---------------------------------------------------------------- kubeconfig
step "4/7 kubeconfig"
mkdir -p /root/.kube
cp -f /etc/kubernetes/admin.conf /root/.kube/config
chmod 600 /root/.kube/config
for u in $(awk -F: '$3>=1000 && $3<65534 {print $1}' /etc/passwd); do
  uh="$(getent passwd "$u" | cut -d: -f6)"
  [ -d "$uh" ] || continue
  mkdir -p "${uh}/.kube"
  cp -f /etc/kubernetes/admin.conf "${uh}/.kube/config"
  chown -R "${u}:${u}" "${uh}/.kube"
done
ok "kubeconfig 已就绪（root 及普通用户）"

# 等待 API 可用
for i in $(seq 1 30); do
  kubectl version >/dev/null 2>&1 && break
  sleep 2
done
kubectl get --raw='/readyz' >/dev/null 2>&1 && ok "API Server 就绪" || err "API Server 未就绪"

# ---------------------------------------------------------------- CNI
step "5/7 安装 CNI（Flannel）"
if [ -f /etc/cni/net.d/10-flannel.conflist ]; then
  ok "Flannel 已安装"
else
  if kubectl apply -f "$CNI_MANIFEST" >/dev/null 2>&1; then
    ok "已应用 Flannel 清单"
  else
    err "CNI 应用失败"
  fi
fi

# ---------------------------------------------------------------- 等待 Ready
step "6/7 等待控制面 Ready"
READY=0
for i in $(seq 1 60); do
  st="$(kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}' | head -1)"
  case "$st" in
    Ready) READY=1; break ;;
  esac
  sleep 5
done
if [ "$READY" -eq 1 ]; then
  ok "节点已 Ready"
else
  err "180 秒内未 Ready，当前状态："
  kubectl get nodes 2>&1 | sed 's/^/      /'
  printf '\n  排查建议：\n'
  printf '    kubectl -n kube-flannel get pods\n'
  printf '    journalctl -u kubelet -n 30 --no-pager\n'
fi

# ---------------------------------------------------------------- join 命令
step "7/7 生成节点加入命令"
if kubeadm token create --print-join-command > "$JOIN_FILE" 2>/dev/null; then
  chmod 700 "$JOIN_FILE"
  ok "已写入 ${JOIN_FILE}"
else
  err "生成失败"
fi

# ---------------------------------------------------------------- 汇总
printf '\n%s──────────── 集群状态 ────────────%s\n' "$C_B" "$C_0"
kubectl get nodes -o wide 2>&1 | sed 's/^/  /'
printf '\n'
kubectl get pods -n kube-flannel 2>&1 | sed 's/^/  /'
printf '\n%s──────────── 汇总 ────────────%s\n' "$C_B" "$C_0"
printf '  通过 %s%d%s   提示 %s%d%s   失败 %s%d%s\n' "$C_G" "$PASS" "$C_0" "$C_Y" "$WARN" "$C_0" "$C_R" "$FAIL" "$C_0"
printf '%s────────────────────────────────%s\n' "$C_B" "$C_0"

if [ "$FAIL" -gt 0 ]; then printf '%s存在失败项%s\n' "$C_R" "$C_0"; exit 1; fi

printf '\n%s控制面就绪。其余节点加入方式：%s\n' "$C_G" "$C_0"
printf '  在每台 worker 上执行：\n'
printf '    bash 04-join-cluster.sh "$(cat %s)"\n' "$JOIN_FILE"