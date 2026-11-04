# 沉默故障复盘：8 个"表面正常、实则失效"的问题

| 项 | 内容 |
|---|---|
| 记录日期 | 2026-11-01 |
| 记录范围 | K8s 集群搭建 → 可观测性 → 被测业务 → 混沌闭环（第 0–1 周） |
| 问题数 | 50（P01–P08 已修复验证；P09–P50 见 §11） |
| 关联文档 | [文档索引](README.md) · [01 技术设计](01-design.md) · [02 集群访问与主机清单](02-cluster-access.md) · [04 项目进展](04-progress-log.md) · [05 项目汇报](05-project-report.md) |

---

## 0. 为什么单独写这一篇

**"沉默故障"的定义**：不报错、不崩溃、进程在跑、`kubectl get pods` 全绿，
但**功能已经失效**——而且往往失效的正是最关键的那部分（指标是错的、告警没发出、更新没生效）。

这类问题比"服务起不来"危险得多：

| | 服务起不来 | 沉默故障 |
|---|---|---|
| 谁会发现 | 立刻，CI/监控直接红 | 可能几天都没人发现 |
| 排查方向 | 看日志、看事件 | **没有日志，因为没人知道它坏了** |
| 典型代价 | 一次重启 | 错误的数据/结论被下游一路复用 |

本项目第 0–1 周共踩到 8 个，全部属于这一类。逐个记录，是为了以后不再犯，也是为了面试能讲清。

### 判据：四条"正常"的错觉

| 你以为的正常 | 实际需要验证的 |
|---|---|
| 配置文件里写了 | **运行时状态**（例：`/api/v1/rules` 真的数出 13 条） |
| 文件生成了、有内容 | **数据可用**（逐行解析、契约断言通过） |
| 进程起来了、Pod Running | **端到端功能**（探针不杀容器、业务数字合理） |
| 指标有值、格式合规 | **口径正确**（桶单调、`+Inf == count`） |

---

## 1. 总览（按危害排序）

| # | 问题 | 一句话 | 危害等级 |
|---|---|---|---|
| P01 | 告警规则从未加载 | `rule_files` 路径与挂载点不一致，8 条规则**一条都没生效** | ★★★★★ 沉默 |
| P02 | 埋点直方图二次累积 | 真实 10ms 的 P95 被算成 **7.5s**，延迟告警永久误报 | ★★★★★ 污染数据 |
| P03 | 实验数据全 `null` | scalar 结果当 vector 解析 + JSONL 写成多行，**数据"有文件但不可用"** | ★★★★ 污染数据 |
| P04 | kubelet 抓取 403 | 未带 token → 5 节点全量假告警 `KubeletDown` | ★★★★ 淹没真信号 |
| P05 | 配额未留 surge | 滚动更新**静默卡死**在 1/2 | ★★★ 静默失败 |
| P06 | OTel 镜像缺 glibc | 报"文件不存在"，极易误判为镜像没拉全 | ★★★ 组件不可用 |
| P07 | 探针超时 + accept 队列溢出 | 容器被 kubelet 判死（exit 137），业务抖动 | ★★★ 反复重启 |
| P08 | Promtail `/ready` 当就绪探针 | 空节点永久 0/1，并连带刷 `PodNotReady` | ★★ 假告警 |

---

## P01 8 条告警规则**从来没生效过**

| 项 | 内容 |
|---|---|
| **表面正常** | Prometheus `1/1 Running`；配置文件里明明写着 `rule_files: - /etc/prometheus/rules/*.yml` |
| **实际故障** | 规则一条都没加载，Alertmanager 长期 **0 告警**——整条"故障→告警"链路断在这里 |
| **根因** | ConfigMap **平铺挂载**：容器里是 `/etc/prometheus/rules.yml`，**没有 `rules/` 目录**，通配符匹配了空 |
| **为什么难发现** | Prometheus 只在**启动日志**报规则加载失败，跑起来后不吭声，UI 不标红 |

关键证据：

```
$ ls -l /etc/prometheus
prometheus.yml -> ..data/prometheus.yml
rules.yml      -> ..data/rules.yml
$ ls -l /etc/prometheus/rules
ls: /etc/prometheus/rules: No such file or directory
```

**修法**：`rule_files: - /etc/prometheus/rules.yml`；部署脚本加预检（先数 ConfigMap 的 `data` 键数量，键数不对就不重启）。

**自查**：

```bash
kubectl -n observability exec deploy/prometheus -c prometheus -- \
  wget -qO- http://localhost:9090/api/v1/rules | grep -c '"type":"alerting"'   # 期望 13
```

关联：[02 §5.11.3](02-cluster-access.md) · `manifests/observability/03-prometheus.yaml`

---

## P02 埋点直方图"累积的累积" → P95 恒定 7.5s

| 项 | 内容 |
|---|---|
| **表面正常** | `/metrics` 格式合规、Prometheus 抓得到、`histogram_quantile` 算得出数 |
| **实际故障** | 真实约 10ms 的 P95 被算成 **7.5s**，`DemoAppHighLatency` 变成**永久告警** |
| **根因** | `render_metrics()` 对**已是累积值**的桶又累加一次（`cum += h[i]`）；`observe()` 里已经按 `seconds <= b` 累加过了 |

关键证据（集群实测）：

```
le="10.0"  1139     ← 竟然大于请求总数
le="+Inf"   116
_count      116
```

**三条硬性契约**（已写成单元测试 `_verify/verify_histogram.py`）：

| 契约 | 含义 |
|---|---|
| bucket 单调不减 | 累积计数只增不减 |
| `le="+Inf"` == `_count` | 最高桶必须等于总数 |
| 最高有限桶 ≤ 总数 | 二次累积的直接破绽 |

**修法**：桶值直接输出 `h[i]`；修复后固定样本（95×3ms + 5×300ms）：`le=10.0`=100 == `+Inf`=100 == `_count`=100。

**实测对比**：

| | frontend | order | payment |
|---|---|---|---|
| 修复前 P95 | 7.66 s | 7.65 s | 7.39 s |
| 修复后 P95 | 0.046 s | 0.025 s | 0.023 s |

**自查**：三行数字必须相等（`le="10.0"` / `le="+Inf"` / `_count`）。

关联：[02 §5.11.6](02-cluster-access.md) · `_verify/VERIFICATION.txt` · `_verify/verify_histogram.py`

---

## P03 实验数据"有文件、有内容"，其实全不可用

| 项 | 内容 |
|---|---|
| **表面正常** | 跑完实验，`samples.jsonl` 有几十行、大小正常、脚本没报错 |
| **实际故障** | 所有采样静默变成 `null`；JSONL 逐行解析直接抛异常 |
| **根因（两个 bug 叠加）** | ① `sum()/count()` 这类**纯标量**查询返回 `resultType=scalar`（`data.result=[时间戳,"值"]`），脚本按 vector 的 `[[{value:[ts,val]}]]` 解析 → `TypeError: 'float' object is not subscriptable`，被 try 吞掉；② 输出用了多行美化 JSON，而 JSONL 要求**一行一条** |
| **危害** | **数据"看着有"其实全是空**；若不发现，后续所有模型评测都是错的 |

**修法**：`q()` 按 `resultType` 分别取值；写盘前压成单行（`separators=(',',':')`）；产物必须**逐行解析通过**才算跑完。

**自查**：

```bash
python3 - <<'PY'
import json,glob,os
d=sorted(glob.glob('/var/lib/aisre/experiments/F0*/'))[-1]
n=sum(1 for l in open(os.path.join(d,'samples.jsonl')) if l.strip() and json.loads(l))
print(d, '逐行 OK:', n)
PY
```

关联：[02 §5.14](02-cluster-access.md) · `experiments/run-experiment.sh`

---

## P04 kubelet 抓取 403 → 5 个节点全量假告警

| 项 | 内容 |
|---|---|
| **表面正常** | 节点全部 `Ready`，kubelet 本身工作正常 |
| **实际故障** | `up{job="kubelet"}=0` → 5 条 `KubeletDown` critical 假告警 |
| **根因** | `kubernetes_sd` 只用 token 做**服务发现**；真正 scrape 时 Prometheus **不会自动带 token**，访问 `nodes/proxy` 返回 **403 Forbidden** |

关键证据：

```
scrapeUrl=https://kubernetes.default.svc:443/api/v1/nodes/k8s-cp/proxy/metrics
health=down  err=server returned HTTP status 403 Forbidden
```

**修法**：

```yaml
- job_name: kubelet
  scheme: https
  authorization:
    credentials_file: /var/run/secrets/kubernetes.io/serviceaccount/token
```

**自查**：`job=kubelet` 且 `health=up` 的 target 数 = **5**。

> 教训：**监控系统自己会变成噪声源**。假告警会把真告警淹没——这正是本项目"降噪"要解决的问题，而它必须先解决自己的噪声。

关联：[02 §5.13.1](02-cluster-access.md) · `manifests/observability/03-prometheus.yaml`

---

## P05 滚动更新静默卡死在 1/2（ResourceQuota 未留 surge）

| 项 | 内容 |
|---|---|
| **表面正常** | Deployment 显示 `1/2 available`，Pod 都 Running，没有红色报错弹出来 |
| **实际故障** | 新版本永远上不去，旧 Pod 一直保留，**更新静默失败** |
| **根因** | `limits.cpu` 配额 = 6，正好等于 6 个应用容器 limits 之和；`maxSurge=1 / maxUnavailable=0` 的滚动更新**需要额外一份** |

关键证据：

```
Warning FailedCreate: pods "frontend-5b7c8bf879-grp2h" is forbidden:
  exceeded quota: demo-app-quota,
  requested: limits.cpu=800m, used: limits.cpu=5300m, limited: limits.cpu=6
```

**修法**：配额提到 `requests.cpu=4 / limits.cpu=12 / limits.memory=12Gi`，并在清单里注释"为什么必须留余量"。

**自查**：`kubectl -n demo-app describe quota demo-app-quota` → `limits.cpu` 使用量明显小于上限。

关联：[02 §5.11.1](02-cluster-access.md) · `manifests/demo-app/00-namespace.yaml`

---

## P06 OTel 容器报"文件不存在"——实为镜像缺 glibc 加载器

| 项 | 内容 |
|---|---|
| **表面正常** | 镜像标签、digest 都在；层 blob 完整（79.85 MB）；挂载后 `/otelcol-contrib` 确实存在（308 MB，`-rwxr-xr-x`） |
| **实际故障** | 容器起不来：`exec /otelcol-contrib: no such file or directory` |
| **根因** | 该镜像是精简手工构建，二进制**动态链接**：`interpreter /lib64/ld-linux-x86-64.so.2`，而镜像里**没有 glibc 加载器**。内核 `execve` 找不到解释器时返回的**就是 ENOENT** |
| **踩坑代价** | 极容易误判成"镜像没拉全"，反复重拉（本次确实白折腾了两轮） |

排查顺序（可作为通用方法）：

| 步骤 | 结果 |
|---|---|
| 镜像是否存在 | ✅ |
| 层 blob 是否完整 | ✅ `ctr content get <layer> \| tar -tzf -` 能列出，大小与 manifest 一致 |
| 挂载根文件系统 | ✅ `/otelcol-contrib` 存在且可执行 |
| `file` 看二进制类型 | ❌ `dynamically linked` |
| 镜像里有没有加载器 | ❌ 只有 `/etc/ssl/certs`、`/etc/otelcol-contrib`、`/otelcol-contrib` |

