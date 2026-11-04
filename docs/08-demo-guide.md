# 端到端自愈闭环 · 演示指南（3~5 分钟录屏脚本）

**中文** | [English](en/08-demo-guide.md)

| 项 | 内容 |
|---|---|
| 用途 | 面试/汇报时的演示脚本：注入 → 降噪 → LLM RCA → 策略校验 → 自动执行 → SLI 恢复 → 审计留痕 |
| 驱动脚本 | `scripts/28-selfheal-loop.sh`（两阶段，可重复执行） |
| 观察窗口 | Grafana 三个盘（总览 / 业务 SLI / AIOps 自愈链路）+ Prometheus Alerts + Alertmanager |
| 实测时长 | 从注入到完全恢复约 **7 分钟**（其中 5 分钟是 rate 窗口残留） |
| 关联文档 | [02 集群访问](02-cluster-access.md) §5.17 · [03 本地大模型](03-local-llm.md) §6–7 · [05 项目汇报](05-project-report.md) |

---

## 0. 演示前检查（约 1 分钟）

```bash
# 集群健康（应 5/5、9/9）
kubectl get nodes --no-headers | awk '$2=="Ready"{c++} END{print c"/5"}'
kubectl -n demo-app get pods --no-headers | awk '{split($2,a,"/"); if(a[1]==a[2]) c++} END{print c+0"/9"}'
# 混沌对象必须为 0（否则 apply 不会重新注入 —— P09）
kubectl -n chaos-mesh get podchaos,networkchaos --no-headers | wc -l
# 三个 Grafana 盘在线
curl -s -u admin:aisre-lab-admin 'http://127.0.0.1:30030/api/search?type=dash-db' | python3 -c "import json,sys;print(len(json.load(sys.stdin)),'个盘')"
```

**讲解词**："演示前先确认三件事：集群健康、没有残留的混沌对象、观测窗口在线。"

## 1. 注入故障（阶段一，约 2 分钟）

```bash
bash /opt/aisre/scripts/28-selfheal-loop.sh --stage prepare --target payment --duration 90s
```

脚本会依次**自动**做：清混沌 → 给 payment/order/frontend 打 `ground-truth` 标签 → 记基线 →
注入 `pod-failure` → 轮询等待告警 → 导出数据集 → 算降噪与根因候选。

**讲解词要点**：
- "注入前先打 ground truth 标签，让答案随数据一起流动，而不是事后按时间窗贴"
- "观察窗口里能看到 pending 先出现（Prometheus 独有），过了 `for: 2m` 才变 firing"

## 2. 降噪与根因（阶段一末尾 + 开发机）

```bash
# 阶段一末尾会打印：规则基线的 Top-1
# 开发机侧跑本地 LLM RCA（把数据集拷回本地后）
python3 scripts/19-rca-llm.py datasets/<数据集> --topology topology/topology.json --model qwen2.5:7b
python3 scripts/20-eval-rca.py datasets/<数据集> --topology topology/topology.json
```

**讲解词要点**：
- "降噪把 N 条告警收敛成 K 个事件簇；拓扑折叠把链上的症状折到根因"
- "**这一步实测出现过规则基线选错、LLM 选对**：规则基线跨簇取最高分时选了 `redis`（两条依赖证据 5.0），
  而 LLM 把 `payment` 排在第一位（自身失败证据权重更高）—— 正确答案是 payment"
- "幻觉校验 0：因为 prompt 给了候选服务清单 + 真实拓扑，且强制 JSON 输出"

## 3. 策略校验（阶段二开头）

```bash
bash /opt/aisre/scripts/28-selfheal-loop.sh --stage heal \
     --dataset /opt/aisre/datasets/<数据集> --root-cause payment
```

**讲解词要点**：
- "根因传进去后，先走**策略引擎**：8 条 check 逐条过（动作分级 / 白名单 / 冷却期 / 爆炸半径 /
  频率限制 / 幂等 / 前置条件 / 干跑）"
- "演示时我会特意演一次**被拦下**的用例（比如 L3 缩容到 0 或越界命名空间），让你看到护栏真的在工作"

