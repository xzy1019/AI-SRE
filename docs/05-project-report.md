# 项目汇报

**中文** | [English](en/05-project-report.md)

| 项 | 内容 |
|---|---|
| 汇报日期 | 2026-11-01 |
| 项目 | AI SRE Agent —— 面向云原生环境的智能故障自愈与混沌验证平台 |
| 阶段 | 第 1 周「环境与数据打通」**提前完成**（原计划 11/02–11/08） |
| 阶段结论 | **故障能造、数据能收、告警能出**；分析层（降噪/RCA/自愈）尚未开工 |
| 关联文档 | [文档索引](README.md) · [01 技术设计](01-design.md) · [02 集群访问](02-cluster-access.md) · [04 项目进展](04-progress-log.md) · [06 沉默故障复盘](06-pitfalls.md) |

---

## 1. 这一阶段到底做出了什么

### 1.1 一套可以反复重建的 5 节点实验环境

```
k8s-cp(21)   k8s-obs(22)   k8s-app1(23)   k8s-app2(24)   k8s-ai(25)
 控制面       可观测性栈      业务 frontend    业务 payment     OTel Collector
 Flannel     Prometheus        order          postgres        （AIOps 组件将落在此）
 Chaos Mesh  Loki/Grafana      loadgen         redis
```

- 从零到集群：`scripts/01 → 05`，全部幂等，可重复执行
- 被墙镜像的解法：开发机 `crane pull` → 局域网 scp → 节点 `ctr import`（`scripts/07/08`）
- 全部脚本与清单同时留在仓库和节点 `/opt/aisre/`，改一处两边同步

### 1.2 自带埋点的被测业务（关键资产）

`demo-app`：`loadgen → frontend → order → payment → postgres/redis`，frontend/order 在 app1、payment 在 app2（**刻意跨节点**，让网络类混沌有意义）。
每个服务暴露 `/metrics`（Prometheus 文本格式）与 `/healthz`，日志为 JSON 结构化（Loki 可直接按字段查）。

**为什么不用现成的 Online Boutique**：那套服务多、镜像重、网络受限时拉不下来；自建这套 20 行 Python（标准库，无第三方依赖）
代码可控、可随意改埋点、可精确制造故障——**实验可控性比"像生产"更重要**。

### 1.3 端到端打通的观测链路

| 环节 | 实测证据 |
|---|---|
| 指标 | `up{job="demo-app"}==1` → 6/6；业务平均延迟 frontend 36ms / order 25ms / payment 12ms |
| 日志 | `{namespace="demo-app"}` 可查；OTLP → Collector → Loki 自检日志带全元数据 |
| 告警 | 13 条规则已加载（8 基础 + 5 业务 SLI）；`DemoAppDownstreamFailure` 在实验中被真实触发 |
| 混沌 | Chaos Mesh v2.8.7，chaos-daemon 5/5；F01/F02 注入生效并产出数据 |

### 1.4 一次完整的"注入 → 采集"闭环（可复现）

```bash
# 控制面执行
bash /opt/aisre/experiments/run-experiment.sh \
     /opt/aisre/experiments/f02-pod-failure-payment.yaml 90
```

产物在 `/var/lib/aisre/experiments/F02-...-<时间戳>/`：

| 文件 | 内容 | 实测 |
|---|---|---|
| `meta.json` | 实验编号、**ground truth**、注入/恢复时间 | `ground_truth: payment-service` |
| `baseline.json` | 注入前 30s 基线 | 5xx=0 |
| `samples.jsonl` | 每 10s 一条采样（一行一条 JSON） | 9 条，逐行可解析 |
| `summary.json` | 峰值/最终指标 | **峰值 5xx = 264**，最终 ready=9 |

**这一份带 ground truth 的数据，就是后面降噪/RCA 评测的地基。** 没有它，模型好坏无从判断。

---

## 2. 第 1 周验收标准对照