**修法**：换 0.113.0（静态链接）：

```bash
ctr -n k8s.io run --rm docker.io/otel/opentelemetry-collector-contrib:0.113.0 probe /otelcol-contrib --version
# otelcol-contrib version 0.113.0
```

> **通用判据**：判断"镜像能不能用"**要真的执行一次**，不能只看 `ls`。镜像里没有 shell 也能验：`ctr run <img> <id> <binary> <args>`。

**自查**：

```bash
# ① 镜像里的二进制真的能跑（在节点上执行，不需要容器内有 shell）
ctr -n k8s.io run --rm docker.io/otel/opentelemetry-collector-contrib:0.113.0 probe /otelcol-contrib --version
# ② Collector 就绪（镜像内无 shell，所以探针走 K8s readiness，不 exec wget）
kubectl -n observability get pod -l app=otel-collector -o jsonpath='{.items[0].status.containerStatuses[0].ready}'; echo
# ③ 端口从业务 Pod 侧探测（借 python3）
kubectl -n demo-app exec deploy/frontend -- python3 -c "import socket;s=socket.socket();s.settimeout(4);s.connect(('otel-collector.observability.svc',4318));print('4318 ok')"
```

关联：[02 §5.12.1](02-cluster-access.md) · `_verify/VERIFICATION.txt` · `manifests/observability/08-otel-collector.yaml`

---

## P07 探针 1s 超时 + accept 队列溢出 → 容器被反复杀（exit 137）

| 项 | 内容 |
|---|---|
| **表面正常** | 服务能跑、能响应；重启后也起来了，看起来"偶尔抖一下" |
| **实际故障** | kubelet 判死并 SIGKILL（exit 137），业务出现瞬时 5xx |
| **根因（两层叠加）** | ① `httpGet` 探针默认 **1s 超时**；② Python `ThreadingHTTPServer` 的 accept 队列（`request_queue_size`）**默认只有 5**，业务请求 + Prometheus 抓取 + 探针并发时 backlog 溢出，新连接被排队/丢弃，探针读不到响应头 |

关键证据：

```
Warning Unhealthy: Liveness probe failed:
  Get "http://10.244.2.23:8080/healthz": context deadline exceeded
  (Client.Timeout exceeded while awaiting headers)
```

**修法（两侧都要改）**：

| 侧 | 改动 |
|---|---|
| 应用 | `ThreadingHTTPServer.request_queue_size = 128` |
| 清单 | 探针 `timeoutSeconds: 3`、liveness `failureThreshold: 5`、`initialDelaySeconds: 20` |
| 资源 | `limits.cpu 400m → 800m`（突发时会被 CFS 限流） |

**自查**：Pod 重启次数合计 = **0**；`--field-selector reason=Unhealthy` 事件 **0** 条。

关联：[02 §5.11.2](02-cluster-access.md) · `manifests/demo-app/03-services.yaml` · `_verify/VERIFICATION.txt`

---

## P08 Promtail `/ready` 当就绪探针 → 空节点永久 0/1

| 项 | 内容 |
|---|---|
| **表面正常** | Promtail 进程在跑，业务日志确实进了 Loki |
| **实际故障** | cp/obs/ai 三个**没有业务 Pod** 的节点长期 `0/1`，并连带触发 3 条 `PodNotReady` 假告警 |
| **根因** | Promtail 的 `/ready` 在**没有任何可采集目标**时返回 **500**（这是它的设计），却被当成了 `readinessProbe` |

**修法**：就绪探针改 `tcpSocket: { port: 9080 }`（进程在监听即视为健康）；liveness 本来就该用 `tcpSocket`。

**自查**：`kubectl -n observability get pod -l app=promtail --no-headers` → `ready = 5/5`。

关联：[02 §5.13.2](02-cluster-access.md) · `manifests/observability/06-promtail.yaml`

---

## 9. 预防清单（下次动手前先看这个）

- [ ] **改配置后查运行时状态**，不要只 `cat` 配置文件（P01）
- [ ] **指标改动先验契约**：桶单调、`+Inf == count`、最高桶 ≤ 总数（P02）
- [ ] **数据采集脚本自带校验**：产物逐行解析 + 打印汇总才算通过（P03）
- [ ] **所有 scrape job 显式声明鉴权**（P04）
- [ ] **配额按"峰值 + 一份 surge"预留**，不要贴着实际用量设（P05）
- [ ] **镜像可用性用"能跑起来"判断**，不用"文件在不在"（P06）
- [ ] **探针超时/阈值要按业务毛刺设计**，内部队列默认值要显式调（P07）
- [ ] **探针语义要匹配组件设计**：`/ready` 可能是"有没有活干"，不是"我活着"（P08）
- [ ] **变更后等一个完整窗口**（如 5m rate 窗口）再看结论，否则旧时序会污染判断（P02 复查时踩过）
- [ ] **批量实验之间必须等“告警窗口排空”**（`firing=0` 且 Alertmanager active=0）再注入下一次；用 `T_firing − T0` 是否合理来自检（P31）
- [ ] **`.jsonl` 产物按行解析校验**：`wc -l` 与记录数对得上才算通过，后缀不保证格式（P32）
- [ ] **导出数据集用精确窗口 `[T0, now]`**，不用“回看 N 分钟”——回看会越过 T0 卷进上一轮事件（P33）
- [ ] **导出前等 Alertmanager 真的投递到 ingest**（对比 ingest 计数），否则会导出“空数据集”（P34）
- [ ] **导出窗口 = `[T0, 故障结束 + 余量]`**，不要停在"首次 firing"，否则指标看不到恢复过程（P35）
- [ ] **改配置前先看"运行中的真实配置"**，不要相信仓库里的"人读副本"——它可能早就漂移了（P36）
- [ ] **Windows 上写 `.sh` 必须转 LF**：`bash -n` 若报 "unexpected end of file"，先查行尾（P37）
- [ ] **新指标要先做"契约自检"再给它配规则**：桶单调、`+Inf == _count`、量级合理（P38）
- [ ] **代码放在 ConfigMap 里时，改完必须 `rollout restart`** —— 改 ConfigMap 不会重启进程（P39）
- [ ] **修好指标后要等一个完整 `rate` 窗口再验证**，否则旧序列还在污染聚合（P40）
- [ ] **注入类操作（`kubectl apply` 混沌/清单）必须显式校验**：`apply` 成功 ≠ 故障注入成功；错误不能丢进 `/dev/null`（P41）
- [ ] **NetworkChaos 带 `target` 时**：确认业务是走 Pod IP 还是 Service ClusterIP —— 走 ClusterIP 则 `target` 匹配不上、延迟不生效（P42）
- [ ] **新增告警规则后，同步扩展降噪/RCA 的候选推断 *和* 证据分类** —— 两处都要改，只改一处等于没改（P43）
- [ ] **连续实验间改 `ground_truth` 标签值 = 换序列**，旧序列会在 `rate` 窗口内继续带着旧 GT 出现（P44）

## 10. 面试/写作可用提炼

1. **"配置写了 ≠ 生效，文件生成了 ≠ 数据可用，进程起来了 ≠ 功能正常。"** —— 一条判据串起 8 个问题。
2. **沉默故障最贵的地方在于"它在给下游喂错数据"**：P02/P03 会让后面的降噪与 RCA 学到噪声。
3. **监控系统自己会变成噪声源**（P04/P08）：做 AIOps 之前，先把自己的假告警清干净——这本身就是降噪的第一次实践。

## 变更记录

| 版本 | 日期 | 修改内容 |
|---|---|---|
| v1.0 | 2026-11-01 | 建立沉默故障复盘：8 个问题的现象/根因/定位证据/修法/自查命令、预防清单、面试提炼 |
| v1.1 | 2026-11-02 | 追加 **P31 批量实验告警窗口未排空（方法学污染）**、**P32 matrix.jsonl 缺换行**；问题数 30 → 32 |
| v1.2 | 2026-11-02 | 追加 **P33 数据集导出窗口越过 T0 导致跨轮污染**；问题数 32 → 33 |
| v1.3 | 2026-11-02 | 追加 **P34 导出抢在 Alertmanager 投递之前 → 空数据集**；问题数 33 → 34 |
| v1.4 | 2026-11-03 | 追加 **P35 导出窗口停在首次 firing**、**P36 人读配置与运行配置漂移（差点覆盖可用配置）**、**P37 Windows 写 .sh 带 CRLF**；问题数 34 → 37 |
| v1.5 | 2026-11-03 | 追加 **P38 下游直方图双重累积（P02 孪生、因无消费者潜伏至今）**、**P39 改 ConfigMap 未重启进程**、**P40 旧序列污染聚合**；问题数 37 → 40 |
| v1.6 | 2026-11-03 | 追加 **P41 混沌注入失败被吞掉，脚本照打“已注入”**；问题数 40 → 41 |
| v1.7 | 2026-11-03 | 追加 **P42 NetworkChaos target 与 ClusterIP 不匹配（延迟静默失效）**、**P43 降噪候选未覆盖边类告警**、**P44 改 GT 标签值导致旧序列串轮**；问题数 41 → 44 |
| v1.8 | 2026-11-03 | **P43 当天闭环**：候选集合（边类返回两端）+ pod→service 还原 + 证据分类补齐；候选召回 0.71→**1.00**、Top-1 命中 71.4%→**85.7%** |
| v1.9 | 2026-11-03 | 追加 **P45 边类告警不带判责信息 → 降噪只能猜**（修复：把被调方健康度写进规则表达式）；新增 `33-check-rule-coverage.py` 回归测试；问题数 44 → 45 |
| v2.0 | 2026-11-03 | **P45 当天彻底闭环**：规则加错误闸门 + 降噪层加**边瓶颈截断**；矩阵 **7/7 Top-1 命中、纯度 100%、过度合并 0%** |
| v2.1 | 2026-11-03 | 追加 **P46 RAG 把 prompt 撑大 → 8GB 显存溢出到 CPU、慢 14 倍**（修复：按显存预算限制检索条数与摘录长度）；问题数 45 → 46 |
| v2.2 | 2026-11-03 | 追加 **P47 SSH 嵌套管道被吞**、**P48 PowerShell 读 .ps1 需要 UTF-8 BOM**、**P49 拓扑折叠把 LLM 已答对的结论改错**；问题数 46 → 49 |
| v2.3 | 2026-11-03 | 追加 **P50 实验可复现性差异（F06 三轮零告警、F01 一轮零告警）** —— 单次跑通 ≠ 可复现；问题数 49 → 50 |
| v2.4 | 2026-11-03 | **P50 当天部分闭环**：F06 压力 200MB→360MB + 新增 `ContainerMemoryHigh` 规则（实测 93% firing、注入后 171s 触发）；顺带验证回归测试确实拦住了未登记的新规则 |
| v2.5 | 2026-11-03 | **P50 的 F06 部分验证通过：3/3 全部触发**（修复前 0/3）；全矩阵可评测 20 轮、Top-1 **20/20** |

---

## 11. 追加：第 2 周新踩的两个坑

### P09 混沌对象**存在**不等于**正在注入**；对已存在的对象 `apply` 不会重新注入

