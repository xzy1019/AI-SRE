# 集群访问信息与主机清单

| 项 | 内容 |
|---|---|
| 记录日期 | 2026-10-31 |
| 集群名称 | aisre-lab |
| 节点数 | 5 |
| 操作系统 | openEuler 24.03 LTS-SP4 |
| 关联文档 | [文档索引](README.md) · [01 技术设计](01-design.md) · [03 本地大模型环境](03-local-llm.md) |

> ## ⚠️ 敏感文件警告
>
> **本文件包含明文密码。** 如果本项目要发布到 GitHub / Gitee，**必须先删除本文件的凭据章节，或把本文件加入 `.gitignore`。**
>
> 建议：发布前把「凭据」一节替换为「凭据见本地密码管理器」。

---

## 1. 凭据

> **本仓库不含任何真实凭据。** 部署前请自行准备 root 密码，通过环境变量传入。

| 项 | 值 |
|---|---|
| 协议 | SSH |
| 端口 | 22 |
| 用户名 | `root`（按你的环境调整） |
| 密码 | **不写入仓库** —— 由环境变量 `LAB_ROOT_PASSWORD` 提供 |
| 适用主机 | 172.29.20.21 / .22 / .23 / .24 / .25（示例网段，按需替换） |

```powershell
# 1) 设置环境变量（仅当前会话有效，不落盘）
$env:LAB_ROOT_PASSWORD = '<你的 root 密码>'

# 2) 登录
ssh root@172.29.20.21
```

需要密码的项目脚本（`07-distribute-images.ps1`、`37-sync-agent-logs.ps1`）
默认从 `$env:LAB_ROOT_PASSWORD` 读取，**不再内置任何默认密码**。

> **项目自建的组件口令**（这些由本项目设定，属于部署产物，照常公开）：
> | 组件 | 用户名 | 密码 |
> |---|---|---|
> | Grafana | `admin` | `aisre-lab-admin` |
> | demo-app PostgreSQL | `app` | `demo-pass` |

#### 各节点登录地址

| 节点 | 登录地址 |
|---|---|
| k8s-cp | `ssh root@172.29.20.21` |
| k8s-obs | `ssh root@172.29.20.22` |
| k8s-app1 | `ssh root@172.29.20.23` |
| k8s-app2 | `ssh root@172.29.20.24` |
| k8s-ai | `ssh root@172.29.20.25` |

> 当前**未配置 SSH 免密**（此前按你的要求删除了所有密钥）。若后续要频繁操作，可考虑重新配置密钥；否则每次登录需手动输入密码。

---

## 2. 主机清单（2026-10-31 实测）

| IP | 主机名 | 角色 | vCPU | 内存 | 磁盘 | 根分区可用 |
|---|---|---|---|---|---|---|
| 172.29.20.21 | `k8s-cp` | 控制面 | 4 | 7.3 GiB | 100 GB LVM | 90 GB |
| 172.29.20.22 | `k8s-obs` | 可观测性 | 4 | **15 GiB** | 100 GB LVM | 90 GB |
| 172.29.20.23 | `k8s-app1` | 被测业务 | 4 | 7.3 GiB | 100 GB LVM | 90 GB |
| 172.29.20.24 | `k8s-app2` | 被测业务 | 4 | 7.3 GiB | 100 GB LVM | 90 GB |
| 172.29.20.25 | `k8s-ai` | AIOps 分析 | 4 | **15 GiB** | 100 GB LVM | 90 GB |
| | | **合计** | **20** | **~52 GiB** | **500 GB** | |

### 2.1 公共配置（五台一致）

| 项 | 值 | 状态 |
|---|---|---|
| 操作系统 | openEuler 24.03 LTS-SP4 | ✅ |
| 内核 | 6.6.0-159.4.3.154.oe2403sp4.x86_64 | ✅ |
| 网卡 | `ens33` | ⚠️ 注意：不是 ens3 |
| 磁盘布局 | sda1(1M) / sda2(1G `/boot`) / sda3(99G LVM → `openeuler-root` 挂 `/`) | ✅ |
| swap | **无 swap 分区** | ✅ 符合要求 |
| 时间同步 | 已同步（chronyd） | ✅ |
| DNS | 114.114.114.114，解析正常 | ✅ |
| 主机名 | 已按规划设置 | ✅ |
| SELinux | Enforcing → **Permissive** | ✅ 已配置 |
| firewalld | active → **已关闭并禁用** | ✅ 已配置 |
| 内核模块 | overlay + br_netfilter | ✅ 已加载 |
| sysctl | bridge-nf-call-iptables=1、ip_forward=1 | ✅ 已生效 |
| 透明大页 THP | 已关闭（含内核参数持久化） | ✅ 已配置 |
| `/etc/hosts` | 五节点解析已补全 | ✅ 已配置 |
| 基础软件包 | git / tar / jq / bash-completion / vim-enhanced | ✅ 已安装 |
| 容器运行时 | 未安装 | ⬜ 待装（下一层脚本） |
| K8s 组件 | 未安装 | ⬜ 待装（下一层脚本） |
| python3 | 已安装 | ✅ |

---

## 3. 与设计规格的差异

实际环境与规划规格有三处偏差：

| 项 | 设计规格 | 实际 | 影响 | 处理 |
|---|---|---|---|---|
| **数据盘** | obs 200 GB / ai 100 GB 独立数据盘 | **均无独立数据盘**，只有 100 GB 系统盘 | 中等 | 见 3.1 |
| 系统盘 | 60 GB | 100 GB | 正向（更大） | 无需处理 |
| OS 版本 | LTS-SP2 | **LTS-SP4** | 正向（更新） | 无需处理，但需注意包版本差异 |
| 内存 | obs/ai 16 GB | 15 GiB | 基本一致 | 无需处理 |

### 3.1 关于缺失的数据盘

设计上给 `k8s-obs`（Prometheus TSDB + Loki 日志）和 `k8s-ai`（实验数据集 + pgvector）各配一块独立数据盘，理由是**时序数据写入密集，独立盘便于 I/O 隔离和后续扩容**。

**实际影响评估：**

- 根分区可用 90 GB，实验场景下 TSDB 保留 7-15 天、日志保留 7 天，**完全够用**
- 缺少 I/O 隔离：Loki 的写入峰值可能影响同节点的其他容器（在 5 节点分工下影响可控，因为 obs 节点只跑可观测性栈）
- 缺少扩容灵活性：数据增长后需扩根分区

**结论：可以先按现状进行，不阻塞。** 如果后续发现磁盘压力，再挂数据盘并迁移 `/var/lib/prometheus` 与 Loki 数据目录。

---

## 4. 配置项与完成状态

以下配置项按依赖顺序执行，全部已脚本化完成：

### 系统层配置（`scripts/01-baseline.sh`，2026-10-31）

| # | 项目 | 说明 | 状态 |
|---|---|---|---|
| 1 | SELinux | Enforcing → Permissive（立即生效 + 持久化） | ✅ |
| 2 | firewalld | 关闭并禁用 | ✅ |
| 3 | 内核模块 | `overlay`、`br_netfilter` | ✅ |
| 4 | sysctl | `bridge-nf-call-iptables`、`ip_forward` | ✅ |
| 5 | 关闭 THP | etcd / TSDB 内存分配延迟 | ✅ |
| 6 | `/etc/hosts` | 五节点名解析 | ✅ |
| 7 | 主机名 | 已确认与规划一致 | ✅ |
| 8 | DNS / 时间同步 | 验证正常（原本已 OK） | ✅ |
| 9 | 基础软件包 | git / tar / jq / bash-completion / vim-enhanced | ✅ |

**五台节点执行结果：均通过 11 项、失败 0 项。**

### 集群层配置（`scripts/02`–`05`，2026-10-31）

