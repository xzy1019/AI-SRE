#!/usr/bin/env bash
# ============================================================================
# 01-baseline.sh —— 集群基础环境配置（幂等，可重复执行）
#
# 用法： 在每台节点上执行  bash 01-baseline.sh
#
# 覆盖范围（系统层）：
#   主机名 / /etc/hosts / DNS / 时间同步 / SELinux / firewalld
#   swap / THP / 内核模块 / sysctl / 基础软件包
#
# 不包含（下一层脚本）：
#   containerd、kubelet/kubeadm/kubectl、集群初始化
# ============================================================================
set -uo pipefail

# ---------------------------------------------------------------- 节点清单
NODES=(
  "172.29.20.21 k8s-cp   control-plane"
  "172.29.20.22 k8s-obs  observability"
  "172.29.20.23 k8s-app1 workload"
  "172.29.20.24 k8s-app2 workload"
  "172.29.20.25 k8s-ai   aiops"
)
DNS_SERVERS=("223.5.5.5" "114.114.114.114")
NTP_SERVERS=("ntp.aliyun.com" "ntp1.aliyun.com" "ntp2.aliyun.com")
BASE_PKGS=(git curl wget tar jq bash-completion vim-enhanced)

# ---------------------------------------------------------------- 输出封装
C_R=$'\033[0;31m'; C_G=$'\033[0;32m'; C_Y=$'\033[0;33m'; C_B=$'\033[0;36m'; C_0=$'\033[0m'
PASS=0; WARN=0; FAIL=0
step() { printf '\n%s== %s ==%s\n' "$C_B" "$*" "$C_0"; }
ok()   { printf '  %s✔%s %s\n' "$C_G" "$C_0" "$*"; PASS=$((PASS+1)); }
warn() { printf '  %s!%s %s\n' "$C_Y" "$C_0" "$*"; WARN=$((WARN+1)); }
err()  { printf '  %s✘%s %s\n' "$C_R" "$C_0" "$*"; FAIL=$((FAIL+1)); }

# ---------------------------------------------------------------- 前置检查
[ "$(id -u)" -eq 0 ] || { echo "必须以 root 执行"; exit 1; }

my_ip() { ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1; }
MY_IP="$(my_ip)"
MY_HOST=""; MY_ROLE=""
for e in "${NODES[@]}"; do
  set -- $e
  if [ "$1" = "$MY_IP" ]; then MY_HOST="$2"; MY_ROLE="$3"; fi
done
if [ -z "$MY_HOST" ]; then
  err "本机 IP ${MY_IP} 不在节点清单中，请先确认网卡地址"
  exit 1
fi
printf '%s节点: %s (%s)   角色: %s%s\n' "$C_B" "$MY_HOST" "$MY_IP" "$MY_ROLE" "$C_0"

# ---------------------------------------------------------------- 1 主机名
step "1/11 主机名"
if [ "$(hostname)" = "$MY_HOST" ]; then
  ok "已是 ${MY_HOST}"
else
  hostnamectl set-hostname "$MY_HOST" && ok "设置为 ${MY_HOST}" || err "设置失败"
fi

# ---------------------------------------------------------------- 2 hosts
step "2/11 /etc/hosts 解析"
hosts_changed=0
for e in "${NODES[@]}"; do
  set -- $e
  if ! grep -qE "^$1[[:space:]]+$2([[:space:]]|$)" /etc/hosts; then
    echo "$1 $2" >> /etc/hosts
    hosts_changed=1
  fi
done
[ "$hosts_changed" -eq 1 ] && ok "已补全节点解析" || ok "节点解析已完整"

# ---------------------------------------------------------------- 3 DNS
step "3/11 DNS 解析"
if getent hosts "${NTP_SERVERS[0]}" >/dev/null 2>&1; then
  ok "解析正常（$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf)）"
else
  warn "解析失败，切换到公共 DNS"
  { for s in "${DNS_SERVERS[@]}"; do echo "nameserver $s"; done; } > /etc/resolv.conf
  CONN="$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | awk -F: '$2!="lo"{print $1; exit}')"
  if [ -n "${CONN:-}" ]; then
    nmcli con mod "$CONN" ipv4.ignore-auto-dns yes ipv4.dns "${DNS_SERVERS[*]}" >/dev/null 2>&1 \
      && ok "已切换并通过 NetworkManager 持久化" || warn "已切换，但持久化失败"
  else
    warn "已切换，但未找到 NM 连接（重启后可能失效）"
  fi
fi

# ---------------------------------------------------------------- 4 时间同步
step "4/11 时间同步"
if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "yes" ]; then
  ok "已同步：$(date '+%F %T %Z')"
else
  warn "未同步（当前 $(date '+%F %T')），正在修复"
  for n in "${NTP_SERVERS[@]}"; do
    grep -q "server ${n}" /etc/chrony.conf || sed -i "1i server ${n} iburst" /etc/chrony.conf
  done
  grep -q '^makestep' /etc/chrony.conf || echo 'makestep 1.0 -1' >> /etc/chrony.conf
  systemctl enable chronyd >/dev/null 2>&1
  systemctl restart chronyd
  sleep 8
  chronyc makestep >/dev/null 2>&1 || true
  sleep 3
  if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "yes" ]; then
    ok "修复成功：$(date '+%F %T %Z')"
  else
    err "仍不同步，请检查与 NTP 服务器的连通性"
  fi
fi

