# 项目文档索引

**中文** | [English](en/README.md)

> AI SRE Agent —— 面向云原生环境的智能故障自愈与混沌验证平台

| 项 | 内容 |
|---|---|
| 项目代号 | AISRE-Agent |
| 文档总数 | 7（另有本索引） |
| 最后更新 | 2026-11-01 |
| 项目根目录 | `ai-sre-agent/` |

---

## 文档索引

按编号顺序阅读即可，编号即依赖顺序。

| # | 文档 | 行数（约） | 内容 |
|---|---|---|---|
| 01 | [技术设计](01-design.md) | 1955 | 项目全貌：架构、模块、算法、评测、排期、组件原理 |
| 02 | [集群访问与主机清单](02-cluster-access.md) | 296 | 5 节点集群的凭据、规格、配置记录与踩坑 |
| 03 | [本地大模型环境](03-local-llm.md) | 314 | RTX 2070 上可运行的模型清单与推理配置 |
| 04 | [项目进展日志](04-progress-log.md) | 190 | 逐日进度、状态总览、资产清单、风险与下一步 |
| 05 | [项目汇报](05-project-report.md) | 175 | 阶段成果、验收对照、演示脚本、汇报口径 |
| 08 | [演示指南](08-demo-guide.md) | 260 | **端到端自愈闭环演示脚本**（3~5 分钟录屏用，含实测时间线与讲解词） |
| 06 | [沉默故障复盘](06-pitfalls.md) | 306 | **8 个「表面正常、实则失效」的问题**：现象 / 根因 / 定位证据 / 修法 / 自查命令 |
| 09 | [故障矩阵报告](09-matrix-report.md) | 401 | **注入 → 观测 → 降噪/RCA 的实测矩阵（F01–F07、F13、F14）**：可评测结果、监控盲区证据与根因、行动项 |
| 10 | [可视化导读](10-visualization-guide.md) | 210 | **怎么用图表看懂实验目的**：四张图各回答什么问题、易误读的地方、四个指标各管什么 |
| — | **图形化控制台** | — | **集群内运行**：`http://172.29.20.21:30088`（主推，NodePort 在任意节点都可达）；**5 个标签页**：总览 / 大模型 / Agent / 实验 / **图表** |

### 按需求跳转

| 你的目的 | 看哪份 | 重点章节 |
|---|---|---|
| 了解项目要解决什么问题 | 01 | §1 项目概述、§9 混沌实验设计、§10 评测体系 |
| 理解技术方案与创新点 | 01 | §4 模块设计、§7 根因分析、§8 安全护栏 |
| 准备面试 | 01 | §18.2 面试话术（8 个必答题）、§1.5 差异化亮点 |
| 连接 / 操作集群 | 02 | §1 凭据、§5.4 集群状态、§5.5 脚本清单 |
| 排查环境问题 | 02 | §5.6 三个关键坑 |
| 调用本地大模型 | 03 | §2 可运行模型清单、§4 常用命令 |
| 理解各组件的原理 | 01 | §11.4 观测组件与混沌工程原理 |
| 了解后续排期 | 01 | §14 开发排期、§16 里程碑与验收标准 |
| 想知道"做到哪一步了" | 04 | 全篇（状态总览 / 逐日进度 / 下一步） |
| 要给别人讲这个项目 | 05 | §1 成果、§4 演示脚本、§7 汇报口径 |
| 想查某个坑怎么修 / 怎么自查 | 06 | 全篇（P01–P08，每条末尾都有自查命令） |
| 看懂图表上的数字 | 10 | 全篇（每张图「怎么看」+ 指标速查表） |
| 想看实验实测数字 / 观测盲区 | 09 | §0 结论、§3 结果、§4 盲区根因 |
| 排查业务与告警链路 | 02 | §5.11 demo-app、§5.13 两处误报、§5.15 实验闭环 |

---

## 脚本索引