| # | 项目 | 说明 | 状态 |
|---|---|---|---|
| 10 | containerd | 1.6.22 + `SystemdCgroup=true` + sandbox_image + 镜像加速 | ✅ |
| 11 | K8s 组件 | kubelet / kubeadm / kubectl **v1.31.14**（阿里云源） | ✅ |
| 12 | CNI 标准插件 | `kubernetes-cni` 包，提供 `/opt/cni/bin` 下 loopback/bridge 等 | ✅ |
| 13 | `kubeadm init` | 控制面初始化 + Flannel CNI | ✅ |
| 14 | 节点加入 | k8s-obs / k8s-app1 / k8s-app2 / k8s-ai 全部 join | ✅ |
| 15 | 集群验证 | 5 节点 Ready，15 项检查全部通过 | ✅ |

**五台节点执行结果：运行时脚本均通过 20 项、失败 0 项。**

---

## 5. 备注

### 5.1 与旧环境的关系

三台旧主机（172.29.20.101 / 103 / 106，openEuler LTS-SP2）**已被本集群取代**，可释放。

### 5.2 网络接口命名差异

旧主机网卡为 `ens3`，新主机为 `ens33`。凡涉及网卡名的配置（如 Flannel 的 `--iface`、防火墙区域绑定）需使用 `ens33`。

### 5.3 基础环境配置脚本

| 项 | 内容 |
|---|---|
| 脚本 | `scripts/01-baseline.sh` |
| 覆盖范围 | 主机名 / hosts / DNS / 时间同步 / SELinux / firewalld / swap / THP / 内核模块 / sysctl / 基础软件包 |
| 特性 | **幂等**，可重复执行；每项独立报告 ✔ / ! / ✘；失败项返回非零退出码 |
| 执行方式 | 在每台节点上 `bash 01-baseline.sh` |
| 实测结果 | 五台全部 11 项通过、0 失败 |

**踩坑记录：`/etc/sysctl.conf` 会覆盖 `/etc/sysctl.d/`**

openEuler 默认在 `/etc/sysctl.conf` 中设置 `net.ipv4.ip_forward=0`。而 `sysctl --system` 的加载顺序是：

```
/etc/sysctl.d/*.conf  →  /run/sysctl.d/  →  /usr/lib/sysctl.d/  →  /etc/sysctl.conf（最后）
```

**`/etc/sysctl.conf` 最后加载，因此会覆盖前面所有设置。** 首次执行脚本时 `ip_forward` 仍为 0，K8s 无法转发流量。

脚本已处理：检测到该冲突后自动注释掉 `/etc/sysctl.conf` 中的该行（先备份为 `sysctl.conf.bak.<时间戳>`），并额外执行 `sysctl -w` 立即生效。

### 5.4 Kubernetes 集群（已建成）

**集群规格**

| 项 | 值 |
|---|---|
| Kubernetes | v1.31.14（kubeadm 部署） |
| 容器运行时 | containerd 1.6.22 |
| CNI | Flannel v0.28.10（VXLAN 后端） |
| 控制面 | k8s-cp（单节点，未做 HA） |
| worker | k8s-obs / k8s-app1 / k8s-app2 / k8s-ai |
| Pod CIDR | `10.244.0.0/16` |
| Service CIDR | `10.96.0.0/12` |
| cgroup | v1（openEuler 默认，K8s 1.31 仍支持） |

**验证结果（2026-10-31）**

```
── 集群节点 ──        5 台全部 Ready
── 系统组件 ──        kube-system / kube-flannel 无异常 Pod
── CNI ──             flannel DaemonSet = 5/5
── 控制面组件 ──      etcd / apiserver / controller-manager / scheduler 全部运行
── CNI 插件 ──        loopback / bridge / host-local / portmap / flannel 齐备
通过 15   失败 0
```

**功能验证**（临时部署 3 副本跨节点测试）

| 测试 | 结果 |
|---|---|
| 跨节点 Pod 互 ping | 2 packets transmitted, **2 packets received** |
| 集群 DNS 解析 | `kubernetes.default.svc.cluster.local` → `10.96.0.1` |
| Docker Hub 镜像加速 | `busybox:1.36` 拉取成功 |
| ghcr.io 镜像加速 | `flannel-cni-plugin` 拉取成功 |

### 5.5 脚本清单

| 脚本 | 运行位置 | 作用 | 幂等 |
|---|---|---|---|
| `01-baseline.sh` | 全部节点 | 系统层基线（主机名/SELinux/时间/内核参数等） | ✅ |
| `02-node-runtime.sh` | 全部节点 | containerd + K8s 组件 + CNI 插件 + 镜像加速 | ✅ |
| `03-init-cluster.sh` | 仅 k8s-cp | kubeadm init + Flannel + 生成 join 命令 | ✅ |
| `04-join-cluster.sh` | worker 节点 | 加入集群 | ✅ |
| `05-verify-cluster.sh` | 仅 k8s-cp | 集群就绪验证（只读） | ✅ |
| `06-preload-images.sh` | 全部节点 | 镜像预拉取（集群内，国内源+改名）—— **慢，仅作备用** | ✅ |
| `07-distribute-images.ps1` | 开发机 | **镜像分发（推荐）**：本机拉取 → 局域网传输 → `ctr` 导入 | ✅ |
| `08-verify-images.sh` | 全部节点 | 镜像清单核对（只读） | ✅ |
| `09-deploy-observability.sh` | 仅 k8s-cp | 部署可观测性栈（7 个组件，幂等） | ✅ |

`manifests/kube-flannel.yml` 为本地化的 CNI 清单（集群侧访问不了 GitHub，故在开发机下载后随脚本一起分发）。

节点上的部署路径：`/opt/aisre/{scripts,manifests}`

### 5.6 搭建过程中的三个关键坑（都已解决）

#### 坑一：containerd 包自带的是"占位"配置

openEuler 的 `containerd` RPM 会预置一个 `/etc/containerd/config.toml`，**只有 17 行且全是注释**，不含 CRI 插件段。

因此不能用"文件是否存在"判断配置是否就绪——必须判断内容：

```bash
# 错误做法
[ ! -f /etc/containerd/config.toml ] && containerd config default > /etc/containerd/config.toml

# 正确做法：检查真正需要的配置项
grep -q 'SystemdCgroup' "$CFG" && grep -q 'sandbox_image' "$CFG" || containerd config default > "$CFG"
```

否则 `SystemdCgroup` 和 `sandbox_image` 都找不到，kubelet 会因为 cgroup driver 不匹配而启动失败。

#### 坑二：ghcr.io 元数据可达但 blob 被连接重置

现象：Flannel Pod 一直 `ImagePullBackOff`，报错：

```
failed to request: Get "https://pkg-containers.githubusercontent.com/ghcrblobs09/blobs/sha256:..."
read tcp 172.29.20.21:47732->185.199.111.154:443: read: connection reset by peer
```

**根因**：`ghcr.io` 的 manifest API 可访问（返回 401 是正常的 token 流程），但**实际镜像层存储在 `pkg-containers.githubusercontent.com`，国内访问被重置**。所以单纯测 `curl https://ghcr.io/v2/` 返回 401 会误判为"可达"。

**解决**：为 `ghcr.io` 配置镜像加速。

```toml
[plugins."io.containerd.grpc.v1.cri".registry.mirrors."ghcr.io"]
  endpoint = ["https://ghcr.m.daocloud.io", "https://ghcr.nju.edu.cn"]
```

#### 坑三：缺少标准 CNI 插件导致 CoreDNS 永久 ContainerCreating

现象：节点 Ready、Flannel 5/5 正常，但 CoreDNS 卡在 `ContainerCreating`：

```
FailedCreatePodSandBox: plugin type="loopback" failed (add):
failed to find plugin "loopback" in path [/opt/cni/bin]
```

**根因**：Flannel 的 DaemonSet 只往 `/opt/cni/bin` 装 `flannel` 一个二进制，**标准插件（loopback/bridge/host-local/portmap）需要 `kubernetes-cni` 包提供**。kubeadm 不会自动安装它。