| 排期里的验收项 | 结果 | 说明 |
|---|---|---|
| 能从零拉起完整环境（脚本化） | ✅ | `scripts/01`–`13` 全部幂等，编号即执行顺序 |
| 注入故障 → 采集到数据 | ✅ | F01（pod-kill）/ F02（pod-failure）均产出可用数据 |
| Grafana 能看到异常曲线 | ✅ | 业务指标 + 6 条业务 SLI 规则 |
| （本周不写 AI 代码） | ✅ | 未动任何模型代码，符合排期纪律 |

---

## 3. 期间发现并修掉的问题（全部是"表面正常、实则失效"）

| # | 现象 | 根因 | 影响 | 处理 |
|---|---|---|---|---|
| 1 | Alertmanager 长期 0 告警 | `rule_files` 写 `/etc/prometheus/rules/*.yml`，但 ConfigMap 平铺挂载成 `/etc/prometheus/rules.yml` | **8 条规则从未生效** | 改路径；用 `/api/v1/rules` 校验（13 条） |
| 2 | 5 个节点全量假告警 `KubeletDown` | kubelet job 未配 `authorization.credentials_file`，scrape 时没带 token → 403 | 噪声淹没真告警 | 补 token → 5/5 `health=up` |
| 3 | 部署卡在 1/2 不收敛 | `limits.cpu` 配额 = 6，而滚动更新（maxSurge=1）需要额外一份 | 更新静默失败 | 配额提到 12 并注释原因 |
| 4 | 容器被反复杀（exit 137） | 探针默认 1s 超时 + `socketserver` accept 队列仅 5 | 业务抖动、假故障 | 探针 3s/阈值 5 + 应用 `request_queue_size=128` |
| 5 | OTel 容器起不来，报"文件不存在" | 0.116.0 二进制动态链接，镜像里**没有 glibc 加载器**（ENOENT 被误读成"镜像没拉全"） | 组件不可用 | 换 0.113.0；用 `ctr run ... --version` 验证而非 `ls` |
| 6 | Promtail 在 3 个节点永远 `0/1` 并触发 `PodNotReady` | `/ready` 在无采集目标时返回 500 | 假告警 | 就绪探针改 `tcpSocket` |
| 7 | 实验数据"有文件但全 null" | 纯标量查询返回 `resultType=scalar`，脚本只按 vector 解析；JSONL 写成了多行 | 数据不可用 | 两种返回都兼容 + 压成单行；产物加逐行解析校验 |
| 8 | P95 恒定 7.5s、延迟告警永不恢复 | 埋点对**已累积**的桶又累加一次（`cum += h[i]`）：`le="10.0"`=1139 而 `_count`=116 | 真实 10ms 被算成 7.5s，噪声直接进入 AIOps 输入 | 按直方图契约修正（单调 / `+Inf==count`），并写成单元测试 `_verify/verify_histogram.py`；修复后 P95 = 0.023–0.046s |

> 这 7 条的共同主题：**"配置写了 / 文件生成了 / 进程起来了"都不等于"功能真的生效"**，
> 必须查运行时状态与端到端数据。这正是 AIOps 项目最容易翻车的地方——上游数据本身就是错的，
> 后面再聪明的算法也只是在学噪声。

---

## 4. 演示脚本（5 分钟讲清楚）

1. **亮环境**（30s）：`bash scripts/13-verify-e2e.sh` → 19 项检查全绿（节点/Pod/指标/日志/告警/混沌/OTel/规则）。
2. **亮业务**（30s）：Grafana 打开业务面板 → 看到 frontend/order/payment 的 QPS 与延迟曲线在跑。
3. **造故障**（60s）：`run-experiment.sh f02-pod-failure-payment.yaml 90` → 演示 payment 全副本不可用。
4. **看数据**（60s）：同一时间窗内：Prometheus 上 payment 抓取消失、order 5xx 飙升（峰值 264）、Loki 里出现"下游调用失败"日志。
5. **看告警**（30s）：Alertmanager 里 `DemoAppDownstreamFailure` 触发，标注根因方向（order 调 payment 失败）。
6. **收尾**（60s）：实验产物目录 + `summary.json` 数字；说明下一步是把这条告警接进 Ingestion 做降噪与 RCA。