| # | 脚本 | 运行位置 | 作用 |
|---|---|---|---|
| 01 | `scripts/01-baseline.sh` | 全部节点 | 系统层基线：主机名 / SELinux / 时间同步 / 内核参数 |
| 02 | `scripts/02-node-runtime.sh` | 全部节点 | containerd + K8s 组件 + CNI 插件 + 镜像加速 |
| 03 | `scripts/03-init-cluster.sh` | 仅 k8s-cp | 控制面初始化 + Flannel + 生成 join 命令 |
| 04 | `scripts/04-join-cluster.sh` | worker 节点 | 加入集群 |
| 05 | `scripts/05-verify-cluster.sh` | 仅 k8s-cp | 集群就绪验证（只读） |
| 06 | `scripts/06-preload-images.sh` | 全部节点 | 镜像预拉取（国内源+改名）——慢，备用 |
| 07 | `scripts/07-distribute-images.ps1` | 开发机 | **镜像分发（推荐）**：本机拉取 → 局域网传输 → `ctr` 导入 |
| 08 | `scripts/08-verify-images.sh` | 全部节点 | 镜像清单核对（只读） |
| 09 | `scripts/09-deploy-observability.sh` | 仅 k8s-cp | 可观测性栈（7 个组件，幂等） |
| 10 | `scripts/10-deploy-chaos-mesh.sh` | 仅 k8s-cp | Chaos Mesh v2.8.7（23 CRD，含三处本地化修改） |
| 11 | `scripts/11-deploy-demo-app.sh` | 仅 k8s-cp | 被测业务 demo-app（6 个负载，幂等） |
| 12 | `scripts/12-deploy-otel-collector.sh` | 仅 k8s-cp | OTel Collector（含 OTLP→Loki 自检） |
| 13 | `scripts/13-verify-e2e.sh` | 仅 k8s-cp | 端到端验证（10 组、25 项检查，只读） |
| 14 | `scripts/14-deploy-ingestion.sh` | 仅 k8s-cp | AIOps 接入层 aisre-ingest（告警接入/归一化/去重/落盘） |
| 15 | `scripts/15-export-dataset.sh` | 仅 k8s-cp | 把一次实验导出为自包含数据集（事件+指标+日志+ground truth+哈希） |
| 16 | `scripts/16-correlation-baseline.py` | 任意机器（只读） | 降噪计算：基线 vs 时间窗+拓扑聚类，输出降噪率/纯度/过度合并率 |
| 17 | `scripts/17-collect-topology.sh` | 仅 k8s-cp | 从 Deployment env + Service/Endpoints 采集**真实拓扑**（call / dependency 两类边） |
| 18 | `scripts/18-tag-ground-truth.sh` | 仅 k8s-cp | ground truth 标签传播（Pod 标签 → 指标 → 告警 → 事件） |
| 19 | `scripts/19-rca-llm.py` | 开发机（Ollama） | 本地 LLM 做 RCA：结构化 prompt + 拓扑折叠 + 幻觉校验 + **RAG 检索增强**（`--rag-kb`，见 [P46](06-pitfalls.md) 的显存陷阱） |
| 20 | `scripts/20-eval-rca.py` | 任意机器（只读） | RCA A/B 对照：规则基线 / 0.6B / 7B / 两级 |
| 21 | `scripts/21-rca-tiered.py` | 开发机（Ollama） | 两级模型：0.6B 初筛 + 7B 复核 |
| 22 | `scripts/22-anomaly-detect.py` | 任意机器（只读） | 时序异常检测三层：阈值 → MAD → EWMA（含去抖与事件合并） |
| 23 | `scripts/23-log-template.py` | 任意机器（只读） | 日志模板挖掘 + 异常模板识别（自带轻量 Drain 实现） |
| 24 | `scripts/24-deploy-agent.sh` | 仅 k8s-cp | 部署自愈执行层 aisre-agent（策略引擎+执行器+审计链） |
| 25 | `scripts/25-agent-selftest.sh` | 仅 k8s-cp | 自愈执行层 9 项策略正/反用例自检（含真实滚动重启） |
| 26 | `scripts/26-apply-grafana-dashboards.sh` | 仅 k8s-cp | 应用 3 个定制 Grafana 仪表盘并用 API 校验 |
| 27 | `scripts/27-ollama-logs.ps1` | 开发机 | 本地大模型工作日志：查看 / 实时跟随 / 汇总 / 自检 / 可观测方式重启 |
| 28 | `scripts/28-selfheal-loop.sh` | 仅 k8s-cp | 端到端自愈闭环驱动：两阶段（注入取证 / 策略·执行·恢复·审计），可重复执行 |
| 29 | `scripts/29-run-matrix.sh` | 仅 k8s-cp | 故障实验矩阵（F01–F07、F13 级联、F14 多根因）批量执行 + 落盘汇总；**含“告警窗口排空”闸门**（P31） |
| 30 | `scripts/30-eval-matrix.py` | 任意机器（只读数据集） | 矩阵评测汇总：逐实验算降噪率/纯度/过度合并/候选 P·R/Top-1/MRR，输出 md+json |
| 31 | `scripts/31-sync-prometheus-config.py` | 任意机器 | **把 `_prometheus*.yml` 确定性渲染进 `03-prometheus.yaml`**（含 `--check` 一致性校验，P36） |
| 32 | `scripts/32-apply-prometheus-config.sh` | 仅 k8s-cp | 应用 Prometheus 配置/规则：**备份 → apply → 重启 → 强制验证**（规则条数/新规则/cAdvisor up） |
| 33 | `scripts/33-check-rule-coverage.py` | 任意机器 | **规则↔降噪覆盖回归测试**（P43 防复发）：静态查「业务规则是否登记了证据分类」+ 数据查「历史数据集是否出现空候选」 |
| 34 | `scripts/34-check-metric-contracts.py` | 任意机器（查 Prometheus） | **指标契约自检**（P38 防复发）：直方图三条不变量 —— 桶单调 / `+Inf == _count` / 均值与 P95 量级一致；含负向验证 |
| 35 | `scripts/35-summarize-repeats.py` | 任意机器（只读数据集） | **重复性汇总**：同一故障多轮 → 均值±标准差、Top-1 命中率 |
| 36 | `scripts/36-build-kb.py` | 开发机（Ollama bge-m3） | **构建 RAG 知识库**：把 `docs/06-pitfalls.md` 的 50 条复盘切成条目并向量化 → `kb/pitfalls-kb.jsonl` |
| 37 | `scripts/37-sync-agent-logs.ps1` | 开发机（SSH 到控制面） | ~~本地控制台的数据同步~~ **已停用**（2026-11-03 本地控制台删除，改由集群内控制台直连取数）；脚本保留备用 |
| 38 | `scripts/38-dashboard.py` | **仅集群内**（`--cluster`） | **图形化控制台**：五标签页 —— 总览 / 大模型 / Agent / 实验 / **图表**（降噪率、轮次构成、RAG 对照）；实时查 Prometheus / Alertmanager / aisre-agent / K8s API |
| 39 | `scripts/39-deploy-dashboard.sh` | 仅 k8s-cp | **把控制台部署到集群**：代码+数据走 ConfigMap（免自建镜像）→ 滚动重启 → NodePort **30088** |
| 40 | `scripts/40-eval-rag-ab.py` | 开发机（Ollama） | **RAG 全矩阵 A/B**：同一批数据集跑「无 RAG vs 带 RAG」，比对 Top-1 / 耗时 / 检索命中 |
| 41 | `scripts/41-collect-extra-datasets.py` | 任意机器（只读） | 收集**不在故障矩阵里**的历史实验数据集（含「已被新数据取代」标记） |