**解决**：安装 `kubernetes-cni`（来自 Kubernetes 软件源）：

```bash
dnf install -y kubernetes-cni
```

装完后 `/opt/cni/bin` 会有 20 个标准插件。注意**必须所有节点都装**——CoreDNS 可能被调度到任意节点，只装控制面不够（本次就踩了这个：装好控制面后 CoreDNS 被调度到 k8s-obs，仍然失败）。

### 5.7 镜像获取方案（重要）

#### 5.7.1 网络限制现状（实测）

集群节点与开发机的网络能力**差异极大**，这是本项目最容易踩坑的地方：

| 目标 | 集群节点 | 开发机 | 说明 |
|---|---|---|---|
| `github.com` | ✘ 不可达 | ✅ 200 | 故 CNI 清单需在开发机下载后分发 |
| `raw.githubusercontent.com` | ✘ 不可达 | ✅ 200 | 同上 |
| `ghcr.io`（API） | ✅ 401 | ✅ 401 | **但镜像层不可用**，见下 |
| `pkg-containers.githubusercontent.com` | ✘ **连接重置** | ✅ 400 | ghcr.io 的实际镜像层存储 |
| `quay.io`（API） | ✅ 401 | ✅ 401 | **但镜像层不可用**，见下 |
| `cdn01.quay.io` | ✘ **TLS 握手超时** | ✅ 403 | quay.io 的实际镜像层存储（AWS S3） |
| `index.docker.io` | ✘ 不可达 | ✘ **连接被拒绝** | Docker Hub 认证端点 |
| `registry-1.docker.io` | ✘ 不可达 | ✅ 401 | Docker Hub 注册表 |
| `registry.k8s.io` | ✘ 超时 | ✅ 401 | 重定向到 Google 制品库 |
| `europe-west4-docker.pkg.dev` | ✘ | ✘ **超时** | registry.k8s.io 的实际存储 |
| `*.m.daocloud.io`（国内镜像源） | ✅ 401 | ✅ 401 | 可用，但慢 |

**两个关键结论：**

1. **「API 可达 ≠ 镜像能拉」** —— `curl https://quay.io/v2/` 返回 401 看起来正常，但真正下载镜像层时会重定向到 `cdn01.quay.io`，国内 TLS 握手超时。**只测 `/v2/` 会产生严重的误判。**
2. **开发机网络比集群宽松，但也不完整** —— 开发机可访问 GitHub 与两个关键 CDN，但 Docker Hub 认证端点和 Google 制品库仍不通。因此开发机拉取时**必须走国内镜像路径**。

#### 5.7.2 方案：开发机拉取 → 局域网分发

```
① 开发机：crane pull（走国内镜像路径）  →  导出 docker-archive tar
                    ↓
② 局域网 scp（实测约 16 MB/s）
                    ↓
③ 集群节点：ctr -n k8s.io images import
                    ↓
④ 若源名 ≠ 目标名，ctr images tag 改名回原始名
```

**为什么走这条路**：镜像 tar 保留原始镜像名，导入后 **k8s 清单可以完全使用上游原名**，后续升级镜像不需要改清单。

**实测数据**

| 环节 | 结果 |
|---|---|
| 开发机拉取 11 张镜像（合计 699.6 MB） | 约 12 分钟 |
| 局域网传输到 k8s-obs（700 MB） | 约 22 秒 |
| 传输到其余 4 台（各约 200 MB） | 每台约 5 秒 |
| `ctr` 导入 11 张 | 约 2.5 分钟 |
| **总计** | **约 15 分钟** |

对比集群内直拉方案：单张 prometheus 就要 385 秒且经常失败，chaos-daemon 在 5 台各拉一遍会更久。

#### 5.7.3 镜像清单与源映射

| 目标镜像名（清单中使用） | 开发机拉取源 |
|---|---|
| `quay.io/prometheus/node-exporter:v1.8.2` | 同左（直连可用） |
| `quay.io/prometheus/prometheus:v2.55.0` | 同左（直连可用） |
| `quay.io/prometheus/alertmanager:v0.28.1` | 同左（直连可用） |
| `registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.14.0` | `k8s.m.daocloud.io/...` |
| `docker.io/grafana/grafana:11.4.0` | `docker.m.daocloud.io/...` |
| `docker.io/grafana/loki:3.3.2` | `docker.m.daocloud.io/...` |
| `docker.io/otel/opentelemetry-collector-contrib:0.116.0` | `docker.m.daocloud.io/...` |
| `ghcr.io/chaos-mesh/chaos-mesh:v2.8.7` | `ghcr.m.daocloud.io/...` |
| `ghcr.io/chaos-mesh/chaos-daemon:v2.8.7` | `ghcr.m.daocloud.io/...` |
| `ghcr.io/chaos-mesh/chaos-dashboard:v2.8.7` | `ghcr.m.daocloud.io/...` |
| `ghcr.io/chaos-mesh/chaos-coredns:v0.2.8` | `ghcr.m.daocloud.io/...` |

**分组**：`node` 组（全部节点）= node-exporter + chaos-daemon；`full` 组（仅 k8s-obs）= 全部 11 张。

#### 5.7.4 使用方式

```powershell
# 开发机执行（完整流程：拉取 + 分发 + 导入）
cd scripts
.\07-distribute-images.ps1

# 镜像已在本地时跳过拉取
.\07-distribute-images.ps1 -SkipPull

# 只处理指定节点
.\07-distribute-images.ps1 -OnlyNode 172.29.20.22
```

```bash
# 节点上核对结果
bash scripts/08-verify-images.sh full    # k8s-obs
bash scripts/08-verify-images.sh node    # 其余节点
```

#### 5.7.5 关于「集群内直拉」备用方案

`06-preload-images.sh` 可在集群节点内部拉取（走国内源 + `ctr` 改名），实测可行但极慢：

| 镜像 | 集群内耗时 |
|---|---|
| prometheus（250 MB） | 385 秒 |
| otel-collector | 158 秒 |
| alertmanager | 44 秒 |

**仅在无法从开发机传输时使用**（例如临时补一张镜像）。

### 5.8 可观测性栈（已部署）

**部署清单**（命名空间 `observability`，工具类组件落在 `k8s-obs`）

| 组件 | 类型 | 状态 | 说明 |
|---|---|---|---|
| Prometheus | Deployment + NodePort 30090 | ✅ 1/1 | 指标采集，保留 7 天 / 8 GB 上限 |
| Alertmanager | Deployment + NodePort 30093 | ✅ 1/1 | 告警分组去重，webhook 出口指向自研 AIOps（待建） |
| Grafana | Deployment + NodePort 30030 | ✅ 1/1 | 已预配 Prometheus / Loki 数据源 |
| Loki | Deployment + ClusterIP 3100 | ✅ 1/1 | 日志存储，单机 filesystem 模式，保留 7 天 |
| Promtail | DaemonSet | ✅ | 日志采集，CRI 解析 + level 标签提取 |
| node-exporter | DaemonSet | ✅ 5/5 | 五节点全覆盖 |
| kube-state-metrics | Deployment | ✅ 1/1 | K8s 对象指标 |

**告警规则**：已内置 8 条（PodCrashLooping / PodNotReady / PodRestartingFrequently / DeploymentReplicasMismatch / NodeMemoryHigh / NodeFilesystemHigh / NodeCPUHigh / KubeletDown）

**访问方式**（NodePort，任意节点 IP）

```
Grafana       http://<节点IP>:30030     admin / aisre-lab-admin
Prometheus    http://<节点IP>:30090
Alertmanager  http://<节点IP>:30093
```

**端到端验证结果**

