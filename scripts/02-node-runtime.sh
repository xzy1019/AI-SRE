#!/usr/bin/env bash
# ============================================================================
# 02-node-runtime.sh —— 安装容器运行时与 K8s 组件（幂等）
#
# 用法： 在每台节点上执行  bash 02-node-runtime.sh
#
# 内容：
#   1. 依赖包（conntrack-tools / socat / iproute-tc / cri-tools）
#   2. containerd（含 SystemdCgroup、sandbox_image、镜像加速）
#   3. Kubernetes 软件源（阿里云）
#   4. kubelet / kubeadm / kubectl
#
# 前置：需先执行 01-baseline.sh
# ============================================================================
set -uo pipefail

K8S_REPO="https://mirrors.aliyun.com/kubernetes-new/core/stable/v1.31/rpm/"
IMAGE_REPO="registry.cn-hangzhou.aliyuncs.com/google_containers"
DOCKER_MIRRORS=("https://docker.m.daocloud.io" "https://registry.cn-hangzhou.aliyuncs.com")
GHCR_MIRRORS=("https://ghcr.m.daocloud.io" "https://ghcr.nju.edu.cn")
DEPS=(conntrack-tools socat iproute-tc)

C_R=$'\033[0;31m'; C_G=$'\033[0;32m'; C_Y=$'\033[0;33m'; C_B=$'\033[0;36m'; C_0=$'\033[0m'
PASS=0; WARN=0; FAIL=0
step() { printf '\n%s== %s ==%s\n' "$C_B" "$*" "$C_0"; }
ok()   { printf '  %s✔%s %s\n' "$C_G" "$C_0" "$*"; PASS=$((PASS+1)); }
warn() { printf '  %s!%s %s\n' "$C_Y" "$C_0" "$*"; WARN=$((WARN+1)); }
err()  { printf '  %s✘%s %s\n' "$C_R" "$C_0" "$*"; FAIL=$((FAIL+1)); }

[ "$(id -u)" -eq 0 ] || { echo "必须以 root 执行"; exit 1; }
printf '%s节点: %s%s\n' "$C_B" "$(hostname)" "$C_0"

# ---------------------------------------------------------- 前置检查
step "0/6 前置条件"
PREREQ_OK=1
for k in net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables; do
  v="$(sysctl -n "$k" 2>/dev/null)"
  if [ "$v" = "1" ]; then ok "$k = 1"; else err "$k = ${v}（请先执行 01-baseline.sh）"; PREREQ_OK=0; fi
done
if swapon --show --noheadings 2>/dev/null | grep -q .; then
  err "swap 未关闭（请先执行 01-baseline.sh）"; PREREQ_OK=0
else
  ok "swap 已关闭"
fi
[ "$PREREQ_OK" -eq 1 ] || { printf '\n%s前置条件不满足，终止%s\n' "$C_R" "$C_0"; exit 1; }

# ---------------------------------------------------------- 1 依赖包
step "1/6 依赖包"
miss=()
for p in "${DEPS[@]}" cri-tools; do rpm -q "$p" >/dev/null 2>&1 || miss+=("$p"); done
if [ "${#miss[@]}" -eq 0 ]; then
  ok "全部已安装"
else
  warn "缺少：${miss[*]}"
  if dnf install -y -q "${miss[@]}" >/dev/null 2>&1; then ok "安装完成"
  else err "安装失败：${miss[*]}"; fi
fi

# ---------------------------------------------------------- 2 containerd
step "2/6 containerd 安装"
if rpm -q containerd >/dev/null 2>&1; then
  ok "已安装：$(rpm -q --qf '%{VERSION}' containerd)"
else
  if dnf install -y -q containerd >/dev/null 2>&1; then ok "安装完成：$(rpm -q --qf '%{VERSION}' containerd)"
  else err "containerd 安装失败"; fi
fi