全部脚本**幂等**，可重复执行；每项独立报告 `✔ / ! / ✘`，有失败项返回非零退出码。

```
manifests/
├── kube-flannel.yml            # CNI 清单（本地化，集群侧访问不了 GitHub）
├── chaos-mesh/chaos-mesh.yaml  # Chaos Mesh（containerd 运行时 + tolerations + 单副本）
├── demo-app/                   # 被测业务（00 命名空间 → 05 压测）
└── observability/              # 00 命名空间 → 07 Grafana，08 OTel Collector
    └── _*.yml                  # 下划线开头：配置片段，供人读，不直接 apply
```

实验定义与采集脚本在 `experiments/`：`f01-pod-kill-payment.yaml`、`f02-pod-failure-payment.yaml`、
`01-pod-chaos.yaml`（合集）、`run-experiment.sh`（执行 + 采样 + 汇总，产物带 ground truth）。

---

## 目录约定

### 编号规则

**编号 = 阅读顺序 = 依赖顺序**，不是创建时间。

- `docs/` 的编号反映「先懂设计，再搭环境，再配组件」的认知路径
- `scripts/` 的编号反映执行顺序（01 必须在 02 之前跑）

### 新增文档时

- 文件名格式：`NN-短横线连接的小写英文.md`（如 `04-observability.md`）
- 在本文档的「文档索引」表中登记
- 在相邻文档的元信息表「关联文档」一行里互相链接

---

## 凭据与开源说明

**本仓库不含任何真实凭据**，且已做过发布前扫描（109 个文件 / 4 MB）。