| 项 | 内容 |
|---|---|
| **表面正常** | `kubectl apply -f f02-....yaml` 返回 `podchaos ... unchanged`，看起来"注入已下发" |
| **实际故障** | **什么也没发生**——观测期里 firing 告警数一直是 0，白等 4 分钟 |
| **根因** | Chaos Mesh 的 PodChaos 在 `duration` 到期后**只恢复故障、不删除对象**；`status.conditions` 变成 `AllInjected=False / AllRecovered=True`。此时再次 apply，spec 无变化，控制器不会重新注入 |
| **正确姿势** | 先 `kubectl -n chaos-mesh delete podchaos --all`，再 `apply` |
| **判断依据** | 看 `status.conditions` + `containerRecords.phase`，**不要看对象存在与否** |

```bash
kubectl -n chaos-mesh get podchaos -o jsonpath='{.items[*].status.conditions}'
#   AllInjected=True  → 正在注入
#   AllRecovered=True → 已恢复（对象只是历史记录）
```

### P10 可观测性栈**没有监控自己** → "通知发出去没有"只能翻日志

| 项 | 内容 |
|---|---|
| **表面正常** | Grafana 有业务面板、Prometheus 能查指标，看起来监控齐全 |
| **实际故障** | Alertmanager **根本没有被抓取**，`alertmanager_notifications_failed_total` 查不到任何数据；"告警发不出去"这件事在指标层面完全不可见，只能翻日志 |
| **危害** | 监控系统自己的失效是**最隐蔽的失效**——你用它来判断别人有没有问题，却没人判断它 |
| **修法** | 补 4 个 job（alertmanager / loki / grafana / aisre-ingest）+ 3 条链路健康规则（`AlertmanagerNotifyFailing` / `IngestNotReceiving` / `IngestScrapeDown`） |
| **观察口径** | `alertmanager_notifications_total` 带 `integration` 标签会打出 16 条序列（15 个都是 0），必须 `sum by (integration)` 或过滤 `integration="webhook"` |

> 这两条再次印证第 0 节的判据：**"看起来配好了"和"它真的在按你期望的方式工作"是两件事**。

### P11 监控规则**自己制造噪声**：IngestNotReceiving 30 分钟阈值一晚刷出十几条

| 项 | 内容 |
|---|---|
| **表面正常** | 规则表达式写得没错：`time() - ingest_last_receive_timestamp_seconds > 1800` |
| **实际故障** | 实验间隙本来就没有告警 → 一到 30 分钟就触发 → 一晚积累十几条 `IngestNotReceiving` firing 事件 |
| **危害** | 这些噪声**混进了数据集**，把降噪率从 60%+ 拉到 42.9%（自己给自己制造工作量） |
| **修法** | 阈值 30 分钟 → **6 小时**，并要求 `up{job="aisre-ingest"} == 1`（服务本身没被抓到时不要判断"没收到告警"） |
| **教训** | 设计告警时先问："这条规则在**一切正常**的情况下会不会响？" 会响的就是噪声源 |

### P12 降噪指标的定义被校准了三次（每次都先在合成数据上暴露）

| 版本 | 定义 | 实测结果 | 修正 |
|---|---|---|---|
| v1 | 候选根因：有 downstream 取 downstream，否则取自己 service | 一条级联链被算成 payment/order/frontend 三个根因 → **纯度 50%、过度合并 50%** | 沿调用拓扑下钻到最深下游 |
| v2 | 把所有 `service→downstream` 边都当调用边 | `DemoAppDependencyDown(payment→redis)` 把整条链拽到 redis → **根因算成 redis（错误）** | 只有 `DemoAppDownstreamFailure` 才表达调用拓扑；依赖类告警根因就是这个依赖 |
| v3 | ground truth 写 `payment-service`，拓扑节点叫 `payment` | 明明命中却算 **0%（假阴性）** | 服务名归一化（去掉 `-service` 后缀） |

> **这三个版本都不是"写错了"，而是"定义没想清楚"**。指标口径一旦定错，
> 后面所有结论都会偏——所以第一版就在 `_verify/fixture-F13` 合成数据上做对照，
> 再上真实数据。这是本仓库里最值得面试讲的一段。

### P13 重复告警参与"投票"会把根因投歪

| 项 | 内容 |
|---|---|
| **表面正常** | ingest 把每条 webhook 都落盘（重复的标 `duplicate=true`）——这是刻意的，重复次数本身是"告警风暴"信号 |
| **实际故障** | 算降噪/根因时若不折叠重复，同一条告警重复 5 次就有 5 票 |
| **实测影响** | 未折叠时，7 条簇的根因被投票成 **redis**（正确答案 payment）；折叠后正确 |
| **修法** | 分析侧按 `dedup_key` 折叠，保留 `duplicates_collapsed` 计数写进结果（可审计） |

### P14 指标口径错误会刷出"450%"这种不可能的数字

| 项 | 内容 |
|---|---|
| **表面正常** | `根因召回率 = 命中簇数 / 根因数` 看起来很合理 |
| **实际故障** | 基线（每条告警一个簇）下 9 个单例簇有 9 个"命中"，9/2 = **450%** |
| **根因** | 口径错在"簇数"与"根因数"量纲不同——召回应该是"有多少个真根因被发现了" |
| **修法** | 召回 = `|{gt 根因: 至少有一个簇命中}| / |gt 根因|`，基线与方案A 都回到 100% |

> **P13/P14 是同一条教训**：指标一旦定错，方向就会错——所以每次改指标都要拿**基线**跑一遍，
> 看它是否给出"不可能的数字"（>100%、负值、基线比方案还高）。

### P15 用"故障发生后"的告警反推拓扑，会把依赖边误当调用边

| 项 | 内容 |
|---|---|
| **表面正常** | 从告警标签反推拓扑（哪条告警带 downstream 就认为有一条边）能跑，还能算出漂亮的降噪率 |
| **实际故障** | `DemoAppDependencyDown(payment→redis)` 被当成"payment 调用 redis"，于是 `frontend→order→payment` 的整条级联链被**下钻到 redis**，根因算错 |
| **根因** | 拓扑是系统事实，应该从 Deployment env / Service / Endpoints 采集；告警只能反映"故障路径"，不能反映"依赖类型" |
| **修法** | `17-collect-topology.sh` 采集真实拓扑，边分 `call`（下钻用）与 `dependency`（只有依赖类告警才归因到它） |

### P16 一个事件簇的根因是**候选集合**，不是唯一答案

| 项 | 内容 |
|---|---|
| **表面正常** | "一个簇 = 一个根因"的假设在单故障实验里完美成立（F02 全是 100%） |
| **实际故障** | F13 双根因（payment + redis 同时挂）时，症状链同时归因于两者，簇里出现两个候选 → 旧口径算出"纯度 50%、过度合并 50%、召回 50%"，**全是假警报** |
| **根因** | 评分口径要求"唯一答案"，而现实是"候选集合 + 排序" |
| **修法** | 改为集合口径：候选精确率（有没有冤枉别人）、候选召回率（有没有漏）、过度合并=候选里出现 GT 之外的根因；域外告警（自身监控/自检）单列 |

> P15/P16 是同一条教训的两面：**评估口径要贴着现实建模**——拓扑要来自系统事实，
> 根因要允许"多候选"。指标口径错一次，结论就错一次（这已经是本项目的第 6 次校准）。


### P17 症状类告警与"自身失败"类告警**不能同权**

| 项 | 内容 |
|---|---|
| **表面正常** | 把所有告警当成"对根因的一票"，看起来公平 |
| **实际故障** | 症状类告警（HighErrorRate/HighLatency）数量通常远多于自身失败类；同权时**链末端**的服务会因为告警条数多而排第一，而它可能只是"最难受的那个" |
| **修法** | 四路证据分权重：`self=3.0`（ScrapeDown/PodNotReady/重启）> `dependency=2.5` > `call=2.0` > `symptom=1.0`；并输出 `evidence` 计数，让排序**可解释** |
| **实测** | F13 的 INC-002 里 payment(7.0) 排在 redis(5.0) 之前，置信度 0.58 —— 既给出主根因，又诚实表达"这里有两个真根因" |

> 权重不是拍脑袋：它是"**证据有多直接**"的排序。能直接观测到"这个服务自己挂了"的证据，
> 永远比"它上游在报错"更有资格排第一。


### P18 ground truth 标签只打"根因 Pod"不够，要打整条级联链

| 项 | 内容 |
|---|---|
| **表面正常** | 给 payment 的 Pod 打上 `ground-truth=payment-service`，指标体系里确实出现了该标签（4 条序列） |
| **实际故障** | 只有 payment 自己发出的告警带 GT；**order/frontend 发出的链上告警仍然 `gt=-`** |
| **根因** | 告警是从**各自 Pod 的指标**聚合出来的：`sum by (service, ground_truth)` 只会拿到"上报这条指标的 Pod"的标签；order 的指标上没有 payment 的标签 |
| **修法** | 打标时给**整条链上的服务**都打同一个 GT（标签语义 = "这个 Pod 参与了该 ground-truth 事件"）：`18-tag-ground-truth.sh set payment,order,frontend payment-service` |
| **实测** | 修前：链上 4 条告警 `gt=-`；修后：4 条全部 `gt=payment-service`（时间戳 09:59:13） |

> 这也是"标签传播"比"按时间窗事后贴"更可靠的原因：标签跟着指标走，
> 不会把窗口里混进来的自身监控/部署自检告警也标成同一个根因。


### P19 LLM 会把"链上症状"当成候选根因

| 项 | 内容 |
|---|---|
| **表面正常** | LLM 输出的排序里，真根因排第一（payment），Top-1 与规则基线一致 |
| **实际故障** | 它把 `order`、`frontend` 也列为根因（F02 上输出 `payment > order > frontend`），而这两者只是**被波及的中间服务** → 候选精确率 0.333（规则基线 0.5） |
| **根因** | 模型天然倾向"把告警里出现过的服务都列上"；而"根因"与"受影响"是不同概念 |
| **修法（两条）** | ① prompt 明确约束："只给根因，不要给被波及的中间服务"；② 后处理用**真实拓扑**把链上的服务折叠到最深层（我们已有 topology.json，可直接做） |
| **注意** | 幻觉（拓扑之外的服务）实测为 0 —— 因为 prompt 里给了候选服务清单与拓扑，并强制 JSON 输出。**约束式 prompt + 后校验**是让本地小模型可用的关键 |


#### P19-fix 修复结果（prompt 约束 + 拓扑折叠）

| 数据集 | 折叠前排序 | 折叠后排序 | 候选精确率 |
|---|---|---|---|
| F02（单故障） | payment > order | **payment** | 0.500 → **1.000** |
| F13（级联双根因） | payment > redis | payment > redis（未误折叠） | 1.000 → 1.000 |

关键点：折叠**只沿 call 边**。F13 里 `payment -依赖-> redis` 是 dependency 边，
如果也沿它折叠，payment 会被错误地当成 redis 的上游而删掉 —— 这条边界有实测把关。


### P20 ground truth 标签传播覆盖不到"不暴露指标的服务"