| 验证项 | 结果 |
|---|---|
| 指标采集 | ✅ Prometheus 抓取 node-exporter / kube-state-metrics / kubelet / apiserver |
| 日志采集 | ✅ 测试 Pod 日志经 Promtail → Loki，查询返回 2 流 / 10 行，`level` 标签正确提取 |
| Grafana 数据源 | ✅ Prometheus / Loki 自动注入 |
| Pod 重启次数 | ✅ 全部为 0 |

#### 5.8.1 部署过程中的四个坑

**坑一：OTel Collector 镜像在本环境无法运行**（未解决，已绕过）

`otel/opentelemetry-collector-contrib:0.116.0` 镜像本身完全正常（二进制存在、ELF 正确、宿主机可直接执行），但**用它起的容器无法 exec 任何文件**——连 bind-mount 进去的静态 busybox 都报 `no such file or directory`。

排查已排除：镜像损坏、tar 格式、快照链缺失、磁盘空间、`ArgsEscaped` 标志（prometheus/loki 同样为 True 却正常）、安全上下文。

对比：**同一台节点上，promtail / loki / grafana / prometheus 全部正常**。

**处理**：改用 Promtail 做日志采集，功能等价且更简单。

**坑二：Grafana 的 pod 级 `runAsNonRoot` 与 init 容器冲突**

```
Error: container's runAsUser breaks non-root policy (container: fix-perms)
```

原因：pod 级 `securityContext` 设了 `runAsNonRoot: true` + `runAsUser: 472`，而 init 容器需要 `runAsUser: 0` 来修目录权限。

**处理**：pod 级只保留 `fsGroup`，`runAsNonRoot` / `runAsUser` 下放到容器级。

**坑三：kube-state-metrics 的 `/readyz` 不在主端口**

KSM v2.14 的 `/healthz` 在 **8080**，但 `/readyz` 在**遥测端口 8081**。探针写错端口会一直 `0/1`。

验证方法：

```
curl http://<pod-ip>:8080/readyz   → 404
curl http://<pod-ip>:8081/readyz   → 200
```

**坑四：Promtail 读不到容器日志（权限 + 路径，两处都会错）**

**权限**：容器日志文件是 `-rw-r----- root:root`（0640），Promtail 默认以 `65534` 运行读不了。

```
uid=65534,gid=65534 → Permission denied
uid=65534,gid=0     → 正常读取
```

**处理**：pod 级加 `supplementalGroups: [0]`，容器级 `runAsGroup: 0`。

**路径**：日志实际路径是 `/var/log/pods/<ns>_<pod>_<uid>/<container>/<n>.log`，**中间有容器名这一层目录**。

```
错误：/var/log/pods/*$1/*.log      → 匹配不到
正确：/var/log/pods/*$1/*/*.log    → 匹配
```

这个错误不会报错，只会在 debug 日志里出现 `no files matched requested path`，表现为 Pod 一直 `0/1` 但没有任何错误信息。

**另注意**：Promtail 的 `/ready` 在"无可采集目标"时返回 500。**不能拿它做 liveness 探针**，否则没有业务负载的节点上 Pod 会被反复重启。liveness 应用 `tcpSocket`。

### 5.9 Chaos Mesh（已部署）

**部署概要**：Chaos Mesh v2.8.7，命名空间 `chaos-mesh`，23 个 CRD。

| 组件 | 类型 | 状态 |
|---|---|---|
| chaos-controller-manager | Deployment × 1 | ✅ 1/1 |
| chaos-daemon | DaemonSet × **5** | ✅ 5/5（含控制面） |
| chaos-dashboard | Deployment × 1 | ✅ 1/1 |
| chaos-dns-server | Deployment × 1 | ✅ 1/1 |
| CRD | — | ✅ 23/23 |

#### 5.9.1 部署前对上游清单做的三处必要修改

Helm 渲染出的原始清单**在本环境无法正常工作**，部署前做了三处修改：

**修改一：运行时从 docker 改为 containerd（关键）**

原始清单：

```yaml
- --runtime
- docker
- --runtime-socket-path
- /host-run/docker.sock
```

**但本集群用的是 containerd，宿主机没有 `docker.sock`。** 不改会导致**所有容器级混沌（Pod kill / container kill 等）静默失败**。

改为：

```yaml
- --runtime
- containerd
- --runtime-socket-path
- /host-run/containerd/containerd.sock
```

（`/var/run` 在本系统是指向 `/run` 的符号链接，hostPath 挂载后会解析到 `/run`，故容器内路径为 `/host-run/containerd/containerd.sock`）

**修改二：chaos-daemon 增加 tolerations**

控制面节点有污点 `node-role.kubernetes.io/control-plane:NoSchedule`，而上游清单的 DaemonSet **没有任何 tolerations**，会导致 **chaos-daemon 不部署到 k8s-cp**，节点级混沌实验无法对控制面生效。

```yaml
      tolerations:
        - operator: Exists
```

**修改三：controller-manager 副本数 3 → 1**

上游默认 3 副本（为 leader election 冗余），本实验集群资源有限，降为 1。

#### 5.9.2 部署过程中的一个坑：CRD 超过 annotation 上限

直接 `kubectl apply -f chaos-mesh.yaml` 时有 **3 个 CRD 失败**：

```
Error from server (Invalid): CustomResourceDefinition.apiextensions.k8s.io
"schedules.chaos-mesh.org" is invalid:
metadata.annotations: Too long: must have at most 262144 bytes
```

**原因**：`kubectl apply`（客户端模式）会把整个对象存进 `last-applied-configuration` annotation，而这 3 个 CRD 的 schema 超过 262144 字节上限。

**处理**：改用服务端应用，它不会写这个 annotation。

```bash
kubectl apply --server-side=true --force-conflicts -f /tmp/crds.yaml
```

> 这是一个通用坑：**任何大型 CRD（如 Prometheus Operator、Istio、ArgoCD）用 `kubectl apply` 都可能遇到。**

#### 5.9.3 功能验证结果（真实注入）

**验证一：Pod 混沌（pod-kill）**

```
注入前 Pod UID: bnwzv / dzdhz / jv5kf
                 ↓ 注入 pod-kill (mode=one)
注入后 Pod UID: bnwzv / jv5kf / mv4pq ← 新 UID + 新时间戳
Chaos 状态:     Selected=True  AllInjected=True
```

被选中的 Pod 确实被终止，Deployment 重建了新副本。**这证明 chaos-daemon 能通过 containerd 操作容器。**

**验证二：网络混沌（NetworkChaos delay）**

```yaml
action: delay
delay: { latency: '500ms', correlation: '100', jitter: '0ms' }
```

```
Chaos 状态: Selected=True  AllInjected=True
```

**这证明 chaos-daemon 能通过 `tc`（Linux 流量控制）操作节点网络栈。**

两个验证覆盖了 Chaos Mesh 的两条核心技术路径（容器运行时 API + 内核网络栈），可以认为部署完整可用。

### 5.11 被测业务 demo-app（已部署）

> 本节 5 个坑的逐条复盘（现象 / 根因 / 定位证据 / 自查命令）见 [06 沉默故障复盘](06-pitfalls.md)。

**部署日期**：2026-11-01 ｜ **脚本**：`scripts/11-deploy-demo-app.sh` ｜ **清单**：`manifests/demo-app/`

| 组件 | 类型 | 副本 | 节点 | 说明 |
|---|---|---|---|---|
| frontend | Deployment | 2 | k8s-app1 | 入口，调用 order |
| order | Deployment | 2 | k8s-app1 | 调用 payment |
| payment | Deployment | 2 | **k8s-app2** | 探测 postgres / redis |
| postgres | StatefulSet | 1 | k8s-app2 | 数据目录 hostPath 持久化 |
| redis | Deployment | 1 | k8s-app2 | maxmemory 128mb / lru |
| loadgen | Deployment | 1 | k8s-app1 | 每 0.4s 打一次 frontend，制造稳定负载 |

调用链：`loadgen → frontend → order → payment → (postgres + redis)`。
**frontend/order 在 app1、payment 在 app2 是刻意跨节点** —— 后续网络类混沌（delay / partition）才有意义。