**演示重点**：项目交付了一套可重复、带 ground truth、可量化的故障数据集，而不只是搭起一个 Kubernetes 集群。

---

## 5. 数据与产物位置

| 内容 | 位置 |
|---|---|
| 实验原始数据（含 ground truth） | `/var/lib/aisre/experiments/<实验>-<时间戳>/` |
| Prometheus TSDB | `k8s-obs:/var/lib/aisre/prometheus`（保留 15 天 / 8GB） |
| Loki 日志 | `k8s-obs`（7 天保留） |
| 集群全部脚本/清单 | `/opt/aisre/{scripts,manifests,experiments}` |
| 本地仓库副本 | `ai-sre-agent/`（docs 01–05、scripts 01–13、manifests、experiments） |

---

## 6. 风险与下一步

| 风险 | 说明 | 缓解 |
|---|---|---|
| 分析层未开工 | 目前只有"数据"，还没有"智能" | 第 2 周主攻 Ingestion + 降噪（不接 LLM，先建基线） |
| 环境单点 | 1 控制面、obs 节点只有 15 GiB 内存 | 实验期间不叠加负载；TSDB 限量 8GB |
| 本地模型弱 | 8 GB 显存 → 7B 级别 | RCA 只做结构化输出，评测同时给出小模型 vs 云 API 对照 |
| 数据规模小 | 单实验分钟级、单集群 | 明确写清局限，不吹"生产级" |

**下一步（按依赖顺序）**：
1. Ingestion（Go）：Alertmanager Webhook → 统一 Event → 指纹去重 → NATS（**告警终于有消费方**）
2. 把每次实验的告警流/指标/日志自动导出到 `datasets/`（含 ground truth）
3. 降噪引擎三段式（Python，先不接 LLM，建立可对比的基线）
4. 异常检测（阈值→MAD→EWMA）+ 日志模板挖掘（Drain3）
5. RCA + RAG（候选集 → 四路证据 → 本地 LLM 结构化输出 → 幻觉后校验）
6. Agent 执行 + 安全护栏（CRD + Policy Engine + 审计哈希链）

---

## 7. 演示说明（摘要与常见问题）

**三句话**
1. 项目提供了一套 5 节点 K8s 实验环境，包含可观测性栈与混沌工程，部署过程已脚本化，可重复构建。
2. 项目自建了带埋点的被测微服务，以及带 ground truth 的实验采集工具链，跑通「注入故障 → 指标/日志/告警」链路。
3. 在该数据集上完成告警降噪与根因分析，并用恢复成功率、误自愈率和恢复时间等指标验证效果。

**常见问题（5 项）**

| 问题 | 回答要点 |
|---|---|
| 为什么不用 kind/k3s？ | 目标包含节点级混沌与真实节点拓扑（跨节点网络故障），kind 只有单机容器；且要用 openEuler 贴近国产化环境 |
| 数据规模是否足够？ | 当前是单集群、分钟级数据；重点是 ground truth 质量和可重复性，不在数据规模。规模化路径是多集群和长周期采集 |
| 告警降噪怎么评估？ | 三个指标：降噪率、簇纯度、**过度合并率**；用带 ground truth 的实验数据算，A/B 对照 |
| 怎么防 Agent 乱执行？ | 四级动作分级（L0 观察 ~ L3 高风险）、8 条策略校验、冷却期、审计哈希链、SLI 恢复判定后才算成功 |
| 为什么强调"误自愈率"？ | SRE 场景里，**错误的自动修复比不修复更贵**：它把故障藏起来、扩大影响面，且难以复盘。所以误自愈率是首要指标 |

---

## 变更记录

| 版本 | 日期 | 修改内容 |
|---|---|---|
| v1.0 | 2026-11-01 | 首次汇报：阶段成果、验收对照、7 个已修问题、演示脚本与演示说明 |