| 类别 | 处理方式 |
|---|---|
| **系统 root 密码** | **不写入仓库**。需要密码的脚本（`07-distribute-images.ps1`、`37-sync-agent-logs.ps1`）从环境变量 `$env:LAB_ROOT_PASSWORD` 读取，未设置则直接报错退出 |
| **项目自建组件的口令** | **照常公开**（部署产物，非外部凭据）：Grafana `admin` / `aisre-lab-admin`；demo-app PostgreSQL `app` / `demo-pass` |
| **主机 IP** | 文档里的 `172.29.20.21`–`25` 是**示例私有网段**，按自己的环境替换 |
| **kubeconfig / 私钥** | 不入库（`.gitignore` 已覆盖 `*.pem` `*.key` `id_rsa*` `kubeconfig`） |
| **运行产物** | `_logs/` `_verify/` `datasets/*/` `kb/`（向量库）均不入库 |

发布前自查（可随时重跑）：

```bash
# 1) 确认没有真实系统密码残留
grep -rn "openEuler" . --include="*.md" --include="*.sh" --include="*.ps1" --include="*.yaml"

# 2) 列一遍会被提交的文件，肉眼过一遍
git ls-files --others --exclude-standard

# 3) 常规敏感词扫描
grep -rniE "password|passwd|secret|api[_-]?key|BEGIN (RSA|OPENSSH)" . \
  --include="*.md" --include="*.yaml" --include="*.sh" --include="*.py"
```

---

## 相关位置

| 内容 | 位置 |
|---|---|
| 集群节点上的脚本部署路径 | `/opt/aisre/{scripts,manifests}` |
| 控制面 kubeconfig | `k8s-cp:/root/.kube/config`（普通用户目录下也有副本） |
| 节点加入命令 | `k8s-cp:/opt/cluster-join.sh`（token 默认 24 小时有效） |
| 本地大模型模型目录 | 开发机 `D:\LLM` |

---

## 变更记录