服务不依赖私有镜像仓库：应用代码放在 ConfigMap `demo-app-code` 里挂载，镜像用 `python:3.12-alpine`，
`command: ["python3","/opt/app/app.py"]`。好处是改代码只要改 ConfigMap + 改 `checksum/code` 注解触发滚动更新。

每个服务暴露三个端点：`/`（业务）、`/metrics`（Prometheus 文本格式）、`/healthz`（探针）。

#### 5.11.1 坑一：ResourceQuota 没给滚动更新留余量 → 部署卡住不收敛

把 `limits.cpu` 配额设成 6（正好等于 6 个应用容器 limits 之和）后，滚动更新（`maxSurge=1 / maxUnavailable=0`）失败：

```
Warning FailedCreate: pods "frontend-5b7c8bf879-grp2h" is forbidden:
  exceeded quota: demo-app-quota,
  requested: limits.cpu=800m, used: limits.cpu=5300m, limited: limits.cpu=6
```

表现为 Deployment 停在 1/2、RS `desired=2 current=1`、`kubectl rollout status` 一直等到超时。

**根因**：滚动更新期间新旧 Pod 会**同时存在**，配额必须留出这一份 surge 的空间。
**处理**：配额上调为 `requests.cpu=4 / limits.cpu=12 / limits.memory=12Gi`，并在清单里写明为什么留余量。

#### 5.11.2 坑二：liveness 探针默认 1s 超时 + 应用 accept 队列太小 → 容器被反复杀掉

现象（exit code 137，事件里明确是探针判死）：

```
Warning Unhealthy: Liveness probe failed:
  Get "http://10.244.2.23:8080/healthz": context deadline exceeded
  (Client.Timeout exceeded while awaiting headers)
```

- `httpGet` 探针默认 `timeoutSeconds: 1`
- 业务请求 + Prometheus 抓取 + 探针并发时，`socketserver` 默认的 `request_queue_size = 5`（accept backlog）会溢出，
  新连接被丢弃/排队，探针读不到响应头 → 判定失败 → kubelet SIGKILL 容器

**处理**（两侧一起改，缺一不可）：

| 侧 | 改动 |
|---|---|
| 应用 | `ThreadingHTTPServer.request_queue_size = 128` |
| 清单 | `timeoutSeconds: 3`、liveness `failureThreshold: 5`、`initialDelaySeconds: 20` |
| 资源 | `requests.cpu 100m`、`limits.cpu 800m`（原 400m 在突发时会被 CFS 限流） |

改完连续观察未再出现探针判死；`restarts` 保持 0。

#### 5.11.3 坑三（最隐蔽）：告警规则一条都没加载 —— `rule_files` 路径与挂载点不一致

Prometheus 配置里写的是：

```yaml
rule_files:
  - /etc/prometheus/rules/*.yml      # ← 期望有 rules/ 子目录
```

但 ConfigMap 是**平铺挂载**的，容器里实际是 `/etc/prometheus/rules.yml`（无 `rules/` 目录）：

```
$ ls -l /etc/prometheus
prometheus.yml -> ..data/prometheus.yml
rules.yml      -> ..data/rules.yml
$ ls -l /etc/prometheus/rules
ls: /etc/prometheus/rules: No such file or directory
```

后果：**8 条 Pod/Node 级告警规则从来没有生效过**，Alertmanager 长期 0 告警，
而 `kubectl get pods` 一切正常，表面上完全看不出来。是这次做「注入 → 告警」闭环时才暴露出来的。

**处理**：`rule_files: - /etc/prometheus/rules.yml`。修复后 `/api/v1/rules` 返回 13 条规则（8 基础 + 5 业务）。

> **教训**：配置项"看起来写了"不等于"真的生效"。校验必须查**运行时状态**（`/api/v1/rules`），
> 不能只看配置文件内容。Prometheus 只在**启动日志**里报规则加载失败，跑起来之后不吭声。

#### 5.11.4 坑四：YAML 块标量把下一个键"吃掉"了

同一个 ConfigMap 里 `prometheus.yml: |` 与 `rules.yml: |` 是兄弟键，缩进必须**同为 2 空格**。
把 `rules.yml` 写到 4 空格时，它落进了上一个块标量的内容里，于是：

```
err="parsing YAML file /etc/prometheus/prometheus.yml:
  yaml: unmarshal errors:
    line 90: field rules.yml not found in type config.plain
    line 91: field groups not found in type config.plain"
```

`kubectl apply` **不会**报错（YAML 本身合法），是 Prometheus 启动时才崩，Pod 进 CrashLoopBackOff。
**处理**：统一缩进；并在部署脚本里加"应用后先数 ConfigMap 的 data 键数量，键数不对就不重启"的预检。

#### 5.11.6 坑五：直方图"累积的累积" → P95 被算成 7.5s，误报永久存在

`render_metrics()` 里对**已经是累积值**的桶又累加了一遍：

```python
cum = 0
for i, b in enumerate(BUCKETS):
    cum += h[i]                      # h[i] 本身已是累积值 → 变成"累积的累积"
    out.append(f'...le="{b}"}} {cum}')
```

`observe()` 里"每个满足 `seconds <= b` 的桶各 +1"，所以 `h[i]` 已经是累积口径。
再累加一次后，`le="10.0"` 的计数会**远大于请求总数**（集群实测 `1139` vs `_count=116`），
`histogram_quantile` 据此把一个真实的 10ms P95 算成 **7.5s**，
于是 `DemoAppHighLatency` 变成"永久告警"——**先污染告警，再污染后面的 AIOps 分析**。

**正确口径**（三条硬性契约，已写成单元测试 `_verify/verify_histogram.py`）：

| 契约 | 含义 |
|---|---|
| bucket 单调不减 | 累积计数只增不减 |
| `le="+Inf"` == `_count` | 最高桶必须等于总数 |
| 最高有限桶 ≤ 总数 | 二次累积的直接破绽，一眼能查 |

**修复前后对比（同一份固定样本：95 次 3ms + 5 次 300ms）**：

| | le=10.0 | _count | 判定 |
|---|---|---|---|
| 修复前 | 1070 | 100 | ✘ FAIL |
| 修复后 | 100 | 100 | ✔ PASS |

集群侧同一口径复核：

| | frontend | order | payment |
|---|---|---|---|
| 修复前 P95 | 7.66 s | 7.65 s | 7.39 s |
| 修复后 P95 | 0.046 s | 0.025 s | 0.023 s |

修复后 `DemoAppHighLatency` 自动恢复（Alertmanager 活动告警归零）。

> **踩坑提醒**：改完埋点别急着看"值合不合理"，先查**契约**（单调性 / +Inf == count）。
> 另外，Pod 重启后旧时序仍会在 5 分钟窗口里参与聚合，**变更后要等一个完整窗口再复核**，
> 否则会把"旧数据的残留"误判成"新代码还不对"（这次就多查了一轮）。
#### 5.11.7 已验证状态

| 项目 | 结果 |
|---|---|
| Pod 就绪 | 9/9（frontend 2、order 2、payment 2、postgres 1、redis 1、loadgen 1） |
| Prometheus 抓取 | `up{job="demo-app"}==1` → **6/6** |
| 业务连通 | frontend → order `/healthz` 返回 200；平均延迟 frontend 36ms / order 25ms / payment 12ms |
| Loki 日志 | `{namespace="demo-app"}` 有 JSON 结构化日志 |
| 告警规则 | 13 条已加载（新增 5 条业务级 SLI：错误率 / P95 延迟 / 下游失败 / 抓取失败 / 依赖不可用） |

---

### 5.12 OpenTelemetry Collector（已部署）

**脚本**：`scripts/12-deploy-otel-collector.sh` ｜ **清单**：`manifests/observability/08-otel-collector.yaml`
**位置**：`observability` 命名空间，落在 k8s-ai ｜ **镜像**：`otel/opentelemetry-collector-contrib:0.113.0`