| 项 | 内容 |
|---|---|
| **表面正常** | 标签传播在 F02/F13 上工作良好（payment 的告警都带上了 GT） |
| **实际故障** | F14 里给 redis/postgres 打标后，Prometheus 里**查不到**带 GT 的 redis/postgres 序列 —— 因为这两个服务**不暴露 /metrics**（demo-app 只有 frontend/order/payment 三个 Python 服务有埋点） |
| **影响** | 根因是不暴露指标的基础组件时，标签传播无法把答案带到它的告警上（只能通过"依赖失败"类告警间接体现） |
| **修法** | ① 给这类组件加 exporter（redis_exporter / postgres_exporter）并接入 scrape；② 分析侧支持 `--gt` 显式覆盖（本轮已实现） |
| **实测** | F14 用 `--gt payment-service,redis-service,postgres-service` 显式给答案，评测才成立 |

### P21 无 service 标签的平台级告警会被算成 "unknown" 候选，拉低精确率

| 项 | 内容 |
|---|---|
| **表面正常** | `PodNotReady` 是平台级告警，本来就不该有 `service` 标签 |
| **实际故障** | 它进入候选集合后变成 `unknown`，把 F14 规则基线的候选精确率从 1.0 拉低到 **0.75** |
| **根因** | 候选推断只认 `service`/`downstream` 标签，没有用 `pod`/`node` 标签反查归属服务 |
| **修法** | 用拓扑里的 `selector`（`app: payment`）把 `pod` 标签映射回服务；或分析侧按命名空间+Pod 前缀归并 |
| **对比** | 同一份数据上 LLM 直接给出 `payment > postgres > redis`，精确率 1.0 —— 说明"标签不全"时 LLM 的容错更好 |

### P22 实验编排脚本解析 inline labels 出错，产物目录名变脏

| 项 | 内容 |
|---|---|
| **表面正常** | `run-experiment.sh` 从 YAML 里 grep 出 `experiment-id` / `ground-truth` |
| **实际故障** | 当清单写成 inline 形式 `labels: { experiment-id: F14, ground-truth: payment-service }` 时，sed 掉前缀会把后半截一起带走 → 产物目录名变成 `F14,ground-truth:payment-service}-f14a-...` |
| **根因** | 只按前缀截断，没有在逗号/花括号处截断 |
| **修法** | `sed 's/[,}].*//'` 统一截断（已修）；建议以后实验清单统一用块状 labels（见 f13/f14 的写法差异） |


### P23 异常检测不带"最小绝对变化 + 持续性"会疯狂误报

| 项 | 内容 |
|---|---|
| **表面正常** | MAD/EWMA 是标准做法，"z > 3" 看起来是合理阈值 |
| **实际故障** | 第一版在低方差序列（qps 在 6~7 之间抖、p95 在 0.01~0.15 之间抖）上疯狂命中：**一份数据集刷出 85~135 个"异常"**，等于没检出 |
| **根因** | ① 只判"相对偏离"，没有最小绝对变化量；② 没有持续时间要求（等价于告警规则少了 `for`）；③ 故障前序列恒为常数时 mad≈0，z 爆到 2.7e9 |
| **修法** | ① 每序列加 `MIN_ABS_DELTA`；② 连续 ≥3 点才算事件；③ MAD 尺度加下限 `max(1.4826*mad, 0.01*|median|)`；④ 按 (序列,层) 归组后按时间间隔切窗口 |
| **效果** | 111 个原始命中 → **17 个异常事件**（F14），且关键信号（5xx 尖峰、downstream_err、pods_ready 下降）都能保留 |

### P24 日志模板挖掘的"基线窗口"会被采样方式毁掉

| 项 | 内容 |
|---|---|
| **表面正常** | 模板挖掘输出"新增模板 7 个"，看起来发现了新故障模式 |
| **实际故障** | `logs.txt` 是实验**结束后**用 `kubectl logs --tail=200` 抓的，基线段只剩 **3 行** —— 所有模板都是"新增"，`new` 判定失去意义 |
| **根因** | 采样窗口偏斜（时序数据要留足基线） |
| **修法** | 实验前也抓一份基线日志（或把 tail 调大、用 Loki 按时间范围导出）；本文档里保留这个数字，是为了说明**"结论指标"必须检查其输入分布** |
| **不受影响的指标** | ERROR 占比（0% → 4%/30%/93%）与具体模板内容仍然有效，可与告警/指标互相印证 |


### P25 Grafana 供给式数据源不写 uid → 仪表盘全是 "No data"

| 项 | 内容 |
|---|---|
| **表面正常** | Grafana 起来了、数据源列表里有 Prometheus 和 Loki、仪表盘也能打开 |
| **实际故障** | 所有面板显示 **No data** —— 仪表盘打不开是"看不到盘"，这里更隐蔽：盘看得到、图是空的 |
| **根因** | 供给式数据源若不写 `uid`，Grafana 会**随机生成** uid；而仪表盘 JSON 里用 `{"type":"prometheus","uid":"prometheus"}` 按 uid 引用 → 对不上 |
| **修法** | 在 `_grafana-datasources.yml` 显式写 `uid: prometheus` / `uid: loki`，与仪表盘里的引用保持一致 |
| **验证** | `curl -u admin:*** http://<节点IP>:30030/api/datasources` 应回显 uid；再用 datasources proxy 抽查一条查询 |

### P26 `wget -U user:pass` 不是认证 —— 校验脚本会误报"仪表盘没加载"

| 项 | 内容 |
|---|---|
| **表面正常** | 校验脚本"按预期"报了 ✘ 未找到，看起来是仪表盘的问题 |
| **实际故障** | 实际仪表盘**早就加载好了**（Grafana 日志里 `finished to provision dashboards`，容器内 `/var/lib/grafana/dashboards` 三个 JSON 软链齐全） |
| **根因** | busybox wget 的 `-U` 是 **User-Agent**，不是 HTTP Basic Auth → 请求 401 → 校验误判 |
| **修法** | 改用 `curl -u admin:<pass> http://<节点IP>:30030/api/search?type=dash-db`（实测返回 3 个盘） |
| **教训** | 这与 P01（`rule_files` 路径写错导致规则从未加载）是同一类错误：**验证手段本身出错，会让你对"功能是否生效"得出完全相反的结论**。验证脚本必须能"在功能正常时通过"，否则要先用已知正常的状态校准一次 |


### P27 `kubectl delete` 多个类型时，只要有一个类型不存在，**整条命令中止、一个都不删**

| 项 | 内容 |
|---|---|
| **表面正常** | 收尾时执行 `kubectl -n chaos-mesh delete podchaos,networkchaos,dnscheckchaos --ignore-not-found` |
| **实际故障** | 报 `the server doesn't have a resource type "dnscheckchaos"` 后**整条命令中止**，7 个残留混沌对象一个都没删；随后 payment 一直 `ImagePullBackOff` |
| **根因** | kubectl 在解析多类型列表时先做类型校验，遇到未知类型直接失败，不会执行删除 |
| **修法** | **逐类型删除**（一个 for 循环），并对每个类型单独 `--ignore-not-found`；删完必须复核对象数 = 0 |
| **实测** | 逐个删后：6 个 podchaos + 1 个 networkchaos 全部清除，剩余对象 0 |

### P28 pod-failure 恢复后，Pod 可能**仍卡在 pause 镜像**（尤其拉不到该镜像时）

| 项 | 内容 |
|---|---|
| **表面正常** | 混沌对象已删、`AllRecovered=True`，以为业务会自动恢复 |
| **实际故障** | payment 两个 Pod 停在 `0/1 ImagePullBackOff`，容器镜像仍是 `gcr.io/google-containers/pause:latest`（Deployment 模板里明明是 `python:3.12-alpine`）——因为 Chaos 注入时**改的是 Pod 的容器 spec**，恢复依赖控制器把它换回来；而 pause 镜像在国内拉不到，Pod 进 ImagePullBackOff 后恢复流程不一定能把它救回来 |
| **修法** | 删除混沌对象后**再删一次相关 Pod**（`kubectl delete pod -l app=payment`），让 Deployment 用正确的模板重建 |
| **实测** | 删 Pod 后新 Pod 镜像恢复为 `docker.io/library/python:3.12-alpine`，30 秒内 `9/9 ready` |
| **顺带价值** | 这次故障恰好验证了刚建的 Grafana 面板：**"业务 Pod 就绪"从 9 掉到 7、"Pod 重启次数"上升** —— 面板第一眼就能看出问题，不用手敲 PromQL |


### P29 新组件上线时漏加抓取 job → 面板 "No data"（与 P10 同类，第二次踩）

| 项 | 内容 |
|---|---|
| **表面正常** | Grafana 里 "审计记录数 / 已执行动作" 面板已配好，表达式看着没错；`curl http://aisre-agent.aiops.svc:8080/metrics` 也能拿到 `aisre_audit_records_total 9` |
| **实际故障** | 面板显示 **No data** —— Prometheus 里 `aisre_audit_records_total` 序列数 = **0** |
| **根因** | 部署 aisre-agent 时**忘了把它的抓取 job 加进 `scrape_configs`**（之前只加了 alertmanager/loki/grafana/aisre-ingest 四个）。组件暴露了指标，但没人来抓 |
| **修法** | `03-prometheus.yaml` / `_prometheus.yml` 增加 `job_name: aisre-agent` → `targets: ["aisre-agent.aiops.svc:8080"]`；apply + 重启 Prometheus |
| **实测** | 修后：`aisre-agent` target `health=up`；`aisre_audit_records_total = 9`、`aisre_actions_executed_total = 1`；经 Grafana datasource proxy 复核同样有值 |
| **防复发** | `13-verify-e2e.sh` 新增 **⑪ 自监控覆盖**：逐个检查 alertmanager / loki / grafana / aisre-ingest / aisre-agent 是否 `up{job=...}==1` |

> 排障顺序（可复用）：**面板无数据 → ① 表达式在 Prometheus 里查一次 → ② 查 `up{job="..."}` → ③ 查 targets 列表 → ④ 直接打组件 `/metrics`**。
> ①有值②无值 = 面板/数据源问题；①②都无值但④有值 = **没被抓取**（本例）；④也无值 = 组件自身没暴露指标。


### P30 用 `Start-Process` 起的本地服务**没有日志可看**

| 项 | 内容 |
|---|---|
| **表面正常** | `Start-Process ollama serve -WindowStyle Hidden` 服务正常起来，`/api/version` 通、模型能推理 |
| **实际故障** | 想查"模型加载了几次、这次调用为什么慢、有没有回退到 CPU"时，**找不到任何日志**：`%LOCALAPPDATA%\Ollama\server.log` 是 **0 字节**，`server.log` 最后写入时间是几天前 |
| **根因** | 进程的 stdout/stderr 被指向隐藏控制台（没有重定向）；Ollama 自己那份 `server.log` 只在托盘程序启动方式下写 |
| **修法** | `Start-Process -RedirectStandardOutput <out> -RedirectStandardError <err>`（两路都要），并固定到项目目录 `_logs/ollama/`；本仓库封装为 `scripts/27-ollama-logs.ps1 -Restart` |
| **顺带结论** | Ollama 的日志**分两路**：stdout 是 GIN HTTP 访问日志，stderr 是服务端运行日志（模型加载/GPU/告警）—— 只看一路会漏一半 |
| **更结构化的替代** | `/api/chat` 响应体自带 `prompt_eval_count / eval_count / *_duration`；项目脚本已把它写进数据集 JSON 的 `usage` 字段（比翻日志更可靠） |