## 4. 自动执行与恢复（阶段二主体）

**讲解词要点**：
- "执行的是 `kubectl rollout restart` 等价动作（maxUnavailable=0），观察窗口里 ready 会先涨到 11/9
  —— 那是滚动重启期间新旧 Pod 共存，服务不断"
- "**5xx 会先回到 0，但告警还在响** —— 这不是 bug：`rate(...[5m])` 有 5 分钟窗口，
  SLI 恢复后要等窗口清空告警才 resolved（这段正好用来讲'为什么告警比指标慢一拍'）"

## 5. 审计留痕（阶段二末尾）

```bash
kubectl -n aiops exec deploy/aisre-agent -- wget -qO- http://127.0.0.1:8080/audit/verify
kubectl -n aiops exec deploy/aisre-agent -- cat /data/audit.jsonl | python3 -c "
import json,sys
rows=[json.loads(l) for l in sys.stdin if l.strip()]
prev='0'*64; bad=[]
for i,r in enumerate(rows,1):
    if r['prev_hash']!=prev: bad.append(i)
    prev=r['hash']
print('记录=%d 链式=%s' % (len(rows), 'OK' if not bad else '异常@%s'%bad))"
```

**讲解词要点**：
- "每条动作都进审计链：`hash = sha256(prev_hash + 内容)`，任何人改了历史记录链就断"
- "注意：**回滚不会删除审计** —— 审计的价值就在于'做过什么必须留痕'"

---

## 6. 实测时间线（可直接作为录屏旁白）

```
20:19:25  清理混沌对象 → 0 个
20:19:26  打 ground truth 标签（payment,order,frontend = payment-service）
20:19:27  基线：ready=9/9  5xx=0  活动告警=0  ingest=241
20:19:27  T0 注入 pod-failure(payment, 90s)
20:20:16  pending=4          ← 注入后 49s 进入 PENDING（只存在于 Prometheus）
20:20:31  ready=7/9          ← payment 两副本不可用（Pod 状态比注入晚约 1 分钟）
20:21:19  firing=1  AM=1     ← T_firing，注入后 112s（pending 满 for: 2m）
20:21:20  导出数据集 → PAYMENT-20261102-2021
20:21:20  降噪：5 firing → 4 事件簇（降噪率 20%）；规则基线 Top-1 = redis ← **选错了**
20:2?:??  开发机 LLM RCA：payment(0.9) > redis(0.7)  ← **选对了**（GT=payment-service）
20:22:48  策略校验：allow=True，8 条 check 全过
20:22:49  T_exec 执行滚动重启 → restartedAt=20:22:50
20:23:16  ready=11/9         ← 滚动重启 surge（新旧 Pod 共存，服务不断）
20:23:57  ready=9/9
20:24:17  firing=4  5xx=0    ← SLI 已恢复但告警仍在窗口残留期
20:26:19  T_recover：firing=0 AM=0   ← 5 分钟 rate 窗口清空后告警归零
20:26:22  清理 GT 标签与混沌对象 → 0 个
审计：11 条记录，链式校验 OK，决策分布 {denied:6, allowed:3, executed:2}
```

**闭环耗时**：注入 → 告警 112s；策略 → 执行 → 恢复 210s（20:22:49 → 20:26:19）。
**总计**：约 7 分钟（含 5 分钟 rate 窗口等待）。

## 7. 演示时最容易被打断的三个提问

| 提问 | 应答要点 |
|---|---|
| "为什么 ready 变成 11/9？" | 滚动重启的 surge：`maxSurge=1/maxUnavailable=0`，新旧 Pod 短暂共存，服务不间断 |
| "指标已经好了，为什么告警还在响？" | 规则用 `rate(...[5m])` 与 `for: 2m`，是**故意**的滞后：避免抖动误报，代价是恢复慢一拍 |
| "如果 LLM 说错了会怎样？" | ① prompt 约束候选集合 + 拓扑折叠；② 输出后校验服务是否在拓扑内（幻觉检测）；③ **策略引擎仍然要过 8 条校验**；④ 最坏情况也只是重启一个 Deployment，且全程有审计可回滚 |