**作用**：给全集群一个统一的 OTLP 接收端（gRPC 4317 / HTTP 4318），收到的日志经 `k8sattributes`
补全 Pod/Deployment/Node 元数据后写入 Loki。aiops 侧组件只要面向 OTLP 一个协议，
将来换后端（Loki→Tempo、加采样、加脱敏）只改 Collector 一处配置。

**与 Promtail 的分工（重要，避免重复入库）**：

| 组件 | 负责 | Loki 中的 job 标签 |
|---|---|---|
| Promtail | 采集容器**文件**日志（`/var/log/pods`） | `promtail` |
| OTel Collector | 只接收应用**主动上报**的 OTLP 数据 | 由资源属性决定 |

两者**不要同时对同一份文件日志采集**，否则 Loki 里同一份日志会出现两套标签（存储翻倍、查询重复）。
所以本部署**只启用 OTLP 管道**，没有配 `filelog` receiver。

#### 5.12.1 大坑：0.116.0 镜像起不来，报"文件不存在"，实为缺少 glibc 加载器

```
libcontainer: container start initialization failed:
  exec /otelcol-contrib: no such file or directory
```

排查过程（每一步都做了，避免误判）：

| 步骤 | 结果 |
|---|---|
| 镜像是否存在 | ✅ 标签与 digest 都在 |
| 层 blob 是否完整 | ✅ `ctr content get <layer> \| tar -tzf -` 能列出，大小与 manifest 声明一致（79.8 MB） |
| 挂载镜像根文件系统 | ✅ `/otelcol-contrib` 存在，308 MB，`-rwxr-xr-x` |
| `file` 看二进制类型 | ❌ `dynamically linked, interpreter /lib64/ld-linux-x86-64.so.2` |
| 镜像里有没有加载器 | ❌ 根文件系统只有 `/etc/ssl/certs`、`/etc/otelcol-contrib`、`/otelcol-contrib` |

**根因**：该镜像是"精简手工构建"版，二进制是**动态链接**的，但镜像里没有 glibc 加载器。
内核 `execve` 找不到解释器时返回的**就是 ENOENT**，于是报"文件不存在"——
极易误判成"镜像拉取不完整"而反复重拉（这次确实白折腾了几轮）。

**处理**：改用 **0.113.0**（其二进制为静态链接，实测可执行）：

```bash
ctr -n k8s.io run --rm docker.io/otel/opentelemetry-collector-contrib:0.113.0 probe /otelcol-contrib --version
# otelcol-contrib version 0.113.0
```

> **方法论**：判断"镜像能不能用"，不要看文件在不在（`ls`），要**真的执行一次**（`ctr run ... --version`）。
> 容器内没有 shell 也能验证：直接 `ctr run <img> <id> <binary> <args>`。

#### 5.12.2 探针写法：镜像里没有 shell

镜像为 distroless 风格，**没有 sh / wget / curl**，所以在它自己容器里做健康检查必然失败：

```
OCI runtime exec failed: exec: "sh": executable file not found in $PATH
```

**处理**：健康检查改为"从外部探测 Service"——借用业务 Pod（自带 python3）连 13133 端口；
K8s 侧就绪判断用 `readinessProbe`（HTTP GET `/`，健康端点返回 `{"status":"Server available"}`）。

#### 5.12.3 端到端验证（实测）

从业务 Pod 发一条 OTLP 日志 → Collector → Loki 查回：

```
OTLP 上报状态码: 200
Loki 查询命中: {"stream":{"job":"aisre-selftest","service_name":"aisre-selftest"},
  "values":[["1793518879101716224",
  "{\"body\":\"otlp-selftest-ok\",\"severity\":\"INFO\",
    \"resources\":{\"cluster\":\"aisre-lab\",\"k8s.deployment.name\":\"frontend\",
    \"k8s.namespace.name\":\"demo-app\",\"k8s.node.name\":\"k8s-app1\",
    \"k8s.pod.name\":\"frontend-5b7c8bf879-8tsdt\",...}}"]]}
```

`k8sattributes` 补全的元数据（namespace / pod / deployment / node）都正确落到了日志里。

---

### 5.13 另外两个"沉默的误报"（已修复）

#### 5.13.1 kubelet 抓取 403 → 5 个节点全量假告警 KubeletDown

```
scrapeUrl=https://kubernetes.default.svc:443/api/v1/nodes/k8s-cp/proxy/metrics
health=down  err=server returned HTTP status 403 Forbidden
```

**根因**：`kubernetes_sd` 只用 ServiceAccount token 做**服务发现**；真正去 scrape 时 Prometheus
**不会自动带 token**，所以打到 `nodes/proxy` 接口就是 403。5 个节点 `up=0`，`KubeletDown` 全量误报。

**处理**：kubelet job 显式补上鉴权：

```yaml
- job_name: kubelet
  scheme: https
  authorization:
    credentials_file: /var/run/secrets/kubernetes.io/serviceaccount/token
```

修复后 5/5 节点 `health=up`。

#### 5.13.2 Promtail `/ready` 当就绪探针 → 空节点永远 0/1，再连带 PodNotReady 误报

Promtail 的 `/ready` 在**没有任何可采集目标**时返回 500（这是它的设计），拿它当 `readinessProbe`
会让 k8s-cp / k8s-obs / k8s-ai 三个没有业务 Pod 的节点长期 `0/1`，并连带触发 `PodNotReady` 告警。

**处理**：就绪探针改 `tcpSocket: { port: 9080 }`（进程在监听即视为健康）。
修复后 5/5 promtail 就绪，误报消失。

---

### 5.14 实验数据采集脚本的两个坑（`experiments/run-experiment.sh`）

第一次跑实验，数据文件"看起来有内容"其实是坏的：

**坑一：Prometheus 纯标量查询返回 `resultType=scalar`**

`sum(...)`、`count(...)` 这类纯标量表达式返回的 `data.result` 是 `[<时间戳>, "<值>"]`，
不是 vector 的 `[[{value:[ts,val]}]]`。只按 vector 解析会抛
`TypeError: 'float' object is not subscriptable`，于是所有采样静默变成 `null`。
**处理**：`q()` 按 `resultType` 分别取值。

**坑二：JSONL 必须一行一条**

采样输出用了多行美化 JSON，逐行 `json.loads` 直接报
`Expecting property name enclosed in double quotes`，后续分析脚本全崩。
**处理**：写盘前压成单行（`separators=(',',':')`）。

> 这两个坑的共同点：**"文件生成了"不等于"数据可用"**。所以数据采集脚本必须自带校验——
> 重跑后用 `json.loads` 逐行验证 + 打印 summary 才算通过（见 §5.15）。

---

### 5.15 混沌实验闭环验证（2026-11-01）

按"注入 → 指标/日志/告警"闭环跑了两组实验，产物在 `/var/lib/aisre/experiments/<实验>-<时间戳>/`
（`meta.json` 含 ground truth、`baseline.json`、`samples.jsonl`、`summary.json`、`final.json`）。

| 实验 | 故障 | 目标 | 观察到的结果 |
|---|---|---|---|
| F01 | PodChaos / pod-kill（mode: all） | payment | 副本秒级重建，SLI 只抖动一下；**未触发持续告警**（瞬时自愈，这本身是降噪场景的素材） |
| F02 | PodChaos / pod-failure（90s，mode: all） | payment | 持续不可用越过 `for` 阈值 → **`DemoAppDownstreamFailure` 在 07:50:08 触发**，order→payment 调用失败链路被正确识别 |

结论：**「注入 → 指标 → 规则 → Alertmanager」这条链路已经打通**。
Alertmanager 的 receiver 目前指向 `http://aisre-ingest.observability.svc:8080/webhook/alertmanager`，
该服务（第 2 周的 Ingestion 组件）**尚未实现**，所以告警"能产生、还没有消费方"——这是下一步的主线。