> 这与 P10（Alertmanager 没被抓取）、P29（新组件漏加抓取 job）是同一主题：**"组件在跑"不等于"组件的行为可被观察"**。
> 差别只是这次发生在开发机上的本地服务，而不是集群里。

### P31 批量实验“背靠背”跑：上一轮的告警还没停，就注入了下一次故障

| 项 | 内容 |
|---|---|
| **表面正常** | `29-run-matrix.sh` 6 个实验全部产出数据集，每个都 `firing_alerts ≥ 1`，汇总表一行不缺，看上去“矩阵跑通了” |
| **实际故障** | F03（注入 order 网络延迟）的数据集里，**唯一一条 firing 事件是 `payment DemoAppScrapeDown`**；F03/F04 的 `metrics.ground_truth_services` 变成 `["payment"]`，与各自的 `ground_truth.json`（order-service / postgres-service）**互相矛盾**；6 个实验的 **Top-1 精确率全是 1.0、MRR 全是 1.000** —— 好得不真实 |
| **根因** | 实验之间只 `sleep 20`，而告警规则是 `rate(...[5m])` + `for: 2m`：**停止注入后告警还要响约 5 分钟**。下一轮开始时上一轮仍在 firing，`count(ALERTS{alertstate="firing"}) ≥ 1` 立刻成立 |
| **识别信号** | ① `T_firing − T0` = **0~1 秒**（真实注入不可能这么快：F02 实测 122s）；② 数据集内事件的服务与本次注入目标**不匹配**；③ 指标好得没有道理 |
| **连锁危害** | ground truth 标签是**跟着告警标签走**的（18 号脚本传播），旧告警带着旧 GT 进入新数据集 → 后续评测**拿旧答案对旧题**，分数虚高且完全自洽，极难发现 |
| **修法** | 每轮注入前加“告警窗口排空闸门” `wait_drain()`：轮询到 **`firing=0` 且 Alertmanager active=0** 才允许注入（上限 420s）；删掉原先的固定 `sleep 20` |
| **实测** | 修后 F01 注入前 `prom_firing=0 / am_active=0`，闸门 15s 通过；`T_firing` 回到分钟级（不再是 0~1s） |

> 这属于**实验方法学**的坑，不是代码 bug：脚本每一行都对、产物文件也都在，
> 但**实验之间互相污染**，导致结论完全不可信。做 AIOps 数据集时，“干净的一轮”比“跑得快”重要得多。

### P32 `matrix.jsonl` 少了换行符 → 从第二条记录起就不是合法 JSONL

| 项 | 内容 |
|---|---|
| **表面正常** | `cat /opt/aisre/datasets/matrix.jsonl` 能看到 6 条完整记录、字段齐全，肉眼像是在正常追加 |
| **实际故障** | `wc -l` = **0**；文件内容其实是 `{...}{...}{...}` **直接拼接**，任何按行解析都会在第一条之后失败 |
| **根因** | 写记录用的是 `json.dump(obj, fh)` —— **它不会自动补换行**；循环里又写了 `print("", end="")`（往 stdout 打空串，与文件无关），换行从来没写进去 |
| **修法** | 显式 `fh.write("\n")`；已有文件用 `json.JSONDecoder().raw_decode()` 循环切分后**重写为一行一条** |
| **实测** | 修复后 `wc -l matrix.jsonl` = 6，`[json.loads(l) for l in open(...)]` 解析出 `['F01'…'F06']` |
| **顺带价值** | 这是“**文件生成了 ≠ 数据可用**”（与 P03 同族）的又一例：`.jsonl` 后缀并不保证它真是 JSONL，**必须有解析校验** |

### P33 数据集导出用“回看 N 分钟” → 窗口越过 T0，把上一轮的事件卷进来

| 项 | 内容 |
|---|---|
| **表面正常** | 矩阵脚本每轮调 `15-export-dataset.sh F01 payment-service 12`，产出 `events.jsonl`、`metrics.json`、`ground_truth.json`，文件齐全、能离线算指标 |
| **实际故障** | F01 注入后**实时轮询 170s 内 `count(ALERTS{alertstate="firing"})` 一直是 0**（脚本自己打了 `✘ 未在 170s 内 firing`），可导出目录里却是 **事件 24 / firing 12** —— 两边直接打架 |
| **根因** | 导出用的是**回看 12 分钟**（`now − 12min`），而上一轮实验刚在几分钟前结束，它的告警事件（`status=firing` 的历史记录）**仍落在窗口内**；实时轮询看的是“**此刻**在不在响”，导出看的是“**窗口内有没有 firing 记录**”——两者根本不是一回事 |
| **为什么难发现** | `events.jsonl` 本身完全合法、字段齐全，只有把它和**实时读数**对照才会发现矛盾；单看产物会以为“F01 触发了 12 条告警” |
| **修法** | `15-export-dataset.sh` **本来就支持精确窗口**（第 4、5 个参数 `FROM`/`TO`）；改成传 `"$T0" "$T_END"`，`window_from` 精确等于注入时刻 |
| **实测** | 改后 `window_from == T0`；导出的 firing 事件与实时轮询的观测一致（F01 恢复为“未触发持续告警”的真实结论） |
| **连带的正确结论** | `pod-kill`（杀一次即重建）**不足以触发 `for: 2m` 的告警** —— 故障太短命。这不是脚本 bug，是**实验设计**要改：要么换成长时故障（`pod-failure`），要么给瞬态故障配瞬时规则 |

> 与 P31 是一对：P31 管“**什么时候开始**下一轮”，P33 管“**往回看多远**”。
> 两个都做对，数据集才只包含本轮故障；只做一个，污染照样进来。

### P34 导出的那一刻，Alertmanager 还没把告警投递过来 → “有告警、数据集却是空的”

| 项 | 内容 |
|---|---|
| **表面正常** | F07（payment 网络分区 5 分钟）轮询到 `T_firing`（注入后 91s），脚本继续导出，`events.jsonl` 生成成功、文件非空判定通过 |
| **实际故障** | 导出的数据集 **事件 0 / firing 0** —— 可同一时刻在 Prometheus 里查 `ALERTS`，明确有 **1 条 firing + 5 条 pending**（`DemoAppHighErrorRate(frontend)` 等） |
| **根因** | **两个时钟不是同一个**：Prometheus 的告警状态机（`pending → firing`）在 Prometheus 里；而 `events.jsonl` 的内容来自 **Alertmanager 的 webhook 投递** → `aisre-ingest`。Alertmanager 有 `group_wait` / `group_interval`，投递**比"状态变成 firing"晚一拍**。脚本一看到 firing 就导出，正好卡在这一拍里 |
| **为什么时有时无** | F01/F02/F06 恰好赶上了（投递快），F07 没赶上 —— **间歇性故障最容易被当成"偶发"放过** |
| **修法** | 基线时记下 `ingest_n`（= `aisre-ingest` 的 `alerts_received_total`），导出前轮询等它**严格变大**（最多 60s），确认"新告警已经落盘"再导出 |
| **排查口诀** | “**Prometheus 里有 ≠ ingest 里有 ≠ 数据集里有**”——三者的时延依次递增，跨系统取数必须等到达 |

> 与 P03（文件有内容但不可用）、P31/P33（窗口串味）同族：**"采集到"这件事本身需要被验证**，
> 而不是假定"我查的时候它就该在"。

### P35 导出窗口停在"首次 firing" → 指标曲线看不到故障演化与恢复

| 项 | 内容 |
|---|---|
| **表面正常** | 修掉 P33 后，导出窗口精确等于 `[T0, now]`，`window_from == T0`，不再串上一轮，看起来已经对了 |
| **实际故障** | 导出**紧跟在"首次 firing"之后**执行，于是指标窗口只有 **F01 = 31s、F06 = 15s** —— 故障持续 90~150s，窗口却只覆盖了开头一小段，**看不到故障峰值，更看不到恢复过程** |
| **根因** | "何时算采完"被定义成了"规则何时变 firing"，但**规则变 firing 只是故障刚开始被看见**，不是故障结束。两者相差可达数分钟 |
| **识别信号** | `metrics.json` 的 `window.to - window.from` 明显小于实验 `duration` |
| **修法** | 窗口改为 **`[T0, T0 + duration + 60s]`**：先把每条实验的时长写进矩阵表（第 5 列），导出前**主动等到故障结束 + 60s 余量**再采集 |
| **连带好处** | 窗口与故障定义对齐后，"恢复用了多久""告警比指标慢几拍"这类结论才有数据支撑 |

> 与 P31/P33/P34 是同一族问题的第 4 个面：**"采样时刻"本身就是被设计出来的**，
> 采早了（P34 没数据）、采偏了（P33 串上一轮）、采短了（P35 看不到恢复），三种都会产出"看起来能算、其实答非所问"的数据集。

### P36 "人读配置"与"运行配置"漂移 —— 按人读文件渲染，差点把能工作的配置改坏

| 项 | 内容 |
|---|---|
| **表面正常** | 仓库里同时有 `manifests/observability/_prometheus.yml`（下划线开头，注释写"人读副本"）和 `03-prometheus.yaml` 里内嵌的 ConfigMap。名字与注释都暗示"两份是一回事" |
| **实际故障** | 我写了渲染脚本，准备以后"以人读文件为唯一事实来源"自动生成部署清单。**渲染完做差异比对时发现**：人读副本里的 `relabel_configs` 缩进是错的（列表项 6 空格、属性 4 空格），`namespaces` 还挂在 `kubernetes_sd_configs` 外面 —— 按它渲染，**正在工作的抓取配置会被换成一份非法配置** |
| **根因** | 两份文件**手工同步**过一段时间，只有部署那份被改对了，人读那份停留在早期版本。**没有任何机制保证两者一致**，注释还让人以为它们一致 |
| **为什么危险** | 这是"改配置"类操作里最隐蔽的一种：**你越"规范化""自动化"，越容易把自己那份陈旧副本推上去，覆盖掉线上唯一正确的东西**。而且 `kubectl apply` 会返回 `configured`，看起来一切正常 |
| **修法** | ① **以运行中的 ConfigMap 为新基准**（`kubectl get cm -o jsonpath` 导出），而不是以仓库副本为基准；② 重建人读文件后再渲染；③ **渲染产物必须与"运行版"做逐行 diff**，只允许出现预期新增行；④ 落地 `scripts/31-sync-prometheus-config.py`（含 `--check`）让两者从此单向生成 |
| **实测** | diff 结果：`prometheus.yml` 只多出 cAdvisor job、`rules.yml` 新增 62 行 / **删除 0 行**，符合预期后才部署；部署后 21 条规则全部加载 |

> 修复动作本身会制造事故 —— 这是本项目里第一个"**为了消灭漂移，差点引入故障**"的例子。
> 判据很朴素：**任何"生成/覆盖"动作，落盘前都要和"当前真实运行的东西"对一次账。**

### P37 Windows 上写 `.sh` 带进 CRLF → bash 报 "unexpected end of file"

