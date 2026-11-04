# 数据集目录（datasets/）

> **这是本仓库最有价值的部分**：别人 clone 下来，不重建集群也能复现你的分析结论。
> 每个子目录 = 一次混沌实验的完整证据链（告警流 + 指标 + 日志 + ground truth）。

## 1. 目录规范

```
datasets/
└── <实验编号>-<YYYYMMDD-HHMM>/
    ├── ground_truth.json    # 这次故障的"标准答案"：故障类型 / 目标服务 / 注入与恢复时间
    ├── events.jsonl         # 告警事件流（来自 aisre-ingest 的统一 Event 模型，一行一条）
    ├── metrics.json         # 关键 SLI 的窗口采样（PromQL 原始返回值 + 查询语句）
    ├── logs.txt             # 涉及服务的日志片段（Loki/容器日志）
    ├── correlation.json     # 降噪计算结果（由 scripts/16 生成，可选）
    ├── manifest.sha256      # 各文件哈希（防止数据被悄悄改动）
    └── README.md            # 这次实验的结论与局限
```

命名规则：`F02-20261101-1859` = 故障编号 F02 + 注入时刻（本地时间）。

## 2. 字段口径（events.jsonl）

| 字段 | 含义 |
|---|---|
| `event_id` | 事件唯一 ID（去重键 + 告警开始时间） |
| `status` | `firing` / `resolved`（**两者都要留**：恢复通知也是证据） |
| `alertname` | 告警名（对应 `manifests/observability/_prometheus-rules.yml` 里的规则） |
| `service` / `downstream` | **拓扑信息**：`service=order downstream=payment` 表示"order 调用 payment 失败" |
| `starts_at` / `ends_at` | 告警自身的起止（来自 Alertmanager） |
| `received_at` | Ingestion 收到的时间（用于算链路延迟） |
| `dedup_key` / `dedup_count` / `duplicate` | 指纹去重结果 |
| `ground_truth` | 若上游标签里带了 ground truth 则填充；否则由数据集侧按时间窗关联 |

## 3. ground truth 怎么来（两种，逐步补齐）

1. **时间窗关联（当前采用）**：实验脚本知道"故障注入时刻 + 持续时间 + 目标服务"，
   导出数据集时把这段时间窗内的告警整体标注为"根因 = 目标服务"。
2. **标签传播（待做）**：在注入时给目标 Pod/命名空间打 `ground-truth=<service>` 标签，
   让告警规则把该标签带进 `labels`，事件里就自带答案。**这是更可靠的方式**，
   因为它不依赖"时间窗恰好对齐"这种假设。

## 4. 局限（写清楚，别自欺）

| 局限 | 影响 |
|---|---|
| 单集群、分钟级数据 | 不能声称"生产规模" |
| 故障以"单根因"为主 | 多根因并发时"过度合并率"的评估才真正有效（F14 会覆盖） |
| 日志为容器标准输出片段 | 不含内核/审计日志 |
| 数据量小 | 价值在**标注质量与可重复性**，不在规模 |

## 5. 怎么复现分析

```bash
# 只读：读数据集算降噪指标（不需要集群）
python3 scripts/16-correlation-baseline.py datasets/F02-20261101-1859
```

输出：控制台表格 + `correlation.json`（降噪率 / 簇纯度 / 过度合并率）。