---
### 5.16 aisre-ingest（AIOps 接入层，已部署）

**部署日期**：2026-11-01 ｜ **脚本**：`scripts/14-deploy-ingestion.sh` ｜ **清单**：`manifests/aiops/` ｜ **代码**：`services/ingest/main.go`（Go，仅标准库）

**它解决了什么**：在此之前 Alertmanager 的 receiver 一直指向一个**不存在的服务**，日志里反复出现：

```
err="aisre-webhook/webhook[0]: notify retry canceled after 10 attempts: Post \"...\""
```

也就是"告警能产生、能接收，但**发不出去**"——AIOps 分析层永远拿不到数据。这是整条链路唯一的硬阻塞。

**链路位置**：

```
Prometheus(规则) → Alertmanager(receiver) → 【aisre-ingest】 → Event → JSONL(/var/lib/aisre/aiops/ingest/events.jsonl)
```

| 端点 | 作用 |
|---|---|
| `POST /webhook/alertmanager` | 接收 Alertmanager Webhook v4 |
| `GET /stats` | 收到的告警数 / 去重数 / 落盘数 / 最后接收时间 |
| `GET /events?limit=N` | 最近 N 条 Event（内存环形缓冲，便于人工核对） |
| `GET /metrics` | 自观测指标（供 Prometheus 抓取） |
| `GET /healthz` `/readyz` | 存活 / 就绪（就绪 = 输出目录可写） |

**统一事件模型**（对齐设计文档 §5.2）：`event_id / source / status(firing|resolved) / alertname / severity /
service / namespace / pod / downstream / starts_at / ends_at / received_at / fingerprint / dedup_key /
dedup_count / duplicate / ground_truth / labels / annotations`。

其中 **`service` + `downstream` 是 RCA 的拓扑输入**：实测收到的事件里带着
`service=order downstream=payment`、`service=frontend downstream=order`——正好是 demo-app 的调用链。

#### 5.16.1 部署方式：源码挂载 + 容器内编译（因为拉不到镜像、也没有 Docker）

开发机没有 Docker，集群又拉不动公共 registry，所以**不构建镜像**：

```
golang:1.23-alpine（提供工具链）
   └── ConfigMap 挂载源码到 /src
         └── 启动命令: go build -o /tmp/aisre-ingest . && exec /tmp/aisre-ingest
```

- 源码**只用 Go 标准库**，因此 `GOPROXY=off` 也能编译成功（不需要任何依赖下载）
- 改代码只需改 ConfigMap + 更新 `checksum/src` 注解触发滚动更新，零构建链路
- 代价：冷启动多花约 10s 编译；`readinessProbe.initialDelaySeconds=25` 覆盖这段
- 镜像获取（实测 48s / 74.5 MB，国内镜像站可用）：

```bash
ctr -n k8s.io images pull --platform linux/amd64 docker.m.daocloud.io/library/golang:1.23-alpine
ctr -n k8s.io images tag docker.m.daocloud.io/library/golang:1.23-alpine docker.io/library/golang:1.23-alpine
```

#### 5.16.2 端到端验证（实测）

注入 F02（payment 全副本不可用 90s）后的完整证据：

| 环节 | 实测结果 |
|---|---|
| Alertmanager → Ingest 投递 | `Notify success`（日志）；`sum(increase(alertmanager_notifications_total{integration="webhook"}[15m]))` = **7**，失败 **= 0** |
| Ingest 收到 | `alerts_received_total` = **9**，`events_written_total` = **9** |
| 事件内容 | `DemoAppScrapeDown(payment) firing/resolved`、`DemoAppHighErrorRate(frontend/order) firing`、`DemoAppDownstreamFailure(order→payment、frontend→order) firing` |
| 事件文件 | `k8s-ai:/var/lib/aisre/aiops/ingest/events.jsonl`，逐行合法 JSON |

#### 5.16.3 顺带修掉的观测盲区：可观测性栈没有监控自己

之前 Prometheus 的抓取目标只有 `prometheus / node-exporter / kube-state-metrics / kubelet /
kube-apiserver / demo-app` ——**没抓 Alertmanager**，于是"通知到底发出去没有"只能翻日志
（`alertmanager_notifications_failed_total` 根本查不到）。本次补齐 4 个 job：

| job | target | 实测 |
|---|---|---|
| `alertmanager` | `alertmanager.observability.svc:9093` | health=up |
| `loki` | `loki.observability.svc:3100` | health=up |
| `grafana` | `grafana.observability.svc:3000` | health=up |
| `aisre-ingest` | `aisre-ingest.aiops.svc:8080` | health=up（部署后） |

并新增 3 条链路健康规则：`AlertmanagerNotifyFailing`、`IngestNotReceiving`、`IngestScrapeDown`
（规则总数 13 → **16**；端到端检查项 19 → **25**）。

> **观察口径提醒**：`alertmanager_notifications_total` 带 `integration` 标签，会打出 16 条序列
> （discord/email/slack/... 全是 0）。看"通知有没有发出去"必须 **`sum by (integration)`** 或直接过滤
> `integration="webhook"`，否则很容易被一堆 0 误导。

#### 5.16.4 新踩的坑：已存在的 PodChaos 对象 `apply` 不会重新注入

第一次重跑 F02 时执行 `kubectl apply -f f02-...yaml`，返回 `unchanged`，**结果什么都没发生**（firing 告警数 0）。
原因：Chaos Mesh 的 PodChaos 对象**在 duration 到期后只是把故障恢复，对象本身保留**，
`status.conditions` 变成 `AllInjected=False / AllRecovered=True`；此时对同一对象再次 `apply`，
spec 没有变化，控制器不会重新注入。

**正确姿势**：

```bash
kubectl -n chaos-mesh delete podchaos --all          # 先删对象
kubectl apply -f /opt/aisre/experiments/f02-....yaml # 再注入，才是"新的一次实验"
```

**判断"现在到底有没有在注入"的唯一正确依据是 status，不是对象存在与否**：

```bash
kubectl -n chaos-mesh get podchaos -o jsonpath='{.items[*].status.conditions}'
#   AllInjected=True  → 正在注入
#   AllRecovered=True → 已恢复（对象只是记录）
```

---


### 5.17 aisre-agent（自愈执行层，已部署并实测）

**部署日期**：2026-11-02 ｜ **脚本**：`scripts/24-deploy-agent.sh` ｜ **清单**：`manifests/aiops/02-agent.yaml` ｜ **源码**：`services/agent/main.go`（Go，仅标准库）

**它在链路最后一段**：Incident（降噪后的根因）+ 建议动作 → **策略引擎** → **执行器** → **审计哈希链**。

**为什么"敢执行"比"能分析"难**：SRE 场景里错误的自动修复比不修复更贵（把故障藏起来、扩大影响面、难以复盘）。
所以这个服务的核心不是"能改 K8s"，而是**改之前 8 道校验、改之后不可篡改的审计**。三层防护：

| 层 | 机制 |
|---|---|
| RBAC 最小授权 | ServiceAccount 只拿到 `demo-app` 命名空间的 `deployments get/list/patch`，不能读 Secret、不能碰 kube-system/observability/chaos-mesh |
| 策略引擎（8 条） | P1 动作分级 L0–L3（L2/L3 需 approved）· P2 目标白名单 · P3 冷却期 10min · P4 爆炸半径（禁止 scale 到 0）· P5 频率限制 5/min · P6 幂等（同 incident 同动作一次）· P7 前置条件（目标存在且非全副本不可用）· P8 干跑语义 |
| 审计哈希链 | 每条记录 `hash = sha256(prev_hash + canonical(payload))`，`GET /audit/verify` 可校验；独立复算已验证 |

**实测（`scripts/25-agent-selftest.sh`，9/9 通过）**：