| 项 | 内容 |
|---|---|
| **表面正常** | 用 PowerShell `Set-Content` 生成的 `32-apply-prometheus-config.sh`，内容看着完全正常，缩进、`if/fi` 都成对 |
| **实际故障** | 推到节点上 `bash -n` 直接报 `line 106: syntax error: unexpected end of file` —— 明明结构是完整的 |
| **根因** | 文件**只有最后一行是 CRLF**（前面都是 LF，因为大部分内容是从别处复制的），最后一行 `fi` 里的 `` 被当成命令的一部分，于是 bash 认为 `if` 少了个 `fi`，一路找到文件尾报"意外结束"。**只差一个字节，报错位置却在 100 行之外** |
| **识别信号** | `bash -n` 报"unexpected end of file"，但人肉看结构完整 → **先查行尾**：`python3 -c "print(open('x.sh','rb').read().count(b'\r\n'))"` |
| **修法** | 统一转 LF（`raw.replace(b'\r\n', b'\n')`）并去掉 BOM；本项目所有 `.sh` 落盘前都做一次行尾归一 |
| **与 P36 的关系** | 两个都是"**文件本地产物 ≠ 目标环境要求**"：一个是缩进/内容漂移，一个是行尾编码。**跨平台/跨环境交付文本文件，天然需要一次校验步骤** |

> 这一条也是 `bash -n` 存在的意义：**语法检查比"看着对"可靠**。
> 顺序应该是：写 → `bash -n` → 在目标环境验证 → 才执行。

### P38 下游直方图的"累积的累积" —— **P02 的孪生兄弟，因为没人消费它，潜伏了两天**

| 项 | 内容 |
|---|---|
| **表面正常** | `downstream_duration_seconds` 一直正常导出，`/metrics` 里格式合法、字段齐全、数值在涨，看起来是个健康的直方图 |
| **实际故障** | 桶计数**随 le 线性递增**（每个桶固定多 ~63653），且 **`le="+Inf"`(63653) 反而小于 `le="10"`(699955)** —— 直接违反直方图的不变量；`histogram_quantile` 据此把 **10ms 级**的调用算成 **7.25s** |
| **根因** | `observe()` 已经是累积写法（对每个满足 `seconds<=b` 的桶各 `+1` 且不 break），渲染时**又做了一次 `cum += h[i]`** —— 二次累积。**与 P02 是同一个 bug**，当年只修了 `http_request_duration_seconds`（那一条有 `DemoAppHighLatency` 在消费，一改就暴露），**下游这条没有任何规则/面板在用，于是没人发现** |
| **暴露方式** | 2026-11-03 新增 `DemoAppDownstreamLatencyHigh`（按调用边建延迟规则）**第一次消费了这个指标** —— 规则在**完全空闲**下 4 条边全 firing，坏数据当场现形 |
| **判据（可复用）** | ① 桶单调不减；② **`+Inf` 恒等于 `_count`**；③ 用 `sum(rate(_sum))/sum(rate(_count))` 算**均值**和 P95 对照，量级不符就是坏数据（实测均值 18.7ms vs P95 7.25s） |
| **修法** | 去掉二次累积，直接输出 `h[i]`（与 HTTP 直方图保持一致口径）；修完实测 `+Inf == count == 133`、各边 P95 回到 **8~24ms** |

> 这是本项目**最有代表性的一条沉默故障**：
> **"没有被消费的指标"等于"没有被验证的指标"**。
> 它静静地错了两天，直到有人第一次真正用它做决策才暴露 ——
> 而如果第一版规则直接上了生产，它会把一个"永久项目"级别的误报喂给整个 AIOps 链路（与 P02 的后果完全一样）。

### P39 业务代码放在 ConfigMap 里：改了 ConfigMap，**进程并没有重启** → 修复不生效

| 项 | 内容 |
|---|---|
| **表面正常** | 现场 P38 的人（我）改了 `02-app-config.yaml`、跑幂等部署脚本、`kubectl apply` 返回成功、Pod 列表全绿；进 Pod 里 `sed -n` 看文件——**新代码明明已经在里面了** |
| **实际故障** | 指标**一点没变**，还是那套线性桶、`+Inf < le=10`。因为应用是 `python3 /opt/app/app.py` 的**长驻进程**，代码在**启动时**就读进内存了；ConfigMap 是**卷挂载**，文件会被 kubelet 就地更新，但**运行中的进程不会重新加载** |
| **识别信号** | ① `kubectl get pods -o custom-columns=START:.status.startTime` —— Pod 启动时间还是**两天前**；② Pod 里 `grep` 到新代码，但指标行为没变。**"文件是新的"和"进程是新的"是两件事** |
| **修法** | 改 ConfigMap 后显式 `kubectl -n demo-app rollout restart deploy/order deploy/payment deploy/frontend`，等滚动替换完成 |
| **教训** | 这是本项目**第三次**踩"改了配置没生效"（P01 改规则没 reload、P29 新组件漏加抓取、P39 改代码没重启）。三次的形态完全不同，**判据是同一条：不要看文件，要看运行时行为** |

### P40 指标修好了，但旧序列还在 `rate` 窗口里继续污染聚合

| 项 | 内容 |
|---|---|
| **表面正常** | P38 修完、P39 重启完，逐 Pod 看原始桶：**完全正确**（`+Inf == count`，131/133 落在 5ms 内），各边 P95 应该是个位数毫秒 |
| **实际故障** | 聚合口径仍报 `order→payment P95 = 7.55s`，告警**继续 firing**。但同一条边的**均值只有 18.7ms** —— 均值健康、P95 爆表，两者自相矛盾 |
| **根因** | 老 Pod 的时间序列**还没有从 Prometheus 里消失**（staleness 约 5 分钟），`sum by (le) (rate(...[2m]))` 把**旧的坏序列和新的好序列加在一起**；坏序列的 `+Inf` 远小于上界桶，直接把分位数拽到顶部 |
| **识别信号** | **均值与 P95 量级严重不符**（18.7ms vs 7.55s）；逐 Pod 数据正常但聚合异常 → 一定是**有别的序列混进来了** |
| **修法** | 不需要改任何东西，**等一个完整 `rate` 窗口**（实测约 4 分钟后）：告警自行 resolved，最大边 P95 回到 **0.024s** |
| **教训** | 验证"修复是否生效"时，**必须给出窗口排空的时间**，否则会把"旧数据还在"误判成"修复失败"，进而反复回滚、越改越乱 |

> P38→P39→P40 是一条完整的追查链：**指标是坏的 → 修了代码没生效 → 生效了但旧数据还在**。
> 三步里每一步的"表象"都像是"修好了"，每一步都只能靠**换一个角度取数**（换窗口、换聚合粒度、看进程而非文件）才能证伪。

### P41 混沌注入失败被"吞掉"，脚本照样打印"已注入" —— 整轮实验**没有故障却有结论**

| 项 | 内容 |
|---|---|
| **表面正常** | 矩阵脚本打印 `✔ [13:27:36] T0=... 已注入`，接着进入"等 firing"，一轮跑完照常导出数据集。日志通篇绿勾 |
| **实际故障** | 那一轮 **根本没有注入任何故障**：`kubectl -n chaos-mesh get networkchaos,podchaos,stresschaos` 返回 **No resources found**。于是"零告警"被当成"监控盲区"，**差一点写进报告当结论** |
| **根因** | 两件事叠加：① 我给实验 YAML 插入的注释**第二行缩进跑到第 0 列**，把 `duration` 顶出了 `spec` 作用域 → `kubectl apply` 报 `strict decoding error: unknown field "duration"`；② 脚本里写的是 `kubectl apply -f "$FILE" >/dev/null 2>&1` —— **返回码没判、错误输出被丢弃**，失败被完全吞掉，紧跟着就是一句无条件的 `ok "已注入"` |
| **为什么特别危险** | 这是"**沉默故障 + 假阳性结论**"的组合：实验没做，但数据、日志、流程全都正常走完。如果没去 `kubectl get` 那一句，结论会是"F03 注入后零告警 → 监控盲区"，**而真相是"根本没注入"**。它污染的不是数据，是**结论** |
| **识别信号** | ① 日志说"已注入"，但 `kubectl get <chaosType>` 是空的；② 目标 SLI（这里是调用边 P95）**几乎没有变化**（5ms → 25ms 级），与注入参数（800ms）**量级不符** |
| **修法** | ① 实验 YAML 的服务端校验：`kubectl apply --dry-run=server`（一次性跑完全部 7 个，暴露了这个错误）；② 脚本里 **判返回码 + 落盘错误**；③ **apply 后再数一次混沌对象**，为 0 就判失败并跳过本轮；④ 收尾打印剩余对象数 |
| **实测** | 修后日志变成 `✔ T0=... 已注入（chaos 对象 1 个）`，`kubectl get` 能看到 `f03-net-delay-order delay 360s` |

> 这是本项目里**第二次**因为"把错误丢进 `/dev/null`"而差点得出反向结论（第一次是 P33 的"实时轮询 0 条、导出却有 12 条 firing"）。
> 通用做法：**凡是"我发出去了"的动作，都必须有一个"它真的生效了"的独立观测**，
> 且这个观测要能失败 —— 否则 `ok` 只是一个愿望。

### P42 NetworkChaos 的 `target` 按 **Pod IP** 匹配，业务走 **Service ClusterIP** → 延迟"注入了但没生效"

| 项 | 内容 |
|---|---|
| **表面正常** | `kubectl get networkchaos f03-net-delay-order` 的 `status.conditions` 是 **`AllInjected=True / AllRecovered=False`** —— 控制器明确说"已注入"；对象里 `delay: {latency: '800ms'}` 也写得清清楚楚 |
| **实际故障** | 从 order Pod 里直接量 `http://payment.demo-app.svc:8080/`，**实测 11ms**（注入前也是 11ms）。800ms 延迟**完全没有出现**；对应的调用边 P95 只从 5ms 抬到 104ms（那是本来就有的一条长尾），规则因此不触发 |
| **根因** | Chaos Mesh 把 `target` 里的 `app: payment` 解析成 **Pod IP**（10.244.3.47/48）并据此下发 netem 过滤规则；而业务代码调的是 **Service 名**，出向包的目的地址是 **ClusterIP**（10.110.238.46）。**DNAT 发生在包离开 Pod 网络命名空间之后**，所以 netem 那条按 Pod IP 写的规则永远匹配不上 —— 包照常通过，控制器却认为自己注入成功了 |
| **对照实验（关键证据）** | 同一份配置，只改一处：<br>· **带 `target`** → order→payment = **0.010s**（没生效）<br>· **去掉 `target`**（延迟 order 全部出向）→ order→payment = **4.02s**（生效） |
| **为什么难发现** | ① 控制器状态是绿的（`AllInjected=True`）；② 延迟不是"没有影响"，而是**留下一条 100ms 级的尾巴**，看起来"像是生效了、只是幅度小"，很容易被当成"延迟被稀释"而不是"根本没注入"；③ 只有**自己去量一次真实调用**才能证伪 |
| **修法** | 本拓扑里 order 只调 payment 一个下游，因此**去掉 `target`**、直接延迟 order 的全部出向，效果等价且确定生效。若必须精确到某条边，需要改用 `externalTargets` 或按 ClusterIP 匹配 |
| **连带修正** | 矩阵 F03 原先的结论"监控盲区（观测点选错）"**只对了一半**：真相是**故障压根没注入** + 观测点确实没覆盖。已同步修正 [09 报告](09-matrix-report.md) |