# ---------------------------------------------------------- 3 containerd 配置
step "3/6 containerd 配置"
CFG=/etc/containerd/config.toml
mkdir -p /etc/containerd

# 注意：openEuler 的 containerd 包自带一个"占位"配置（仅 17 行注释，无 CRI 插件段）。
# 不能只判断文件是否存在，必须判断内容是否包含 CRI 段，否则 SystemdCgroup
# 和 sandbox_image 都会找不到。
if grep -q 'SystemdCgroup' "$CFG" 2>/dev/null && grep -q 'sandbox_image' "$CFG" 2>/dev/null; then
  ok "配置已就绪（$(wc -l < "$CFG") 行）"
else
  if [ -f "$CFG" ]; then
    cp -a "$CFG" "${CFG}.orig.$(date +%s)" 2>/dev/null
    warn "检测到包自带的占位配置，已备份并重新生成"
  fi
  containerd config default > "$CFG"
  ok "已生成完整默认配置（$(wc -l < "$CFG") 行）"
fi
# cgroup 驱动必须与 kubelet 一致
if grep -q 'SystemdCgroup = false' "$CFG"; then
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' "$CFG"
  ok "SystemdCgroup = true"
elif grep -q 'SystemdCgroup = true' "$CFG"; then
  ok "SystemdCgroup 已是 true"
else
  err "未找到 SystemdCgroup 配置项"
fi

# sandbox_image 指向可达镜像源（kubeadm 要求与自身版本一致）
PAUSE_VER="3.10"
if command -v kubeadm >/dev/null 2>&1; then
  DET="$(kubeadm config images list --image-repository "$IMAGE_REPO" 2>/dev/null | grep '/pause:' | head -1)"
  [ -n "$DET" ] && PAUSE_VER="${DET##*:}"
fi
if grep -q 'sandbox_image' "$CFG"; then
  sed -i "s|^\(\s*\)sandbox_image = .*|\1sandbox_image = \"${IMAGE_REPO}/pause:${PAUSE_VER}\"|" "$CFG"
  ok "sandbox_image → ${IMAGE_REPO}/pause:${PAUSE_VER}"
else
  err "配置中未找到 sandbox_image 项"
fi

# 镜像加速（幂等）。ghcr.io 必须配 —— 其元数据可达，但 blob 存储在
# pkg-containers.githubusercontent.com，国内会被连接重置，导致 ImagePullBackOff。
HAS_DOCKER=0; HAS_GHCR=0
grep -q 'registry.mirrors."docker.io"' "$CFG" 2>/dev/null && HAS_DOCKER=1
grep -q 'registry.mirrors."ghcr.io"'    "$CFG" 2>/dev/null && HAS_GHCR=1

if [ "$HAS_DOCKER" -eq 1 ] && [ "$HAS_GHCR" -eq 1 ]; then
  ok "镜像加速已配置（docker.io + ghcr.io）"
else
  {
    echo ''
    echo '# ---- added by 02-node-runtime.sh ----'
    if [ "$HAS_DOCKER" -eq 0 ]; then
      echo '[plugins."io.containerd.grpc.v1.cri".registry.mirrors."docker.io"]'
      printf '  endpoint = ['
      for i in "${!DOCKER_MIRRORS[@]}"; do [ "$i" -gt 0 ] && printf ', '; printf '"%s"' "${DOCKER_MIRRORS[$i]}"; done
      echo ']'
    fi
    if [ "$HAS_GHCR" -eq 0 ]; then
      echo '[plugins."io.containerd.grpc.v1.cri".registry.mirrors."ghcr.io"]'
      printf '  endpoint = ['
      for i in "${!GHCR_MIRRORS[@]}"; do [ "$i" -gt 0 ] && printf ', '; printf '"%s"' "${GHCR_MIRRORS[$i]}"; done
      echo ']'
    fi
  } >> "$CFG"
  ok "镜像加速已添加（docker.io=${HAS_DOCKER} ghcr.io=${HAS_GHCR}，0 表示新增）"