# ---------------------------------------------------------------- 5 SELinux
step "5/11 SELinux"
SEL_STATE="$(getenforce 2>/dev/null || echo Disabled)"
case "$SEL_STATE" in
  Enforcing)
    if [ -f /etc/selinux/config ]; then
      setenforce 0 2>/dev/null || true
      sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
      ok "Enforcing → Permissive（立即生效 + 持久化）"
    else
      err "找到 Enforcing 但 /etc/selinux/config 不存在"
    fi
    ;;
  Permissive) ok "已是 Permissive" ;;
  *)          ok "SELinux 未启用（${SEL_STATE}）" ;;
esac

# ---------------------------------------------------------------- 6 firewalld
step "6/11 firewalld"
if systemctl is-active --quiet firewalld 2>/dev/null; then
  systemctl disable --now firewalld >/dev/null 2>&1 \
    && ok "已关闭并禁用（实验环境；生产应改为按端口放行）" \
    || err "关闭失败"
else
  ok "未运行"
fi

# ---------------------------------------------------------------- 7 swap
step "7/11 swap"
if swapon --show --noheadings 2>/dev/null | grep -q .; then
  swapoff -a
  sed -i '/[[:space:]]swap[[:space:]]/ s/^\([^#]\)/#\1/' /etc/fstab
  ok "已关闭并注释 /etc/fstab（kubelet 要求）"
else
  ok "无 swap（符合要求）"
fi

# ---------------------------------------------------------------- 8 THP
step "8/11 透明大页 (THP)"
if grep -q '\[never\]' /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null; then
  ok "已关闭"
else
  echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
  if command -v grubby >/dev/null 2>&1; then
    grubby --update-kernel=ALL --args="transparent_hugepage=never" >/dev/null 2>&1 \
      && ok "已关闭，并写入内核参数（重启后仍生效）"
  else
    cat > /etc/systemd/system/disable-thp.service <<'UNIT'
[Unit]
Description=Disable Transparent Huge Pages
After=sysinit.target local-fs.target
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled'
[Install]
WantedBy=basic.target
UNIT
    systemctl daemon-reload
    systemctl enable --now disable-thp >/dev/null 2>&1 \
      && ok "已关闭，并通过 systemd 单元持久化"
  fi
fi

# ---------------------------------------------------------------- 9 内核模块
step "9/11 内核模块"
cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay 2>/dev/null || true
modprobe br_netfilter 2>/dev/null || true
if lsmod | grep -q '^overlay' && lsmod | grep -q '^br_netfilter'; then
  ok "overlay + br_netfilter 已加载"
else
  err "模块加载失败，请检查内核是否支持"
fi

# ---------------------------------------------------------------- 10 sysctl
step "10/11 sysctl"
cat > /etc/sysctl.d/k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
# /etc/sysctl.conf 在 sysctl --system 中【最后】加载，会覆盖 /etc/sysctl.d/ 的设置。
# openEuler 默认在该文件里设了 net.ipv4.ip_forward=0，必须处理，否则 K8s 无法转发流量。
if grep -qE '^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=[[:space:]]*0' /etc/sysctl.conf 2>/dev/null; then
  cp -a /etc/sysctl.conf "/etc/sysctl.conf.bak.$(date +%s)" 2>/dev/null
  sed -i -E 's|^([[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=.*)$|# \1   # commented by 01-baseline.sh: k8s requires ip_forward=1|' /etc/sysctl.conf
  warn "已注释 /etc/sysctl.conf 中的 ip_forward=0（该文件最后加载，会覆盖 sysctl.d）"
fi

sysctl --system >/dev/null 2>&1 || true
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
V1="$(cat /proc/sys/net/bridge/bridge-nf-call-iptables 2>/dev/null || echo 0)"
V2="$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)"
if [ "$V1" = "1" ] && [ "$V2" = "1" ]; then
  ok "bridge-nf-call-iptables=1, ip_forward=1"
else
  err "未生效（bridge-iptables=${V1}, ip_forward=${V2}）"
fi

# ---------------------------------------------------------------- 11 软件包
step "11/11 基础软件包"
missing=()
for p in "${BASE_PKGS[@]}"; do
  rpm -q "$p" >/dev/null 2>&1 || missing+=("$p")
done
if [ "${#missing[@]}" -eq 0 ]; then
  ok "全部已安装"
else
  warn "缺少：${missing[*]}，正在安装"
  if dnf install -y -q "${missing[@]}" >/dev/null 2>&1; then
    ok "安装完成：${missing[*]}"
  else
    err "安装失败：${missing[*]}"
  fi
fi

# ---------------------------------------------------------------- 汇总
printf '\n%s────────────────────────────────────%s\n' "$C_B" "$C_0"
printf '%s配置完成：%s\n' "$C_B" "$MY_HOST"
printf '  通过 %s%d%s   提示 %s%d%s   失败 %s%d%s\n' \
  "$C_G" "$PASS" "$C_0" "$C_Y" "$WARN" "$C_0" "$C_R" "$FAIL" "$C_0"
printf '%s────────────────────────────────────%s\n' "$C_B" "$C_0"

if [ "$FAIL" -gt 0 ]; then
  printf '%s存在失败项，请检查上方输出%s\n' "$C_R" "$C_0"
  exit 1
fi
printf '%s基础环境就绪（如修改了内核参数，建议重启一次）%s\n' "$C_G" "$C_0"