> 与 P09（对象存在 ≠ 正在注入）是同一主题的**更深一层**：
> P09 是"对象没重新注入"，P42 是"**对象报注入成功，但规则匹配不到流量**"。
> 判据只有一条：**别信 `status`，去量一次真实请求的耗时。**

### P43 新增了 5 条告警规则，但降噪的"候选推断"不认识它们 → 新告警进不了候选集合

| 项 | 内容 |
|---|---|
| **表面正常** | 修完观测盲区后重跑，F03/F04/F05 **全部产生告警**（13 / 1 / 16 条），矩阵"7/7 可评测"，看起来大功告成 |
| **实际故障** | 评测结果里 **F03 的候选精确率/召回率 = 0.00/0.00、过度合并率 100%、Top-1 未命中**；**F04 的候选精确率 = `-`（一个候选都没有）** |
| **根因** | `16-correlation-baseline.py` 的 `candidate()` 是按**告警名硬编码**的三分类（`DemoAppScrapeDown` / `DemoAppDependencyDown` / `DemoAppDownstreamFailure` + 默认下钻）。新加的 **`DemoAppDownstreamLatencyHigh`（边类）**、**`ContainerCPUHigh`（资源类）**、**`DemoAppTrafficCollapse`（流量类）** 都不在映射里：<br>· 边类告警被当成"下游失败"一路下钻到 **payment/postgres/redis**，而 GT 是**调用方** order<br>· 资源类告警只有 `pod`/`container` 标签、**没有 `service` 标签**，推断直接落到 `unknown` |
| **为什么值得记** | 这是"**观测层扩容后，分析层没跟上**"的典型落差。规则加得越多，**下游分析越容易默默降级**，而且指标会以"看起来还能算"的方式呈现（0.00 而不是报错） |
| **正确修法（待做）** | 候选模型要从"单点服务"升级到**边/资源两类新增语义**：<br>① 边类 → 候选集合 = **{调用方, 被调方}**（本项目已有"候选集合"口径，正好复用）<br>② 资源类 → 用 `pod → service` 映射还原服务名<br>③ 补一条**回归测试**：每新增一个告警规则，必须能在某个数据集上产出非空候选 |
| **修复（2026-11-03 当天完成）** | 把「观测层扩容 → 分析层跟上」补成三件事：<br>① **候选集合**：`candidate()` 升级为 `candidates()`，调用边上的**延迟类**告警返回 `{最深下游, 调用方}`；<br>② **pod → service 还原**：资源类告警没有 `service` 标签，用「拓扑节点最长前缀匹配 → 否则取第一段」还原；<br>③ **证据分类补齐**：`DemoAppDownstreamLatencyHigh` → `call`、`ContainerCPUHigh` → `self`、`DemoAppHighErrorRateFast` / `DemoAppTrafficCollapse` → `symptom`（原先全落 `other` 0.5，**规则加了等于白加**） |
| **修复后实测** | 候选**召回率 0.71 → 1.00**（每个 GT 都进了候选集合）、**Top-1 命中 71.4% → 85.7%**（F04 从「零候选」变成 1.00/1.00）、候选精确率 0.83 → 0.81（轻微下降）、过度合并 14.3% → 21.4% |
| **踩到的两个细节** | ① 一度把「调用方」加给**所有**调用边告警 → 级联场景把受害者 frontend/order 也算候选，过度合并冲到 **64.3%**（精确率 0.55）→ 收窄为**只对延迟类**生效；② `edges` 是 **dict{from: to}**、`dep_edges` 才是元组集合，两者形状不同，判据不能混用（第一次写错导致改动看起来没生效） |
| **仍存的局限（未粉饰）** | **F03 的 Top-1 仍是 miss**：F03 注入点是 order 的出向路径（GT=order），但告警集合里 payment 侧症状（自身流量塌陷等）权重更高，模型排 payment 第一。**候选集合已包含 order（召回 1.0）**，但「谁是第一个」需要**被调方自身是否健康**这条额外证据才能区分：<br>· 被调方自身延迟/错误率正常 ⇒ 责任在调用方的出向路径（本例应判 order）<br>· 被调方自己也不健康 ⇒ 顺链下沉（F05 那种）<br>事件流里目前**没有**这条信息 → 记为下一步 |

### P44 `ground_truth` 标签**改了值 = 换了一条新序列**，旧序列带着上一轮的答案继续出现

| 项 | 内容 |
|---|---|
| **表面正常** | 每轮实验都会 `18-tag-ground-truth.sh set <链路> <本轮根因>`，导出的事件里也**确实**带着 `ground_truth` 字段，标签传播链路看起来工作正常 |
| **实际故障** | **F04**（根因 postgres-service）的事件里，`ground_truth` 是 **`order-service`**（那是 **F03** 的答案）；**F05**（根因 payment-service）的事件里混进了 **8 条 `order-service`**。评测因此把 F04 的 GT 认成 order、F05 认成 `order,payment`，**分数整体算错** |
| **根因** | Prometheus 的标签是**序列身份的一部分**：把 Pod 的 `ground_truth` 从 `order-service` 改成 `postgres-service`，不是"修改"而**新增**一条序列；**旧序列还会在 staleness 窗口（约 5 分钟）内继续被 `rate()` 取到**。而告警规则普遍用 `rate(...[5m])`，正好把上一轮的旧标签一起算进来 |
| **识别信号** | 数据集里 `ground_truth` 出现**多个取值**，且其中一个是**上一轮**的根因 |
| **修法** | 不去改标签传播机制（它本身是对的），而是**明确"权威答案来自矩阵定义"**：评测时把矩阵里的 `ground_truth` 通过 `--gt` 传给降噪脚本，**覆盖**事件标签（`--gt` 本来就是最高优先级）。实测修正后 F04 → postgres、F05 → payment，与实验定义一致 |
| **顺带结论** | 这条也解释了为什么"标签传播"不能单独当权威：**它是"数据自带答案"，但数据带的是"那一刻的答案"**。做离线数据集时，**实验定义的 GT 才是真相**，标签传播是佐证 |

> P42–P44 是同一轮里"修好观测层之后"冒出来的三个新问题，正好构成一条链：
> **故障没真注入（P42）→ 注入后新告警进了但分析层不认识（P43）→ 分析用的答案还被上一轮污染（P44）**。
> 每修一层，下一层的缺口才看得见 —— 这就是"端到端"和"装好组件"的区别。

### P45 边类告警**不带判责信息**，降噪层只能"猜被调方还是调用方"

| 项 | 内容 |
|---|---|
| **表面正常** | `DemoAppDownstreamLatencyHigh` 正常 firing，标签齐全（`service=order`、`downstream=payment`），候选集合也包含了两端 `{order, payment}` —— 召回率做到 1.00，指标一片向好 |
| **实际故障** | **Top-1 指向了错的端点**：F03 的注入点在 **order 的出向路径**（GT=order），但模型把 **payment** 排第一。因为告警只说了"这条边慢"，**完全没说被调方是不是也慢** |
| **根因** | 判责所需的信息（被调方自身健不健康）**根本不在告警里**。下游拿到 `service/downstream` 两个标签，无法区分：<br>· A 的出向路径慢（被调方健康）→ 责任在 **A**<br>· B 自己慢（被调方不健康）→ 责任在 **B**<br>两种情况的告警长得**一模一样** |
| **修法（把判责前移到规则层）** | 在规则表达式里加一个"被调方健康"的条件：<br>`边 P95 > 0.5s` **AND** `被调方自身服务端 P95 < 1s`（用 `label_replace` 把被调方 `service` 复制成 `downstream` 再 `and on(downstream)`）。<br>这样"这条告警出现"本身就**蕴含**了"被调方健康"，降噪层据此把候选收敛为**调用方**。<br>被调方也慢、或分区导致它根本没有请求（`rate=0 → histogram_quantile=NaN`，右侧无序列）时，告警**不出现** —— 那种情况本就该由下游失败告警负责 |
| **实测** | ① 簇纯度 78.6% → **85.7%**、候选精确率 0.81 → **0.86**、MRR 0.857 → **0.893**，召回保持 **1.00**；<br>② F05（payment 分区，被调方确实不健康）的边延迟告警从 **5 条降到 1 条**；<br>③ F03（被调方健康）的边延迟告警**保留** —— 这正是要归给调用方的场景 |
| **第二处修正（边瓶颈截断，降噪层）** | 上面那道闸门解决了"该不该告警"，但没解决"**症状沿链下沉**"的系统性偏差：级联症状（frontend 错误率、frontend→order 失败…）会一路下沉到**链尾 payment**，把 payment 堆到 7.0，真正的瓶颈 order 只有 2.0。修正：既然边告警已证明"被调方健康"，**穿过这条边的症状就应截断在该边的调用方**（`self` 类证据不截断，避免抹掉真根因） |
| **第三处修正（错误闸门，规则层）** | 边延迟告警再加"**这条边不能同时在报错**"。必要性：F05（分区）**恢复期**被调方一度恢复服务，2m 窗口里旧的高延迟让边告警又 firing 一次，把 F05 归因带偏到 order。加闸门后该告警在 F05 里彻底不出现 |
| **最终实测（7/7）** | 簇纯度 **100%**、过度合并 **0%**、候选精确率/召回率 **1.00/1.00**、Top-1 精确率 **1.00**、MRR **1.000**、**Top-1 命中率 100%（7/7）**。行为验证：F03 保留 1 条边延迟告警（被调方健康）、F05 为 0 条（边在报错） |

> 这条的普适教训：**分析层的歧义，要尽量在其上游（规则/指标定义）用证据消掉，而不是在下游用启发式去猜。**
> 上游多写一个 PromQL 条件，下游就少一堆"看起来还能算、其实在猜"的逻辑。

### P46 RAG 把 prompt 撑大 → 8GB 显存溢出到 CPU → **慢 14 倍**（而且没有任何报错）

| 项 | 内容 |
|---|---|
| **表面正常** | 给 RCA 接上 RAG（检索本项目 45 条踩坑记录）后，**答案变对了**：F03 的 Top-1 从 `payment`（错）变成 `order`（对，GT）—— 检索命中的正是 P45「边类告警不带判责信息」。端到端**功能完全正常**，日志无任何告警 |
| **实际故障** | 推理耗时从 **11.2s 暴涨到 159.5s（14 倍）**。`usage` 里 `eval_count=156`、`eval_duration=141s` ⇒ **生成速度只有 1.1 tokens/s**（正常约 14 tokens/s） |
| **根因** | 检索把 prompt 从 **2523 字符撑到 5396 字符**（≈2842 tokens）。7B Q4 权重本身占 4.36GB，**8GB 显存**上再放大 KV cache 就装不下 → Ollama 自动把部分层**卸载到 CPU**；GPU 只干一部分活，速度掉一个数量级。**Ollama 不会为此报错**，只是"变慢" |
| **识别信号** | ① `usage.eval_duration / eval_count` 得到的 tokens/s 突然从两位数掉到个位数；② `load_duration` 与 `prompt_eval_duration` 正常、只有 `eval_duration` 异常大；③ **答案质量没降、只是慢** —— 容易被当成"模型就这样" |
| **修法** | 按**显存预算**约束检索量：`--rag-top 3 → 2`、`--rag-excerpt 900 → 350`（每条历史案例只喂摘要），prompt 回到 3648 字符 |
| **实测（同一数据集 F03）** | 非 RAG：2523 字符 / **11.2s** / Top-1 **payment（错）**<br>RAG 重：5396 字符 / **159.5s** / Top-1 order（对）<br>**RAG 轻：3648 字符 / 14.5s / Top-1 order（对）** ⇒ 只多 **3.3 秒**就换来正确答案 |
| **顺带结论** | 这条与 P38 是同一主题的另一面：**"能跑"和"跑得动"是两件事**。RAG 的正确性问题容易看见，**性能退化却悄无声息** —— 所以 LLM 链路也必须记录 `tokens/s` 这类运行指标，而不是只看答案对不对 |