fi

# TOML 语法自检：配置写坏会导致 containerd 起不来
if ! containerd config dump >/dev/null 2>&1; then
  err "containerd 配置语法无效，请检查 ${CFG}"
fi

# ---------------------------------------------------------- 4 启动 containerd
step "4/6 containerd 启动"
systemctl enable containerd >/dev/null 2>&1
systemctl restart containerd
sleep 3
if systemctl is-active --quiet containerd; then
  ok "运行中（$(systemctl show -p ActiveEnterTimestamp --value containerd | cut -d' ' -f2-3)）"
else
  err "启动失败"
  journalctl -u containerd -n 15 --no-pager | sed 's/^/      /'
fi

# ---------------------------------------------------------- 5 K8s 软件源
step "5/6 Kubernetes 软件源"
if [ -f /etc/yum.repos.d/kubernetes.repo ] && grep -q "$K8S_REPO" /etc/yum.repos.d/kubernetes.repo; then
  ok "已配置"
else
  cat > /etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=${K8S_REPO}
enabled=1
gpgcheck=0
EOF
  ok "已写入阿里云源"
fi

# ---------------------------------------------------------- 6 K8s 组件
step "6/6 kubelet / kubeadm / kubectl"
# 注意：kubernetes-cni 提供 /opt/cni/bin 下的标准插件（loopback / bridge / host-local 等）。
# 缺失会导致 CoreDNS 等 Pod 永久卡在 ContainerCreating，报错：
#   failed to find plugin "loopback" in path [/opt/cni/bin]
NEED=()
for p in kubelet kubeadm kubectl kubernetes-cni; do
  rpm -q "$p" >/dev/null 2>&1 || NEED+=("$p")
done
if [ "${#NEED[@]}" -eq 0 ]; then
  ok "全部已安装（kubeadm $(rpm -q --qf '%{VERSION}' kubeadm)）"
else
  warn "缺少：${NEED[*]}"
  if dnf install -y -q "${NEED[@]}" >/dev/null 2>&1; then
    ok "安装完成"
  else
    err "安装失败：${NEED[*]}"
  fi
fi
systemctl enable kubelet >/dev/null 2>&1 && ok "kubelet 已设为开机启动"

if [ -x /opt/cni/bin/loopback ]; then
  ok "/opt/cni/bin 标准插件就绪"
else
  err "/opt/cni/bin/loopback 缺失，Pod 网络会失败"
fi

# ---------------------------------------------------------- 验证
step "验证"
command -v containerd >/dev/null && ok "containerd 二进制存在"
command -v kubeadm    >/dev/null && ok "kubeadm 二进制存在"
command -v kubectl    >/dev/null && ok "kubectl 二进制存在"
command -v kubelet    >/dev/null && ok "kubelet 二进制存在"
command -v crictl     >/dev/null && ok "crictl 二进制存在"
if command -v crictl >/dev/null 2>&1; then
  if crictl --runtime-endpoint unix:///run/containerd/containerd.sock version >/dev/null 2>&1; then
    ok "crictl 可连通 containerd"
  else
    warn "crictl 连接 containerd 失败（可稍后重试）"
  fi
fi

printf '\n%s────────────────────────────────────%s\n' "$C_B" "$C_0"
printf '%s完成：%s\n' "$C_B" "$(hostname)"
printf '  通过 %s%d%s   提示 %s%d%s   失败 %s%d%s\n' "$C_G" "$PASS" "$C_0" "$C_Y" "$WARN" "$C_0" "$C_R" "$FAIL" "$C_0"
printf '%s────────────────────────────────────%s\n' "$C_B" "$C_0"
[ "$FAIL" -gt 0 ] && { printf '%s存在失败项%s\n' "$C_R" "$C_0"; exit 1; }
printf '%s节点运行时就绪%s\n' "$C_G" "$C_0"