| 版本 | 日期 | 修改内容 |
|---|---|---|
| v1.0 | 2026-10-31 | 建立文档索引：编号规范、按需求跳转表、脚本索引、敏感文件提醒 |
| v1.1 | 2026-11-01 | 文档索引扩到 5 份（新增 04 项目进展、05 项目汇报）；脚本索引补到 13 个；补充 manifests/experiments 目录说明 |
| v1.2 | 2026-11-01 | 新增 **06 沉默故障复盘**（8 个问题的现象/根因/修法/自查命令）；02 文档 §5.11 交叉引用；§5.11.5→§5.11.7 编号顺位修正 |
| v1.3 | 2026-11-01 | 脚本索引补到 14 个；13 号脚本检查项更新为 10 组 25 项 |
| v1.4 | 2026-11-02 | 脚本索引补到 16 个（数据集导出 + 降噪基线）；datasets/ 目录投入实际使用 |
| v1.5 | 2026-11-02 | 脚本索引补到 17 个；降噪第 2 段落地（真实拓扑 + 候选集合口径） |
| v1.6 | 2026-11-02 | 脚本索引补到 25 个（标签传播 / LLM RCA / 两级模型 / 异常检测 / 日志模板 / 自愈执行层） |
| v1.7 | 2026-11-02 | 脚本补到 26；新增 3 个定制 Grafana 仪表盘（总览 / 业务 SLI / AIOps 自愈链路） |
| v1.8 | 2026-11-02 | 脚本补到 27；新增本地大模型工作日志查看（含 token/耗时/生成速率落盘） |
| v1.9 | 2026-11-02 | 新增 08 演示指南；脚本补到 28（端到端自愈闭环驱动） |
| v2.0 | 2026-11-02 | 脚本补到 30（自愈闭环驱动 / 故障矩阵 / 矩阵评测）；实验矩阵 F01–F06 跑通并落盘 |
| v2.1 | 2026-11-02 | 06 沉默故障复盘扩到 **34**（新增 P31 批量实验窗口未排空、P32 matrix.jsonl 缺换行、P33 导出窗口越过 T0、P34 导出抢在投递之前）|
| v2.2 | 2026-11-02 | 新增 **09 故障矩阵报告**（F01–F07 实测：有告警 3 例全对；F03/F04/F05 监控盲区，F05 已用实测反证故障为真）|
| v2.3 | 2026-11-03 | 脚本补到 32；06 扩到 **40**（P35–P40）；补观测盲区：5 条新规则 + cAdvisor 抓取 |
| v2.4 | 2026-11-03 | 修 **P38 下游直方图双重累积**（P02 孪生，因无消费者潜伏）；实验时长统一 ≥6min；导出窗口改为 `[T0, 故障结束+余量]` |
| v2.5 | 2026-11-03 | 06 扩到 **44**（P41–P44）；**复验完成：F03/F04/F05 全部产生告警，7/7 实验可评测**；09 新增 §6 复验 |
| v2.6 | 2026-11-03 | 新增 `31/32` 号脚本（配置单向生成 + 带备份校验的部署）；评测支持 `--only-latest` 与权威 GT 覆盖 |
| v2.7 | 2026-11-03 | **P43 闭环**：降噪候选升级为候选集合 + pod→service 还原 + 证据分类补齐；候选召回 0.71→**1.00**、Top-1 命中 71.4%→**85.7%** |
| v2.8 | 2026-11-03 | 新增 `33-check-rule-coverage.py`（规则覆盖回归测试，含负向验证）；`DemoAppDownstreamLatencyHigh` 加**边类判责条件**（被调方自身 P95 正常才告警） |
| v2.9 | 2026-11-03 | 判责条件复验完成：簇纯度 85.7%、候选精确率 0.86、MRR 0.893、召回 1.00；06 扩到 **45**（新增 P45） |
| v3.0 | 2026-11-03 | **P45 彻底闭环**：边瓶颈截断 + 错误闸门 → **矩阵 7/7 Top-1 命中、纯度 100%、过度合并 0%、候选 P/R 1.00/1.00** |
| v3.1 | 2026-11-03 | 新增 `34-check-metric-contracts.py`（指标契约自检，含负向验证）与 `35-summarize-repeats.py`（重复性汇总）；启动 **3 轮重复性实验** |
| v3.2 | 2026-11-03 | **RAG 接入**：新增 `36-build-kb.py`（46 条复盘 → 向量库）+ `19` 支持 `--rag-kb`；F03 实测 Top-1 由 payment（错）纠正为 **order（对）**，代价 +3.3s；06 扩到 **46**（P46 显存陷阱） |
| v3.3 | 2026-11-03 | 新增 **图形化控制台**（`37` 同步 Agent 日志 + `38` 本地 Dashboard）；修 **P49 拓扑折叠把 LLM 答对的结论改错**（加置信度守卫）；06 扩到 **49**（P47 SSH 嵌套管道 / P48 PS 需 BOM / P49 折叠） |
| v3.4 | 2026-11-03 | 控制台**部署进集群**（`39` + `manifests/aiops/03-dashboard.yaml`）：`http://172.29.20.23:30088`；扩为四标签页并改为集群内实时取数 |
| v3.5 | 2026-11-03 | **删除本地控制台**（进程 + `dashboard-data/` + `_logs/agent/`）；控制台统一以集群内形态提供 |
| v3.6 | 2026-11-03 | **3 轮重复实验完成**：可评测 17 轮 Top-1 命中 **100%**、纯度 100%、过度合并 0%；发现 **P50 实验可复现性问题**（F06 三轮零告警）；汇总已接入集群控制台 |
| v3.7 | 2026-11-03 | **修 P50（F06）**：压力 200MB→360MB + 新增 `ContainerMemoryHigh` 规则；实测内存 93%、注入后 171s 触发 |
| v3.8 | 2026-11-03 | 新增 `40-eval-rag-ab.py` 做 **RAG 全矩阵 A/B**：结果是**负结果**（RAG 7/7 vs 无 RAG 7/7，无增益）→ 记入 09 §6.7 |
| v3.9 | 2026-11-04 | 控制台新增**「图表」标签页**（降噪率±σ / 轮次构成 / RAG 对照）；**主推访问地址改为 `http://172.29.20.21:30088`** |
| v4.0 | 2026-11-04 | 图表尺寸适配窄屏（min-width 680 / max-width 940 + 横向滚动），文字保持可读 |
| v4.1 | 2026-11-04 | 新增 **10 可视化导读**（每张图怎么看 + 指标速查）；控制台图表页内嵌「怎么看」提示；补 **非矩阵实验图**（F13/F14/自愈闭环） |
| v4.2 | 2026-11-04 | **重跑 F13/F14**（旧数据是 11-02 用旧规则+180s 时长产的，已过时）：定义校准到 360s、修掉 F13 里失效的 `target`，各跑 3 轮 |
| v4.3 | 2026-11-04 | F13/F14 重跑完成并**并入矩阵**（原来只有单次旧数据）→ 总体 **可评测 26 轮、Top-1 26/26**；「非矩阵实验」图加 `[历史]` 标记 |
| v4.4 | 2026-11-04 | 新增 [10 可视化导读](10-visualization-guide.md)；控制台图表页内嵌「怎么看」提示 |