> 通用做法：**给本地小显存模型加任何"更多上下文"的能力（RAG / few-shot / 长历史）时，
> 都要先量 `tokens/s`**。8GB 卡上，prompt 从 2.5k 字符涨到 5k 字符就足以触发 CPU 卸载。

### P47 远程命令里再套管道/引号 → **整段被吞掉，返回空**

| 项 | 内容 |
|---|---|
| **表面正常** | 同步脚本里写 `ssh <host> 'kubectl ... -- sh -c "wget -qO- URL" 2>/dev/null | grep -E "^aisre_"'`，人肉在终端里跑**完全正常**，能列出 3 条指标 |
| **实际故障** | 同一个字符串放进 PowerShell 脚本、由 `& ssh.exe @opts $host $cmd` 传出去时，**返回空**：审计链同步成功（那条命令简单），但 agent/ingest 指标全是 0 项，`metrics.json` 只剩 `synced_at` |
| **根因** | 这条命令要穿过 **三层** 解析：PowerShell（单引号字面量）→ ssh（把参数拼成远端 shell 命令）→ 远端 bash（`sh -c "..."` 里还有一层引号 + 管道）。**任何一层的引号规则不同，管道就会被某一层吃掉**；而且失败是**静默**的（`2>$null` 把错误也丢了） |
| **识别信号** | ① 同一个命令在终端能跑、在脚本里返回空；② 输出里只有"简单命令"的结果；③ **不能靠 `2>$null` 判断成败**（它把证据也丢了） |
| **修法** | **远程命令一律不带管道**：`kubectl ... -- wget -qO- URL` 只取原始文本，**过滤/解析全部放回本地**（PowerShell 的 `Where-Object` / `ConvertFrom-Json`）。远程一次只做一件事 |
| **实测** | 改后 `agent 指标 3 项 / ingest 指标 9 项 / 集群 5 项`，全部拿到；`rules_loaded` 也从不正确的 6 变成正确的 **21** |

> 与 P41（注入失败被吞）同源：**跨层传递时，失败往往是静默的**。
> 判据：凡是"发出去的命令"，都要能**证伪**它到底执行了没有 —— 最省事的办法就是让它只做最简单的一件事。

### P48 PowerShell 5.1 读 `.ps1` **必须带 UTF-8 BOM**，否则中文变乱码、语法直接报错

| 项 | 内容 |
|---|---|
| **表面正常** | 用 Python（或任何"标准 UTF-8 无 BOM"工具）写出一个 `.ps1`，文件内容肉眼完全正常、`Get-Content` 也显示正常 |
| **实际故障** | `powershell -File xxx.ps1` 报 **`The string is missing the terminator`**，报错位置在文件末尾的 `Say "完成"` —— 中文串被解析成乱码（`Say "瀹屾垚"`）后把引号规则搞崩了 |
| **根因** | **Windows PowerShell 5.1 默认按系统 ANSI 代码页（中文 Windows = GBK）读取无 BOM 的 `.ps1`**。文件其实是 UTF-8，于是中文字节被当 GBK 解释 → 乱码 → 乱码里可能包含引号/反斜杠等**具有语法意义的字符** → 解析失败。而 PowerShell **7+** 默认 UTF-8，所以"在我机器上没问题" |
| **识别信号** | ① 报错信息里的中文是乱码；② 报错位置莫名其妙（在最后一行）；③ 同样的文件用 `pwsh`(7) 跑正常、用 `powershell`(5.1) 跑失败 |
| **修法** | 写 `.ps1` 时用 **`encoding="utf-8-sig"`**（带 BOM）。本项目 `scripts/37-sync-agent-logs.ps1` 就是这么生成的；对比 `38-dashboard.py`（`.py` 不需要 BOM，Python 3 默认按 UTF-8 读源码） |
| **实测** | 加 BOM 后 `powershell -File` 立即正常；文件大小从 4981 → 4986 字节（多出的 3 字节就是 BOM） |

> 与 P37（Windows 写 `.sh` 带 CRLF）是**一对镜像问题**：
> 两边都在"跨平台交付文本"上翻车 —— `.sh` 要 **LF 且不要 BOM**，`.ps1` 要 **BOM**。
> 判据：**交付脚本前，先确认目标解释器期望的编码/行尾**，不要用"文件看起来对不对"来判断。

### P49 下游后处理（拓扑折叠）**无条件折叠上游** → 把 LLM 已经答对的结论改错

| 项 | 内容 |
|---|---|
| **表面正常** | RCA 流程跑得很顺：LLM 返回结构化 JSON、幻觉校验通过、拓扑折叠"折叠掉上游症状"、结果落盘，每一步都有日志 |
| **实际故障** | **LLM 答对了，后处理把它改错了**：F03（注入 order 出向延迟，GT=order）里 LLM 给出 `order 0.9 > payment 0.6`；折叠逻辑随后把 `order` 当作"上游症状"丢掉，最终输出变成 `payment`（**错误**） |
| **根因** | `fold_root_causes()` 的判据是"只要 a 沿 call 边能到达 b，就丢掉 a"——**无条件**。它默认"下游一定是根因"，而这条假设在**边/出向路径类故障**上不成立（正是 P45 在规则层修掉的同一个偏差，只是这里出现在后处理里） |
| **为什么难发现** | ① 折叠本身是"设计好的功能"，日志还打印"折叠掉上游症状 ['order']"，**看起来是在正常工作**；② 原始答案存在 `llm_raw` 里，但**下游消费的是 `parsed`（折叠后）**，于是"看原始输出是对的、看最终结论是错的"；③ 只有**把两者并排看**才会发现 |
| **修法** | 加**置信度守卫**：只有当上游**不比下游更可信**（`conf(a) <= conf(b)`）时才折叠它。即"折叠"从"无条件的规则"降级为"**低置信度时的去噪手段**" |
| **实测** | 修后同一数据集重跑（RAG 轻量版）：输出 `order(0.9) > payment(0.6)`，**未被折叠**，Top-1 正确；耗时 6.9s、50 tok/s |

> 这条最值得记的是它的**形态**：错误不在"没有答案"，而在"**答案被一个看起来合理的后处理改掉了**"。
> 通用做法：**后处理必须能被单独关闭/对照** —— 本项目把 `llm_raw`（模型原始输出）与 `parsed`（后处理结果）**都**落盘，才使得这个 bug 一小时内被抓出来。

### P50 单次"跑通了"不等于**可复现** —— 重复 3 轮后，F06 是 **0/3**

| 项 | 内容 |
|---|---|
| **表面正常** | 故障矩阵每个实验此前都"跑通过"：F06（payment 内存压力 200MB）在单轮里产生过 2 条 firing 告警、生成过数据集、进入过评测。看起来和其它实验一样可用 |
| **实际故障** | 把它跑 3 遍：**F06 三轮全部零告警**（`events=0 firing=0`）—— 三轮都**不可评测**。而 F01（pod-kill）也有一轮零告警。也就是说：**这两个实验的"能触发告警"是碰运气**，不是稳定性质 |
| **根因** | 两类原因叠加：<br>· **F06**：内存压力 200MB 面对 384Mi 的 limit **不足以稳定触发 OOMKilled**，是否重启取决于当时的内存碎片/GC 时机 → 有时触发、有时不触发；<br>· **F01**：pod-kill 是**瞬时**故障（杀一次就重建），能否触发 `for` 门限取决于重建快慢 → 本身就在临界点上（这条在 P33 里已经从另一个角度记过一次） |
| **为什么单轮发现不了** | 单轮跑一次"成功了"会让人以为这个实验**设计正确**。而"偶尔不触发"和"设计上就不该触发"在**一次样本**里长得一模一样 —— 必须重复才能区分 |
| **识别信号** | 重复 N 轮后，同一实验的 `firing` 轮数 < N；对应数据集里 `events.jsonl` 为空（**不是评测脚本报错**，而是压根没有输入） |
| **修法（分两类）** | ① **F06**：见下方「F06 修复」；② **F01**：接受它是瞬时故障，改用瞬时规则（不带 `for`）来观测，或改成长时故障。③ **流程上**：汇总脚本必须把「无告警轮次」**单独计数并打印**，不能静默跳过（本脚本第一版就是静默跳过的，差点把 F06 的问题藏起来） |
| **F06 修复：先量化，再调参** | 用 cAdvisor 量出真实数字：payment 应用自身仅 **~26–30 MiB**，limit **384 MiB**，而压力只给 **200MB** ⇒ 合计 230MiB **远低于** limit ⇒ 压不到 OOM，是否触发完全看应用自身抖动。**改法两处**：<br>① 压力 **200MB → 360MB**；② **新增规则 `ContainerMemoryHigh`**（工作集 / limit > 85%，`for: 2m`）—— 不再赌「是否恰好被 OOMKilled」，直接盯**占比**。<br>第一次改到 320MB 实测只有 **83.5%（差一点没过 85%）**，二次校准到 360MB 后实测 **93.2%/93.5%**、`ContainerMemoryHigh` **两条都 firing**（注入后 171s） |
| **顺带验证了回归测试的价值** | 新增 `ContainerMemoryHigh` 后**故意先跑** `33-check-rule-coverage.py`，它立刻报 `✘ 规则未登记证据类型: ContainerMemoryHigh`（业务类新规则必须同时登记 `evidence_type()` 与 `candidates()`）。补登记后测试转绿 —— **这条守卫从"设计出来"到"真的拦住一次"闭环了** |
| **修复后实测（F06 连跑 3 次）** | **3/3 全部触发**：2208 轮 5 事件/3 firing、2216 轮 4/2、2223 轮 4/2；内存稳定在 **93.2%/93.5%**、`ContainerMemoryHigh` firing、注入后 **171s** 触发。F06 从"0/3 不可评测"变成 **n=3、纯度 100%、过度合并 0%、Top-1 3/3** |
| **修复前后对比（全矩阵）** | 修复前：可评测 **17** 轮、另有 4 轮无告警；修复后：可评测 **20** 轮、**Top-1 20/20（100%）**、纯度 100%、过度合并 0% |
| **仍未解决** | **F01 仍有 1 轮无告警**（pod-kill 是瞬时故障，卡在 `for` 门限临界点）。这条**接受**为已知特性 —— 它说明"瞬时故障需要瞬时规则"，已列入下一步 |

> 这条与前面的"沉默故障"是**镜像关系**：
> 前面 49 条是"看起来在工作、其实是坏的"；P50 是"**看起来能触发、其实不稳定**"。
> 共同点依旧是那条判据：**单一观察不足以支撑结论** —— 要么换角度取数，要么重复多次。