| # | 用例 | 结果 |
|---|---|---|
| ① | L1 restart dry-run | ✅ 允许且不执行 |
| ② | L1 restart 真实执行 | ✅ 已执行：`kubectl rollout restart` 效果（payment Pod 于 11:05:20 / 11:05:31 重建，maxUnavailable=0 不影响可用性） |
| ③ | L3 scale 到 0 | ✅ 拒绝（P1/P4） |
| ④ | L2 扩容未经 approved | ✅ 拒绝（P1） |
| ⑤ | 越界命名空间 kube-system | ✅ 拒绝（P2） |
| ⑥ | 冷却期内重复执行 | ✅ 拒绝（P3/P6） |
| ⑦ | 幂等：同 incident 同动作二次 | ✅ 拒绝（P6/P3） |
| ⑧ | 审计链完整性 | ✅ `chain_ok=true`，8 条记录；**独立复算链式关系也 OK** |
| ⑨ | 目标不存在 | ✅ 拒绝（P7） |

审计文件持久化：`k8s-ai:/var/lib/aisre/aiops/agent/audit.jsonl`（重启后自动恢复链）。

---



### 5.18 Grafana 定制仪表盘（3 个，随 Git 版本管理）

**部署**：`scripts/26-apply-grafana-dashboards.sh` ｜ **清单**：`manifests/observability/09-grafana-dashboards.yaml`
｜ **源 JSON**：`manifests/observability/dashboards/*.json`（可 review、可回滚）

| 仪表盘 | uid | 面板数 | 用途 |
|---|---|---|---|
| **AISRE · 总览** | `aisre-overview` | 11 | 值班第一眼：节点 Ready / 业务 Pod 就绪 / 5xx 速率 / 活动告警 / 业务 QPS / pending / 通知失败(1h) / 节点 CPU·内存 / **AIOps 链路抓取健康** |
| **AISRE · 业务 SLI（demo-app）** | `aisre-demo-sli` | 10 | 定位"哪里慢/哪里错"：QPS、5xx 错误率、P95、P50/P99(payment)、**下游调用失败速率与耗时**、Pod 重启数、就绪副本数、ERROR 日志流 |
| **AISRE · AIOps 自愈链路** | `aisre-aiops-chain` | 13 | 验证"链路通不通、有没有动作"：ingest 收到/落盘/去重、审计记录数、已执行动作、通知成功 vs 失败、组件存活、当前告警明细表、aiops 日志、链路读法说明 |

访问：`http://<节点IP>:30030`（admin / aisre-lab-admin）。

**验证**（`26` 号脚本第 3 步，实测输出）：

```
aisre-overview       ✔ 面板数=11  标题=AISRE · 总览
aisre-demo-sli       ✔ 面板数=10  标题=AISRE · 业务 SLI（demo-app）
aisre-aiops-chain    ✔ 面板数=13  标题=AISRE · AIOps 自愈链路
数据源 uid        ✔ Loki=loki, Prometheus=prometheus
数据是否通      ✔ 业务 QPS = 5.93
```

#### 5.18.1 两个坑（都实测踩过）

| 坑 | 现象 | 根因 / 修法 |
|---|---|---|
| **数据源 uid 随机** | 仪表盘能打开但所有面板显示 "No data" | 供给式数据源如果不写 `uid`，Grafana 会随机生成；而仪表盘 JSON 里按 `uid` 引用 → 对不上。**修法**：`_grafana-datasources.yml` 显式写 `uid: prometheus` / `uid: loki` |
| **`wget -U user:pass` 不是认证** | 校验脚本报 401，看起来像"仪表盘没加载"（实际早就加载好了） | busybox wget 的 `-U` 是 **User-Agent**，不是 Basic Auth。**修法**：改用 `curl -u admin:*** http://<节点IP>:30030/api/...`，或 `wget --header="Authorization: Basic <base64>"` |

#### 5.18.2 为什么仪表盘也用 ConfigMap 而不是在 UI 里点

- 仪表盘是**项目资产**：要能 code review、能回滚、能随环境重建（UI 里点的面板做不到）
- 配合 `grafana-dashboard-provider`（`updateIntervalSeconds=30`）：改 JSON → 重新 apply → 30 秒内自动生效
- 代价：供给式盘在 UI 里**不可保存**（会提示只读），要改就改 JSON

---

### 5.19 待确认 / 下一步

- 是否需要重新配置 SSH 免密（影响后续操作效率；当前每次操作都走 `SSH_ASKPASS` + 密码）
- `aisre-ingest`（Alertmanager 的 webhook 消费方）尚未实现 —— 第 2 周主线
- 实验库需要按设计文档重排：`experiments/` 目前是「一个文件一个实验」与「一个文件一组合集」混用
- `k8s-obs` / `k8s-ai` 的独立数据盘仍未挂载（见 §3.1，暂不阻塞）

---

## 变更记录

| 版本 | 日期 | 修改内容 |
|---|---|---|
| v1.0 | 2026-10-31 | 建立集群访问文档：凭据、五台主机实测清单、与设计规格的差异、待配置项 |
| v1.1 | 2026-10-31 | **完成五台节点基础环境配置**（`scripts/01-baseline.sh`）；记录 `/etc/sysctl.conf` 覆盖 sysctl.d 的踩坑 |
| v2.0 | 2026-10-31 | **Kubernetes 集群搭建完成并通过验证**（`scripts/02`–`05`）；记录 containerd 占位配置、ghcr.io blob 重置、CNI 插件缺失三个关键坑 |
| v2.1 | 2026-10-31 | 文档编号为 **02**；补充关联文档索引 |
| v2.2 | 2026-10-31 | 第 4 节标题由「待配置项清单」改为「配置项与完成状态」（所有项均已完成，原标题名不副实） |
| v2.3 | 2026-10-31 | 第 4 节措辞优化：引导语改为完成时态；两个重复的「已完成」子标题改为「系统层配置 / 集群层配置」 |
| v2.4 | 2026-11-01 | **新增 §5.7 镜像获取方案**：记录集群/开发机网络差异、两个关键 CDN 被墙、开发机拉取分发流程与实测数据 |
| v2.5 | 2026-11-01 | **可观测性栈部署完成并通过端到端验证**；记录四个坑（OTel 镜像异常、Grafana 安全上下文、KSM 探针端口、Promtail 权限与路径） |
| v2.6 | 2026-11-01 | **Chaos Mesh 部署完成并通过真实注入验证**；记录三处必要清单修改（containerd 运行时 / tolerations / 副本数）与 CRD annotation 上限问题 |
| v2.7 | 2026-11-01 | **部署被测业务 demo-app 并打通业务级监控**（`scripts/11`）；记录四个坑（配额 surge / 探针超时与 accept 队列 / `rule_files` 路径导致规则从未加载 / YAML 块标量吞键）；新增 5 条业务级 SLI 告警 |
| v2.8 | 2026-11-01 | **部署 OTel Collector 并打通 OTLP→Loki**（`scripts/12`）；记录 0.116.0 镜像因缺少 glibc 加载器而起不来的排查过程；修复 kubelet 抓取 403 与 Promtail 就绪探针两处误报；修正实验采集脚本的 scalar 解析与 JSONL 单行问题；完成 F01/F02 混沌闭环验证（`scripts/13`） |
| v2.9 | 2026-11-01 | **AIOps 接入层 aisre-ingest 部署完成，整条"故障→告警→事件"链路打通**；补 4 个自监控抓取 job 与 3 条链路健康规则；记录 PodChaos 对象 apply 不会重新注入的坑 |
| v3.0 | 2026-11-02 | **新增 §5.17 自愈执行层 aisre-agent**：8 条策略 + 审计哈希链 + 9 项自检全通过；原 §5.17 → §5.18 |
| v3.1 | 2026-11-02 | **新增 §5.18 Grafana 定制仪表盘**（3 个盘 / 34 个面板）；记录数据源 uid 与 wget 认证两个坑；原 §5.18 → §5.19 |
