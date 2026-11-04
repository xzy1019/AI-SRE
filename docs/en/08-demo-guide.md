[中文](../08-demo-guide.md) | **English**

> ⚠️ Machine-translated by `qwen2.5:7b` — review before trusting.

# End-to-End Self-healing Loop · Demonstration Guide (3-5 Minute Screen Recording Script)

| Item | Content |
|---|---|
| Purpose | Demonstration workflow for demos and presentations: injection → denoising → LLM RCA → policy validation → automatic execution → SLI recovery → audit logging |
| Driving Script | `scripts/28-selfheal-loop.sh` (two-phase, executable multiple times) |
| Observation Window | Grafana three dashboards (Overview / Business SLI / AIOps Self-healing Link) + Prometheus Alerts + Alertmanager |
| Actual Duration | Approximately **7 minutes** from injection to full recovery (with 5 minutes of rate window residual) |
| Related Documentation | [02 Cluster Access](02-cluster-access.md) §5.17 · [03 Local Large Model](03-local-llm.md) §6-7 · [05 Project Report](05-project-report.md) |

## 0. Pre-Demo Checks (~1 minute)

```bash
# 集群健康（应 5/5、9/9）
kubectl get nodes --no-headers | awk '$2=="Ready"{c++} END{print c"/5"}'
kubectl -n demo-app get pods --no-headers | awk '{split($2,a,"/"); if(a[1]==a[2]) c++} END{print c+0"/9"}'
# 混沌对象必须为 0（否则 apply 不会重新注入 —— P09）
kubectl -n chaos-mesh get podchaos,networkchaos --no-headers | wc -l
# 三个 Grafana 盘在线
curl -s -u admin:aisre-lab-admin 'http://127.0.0.1:30030/api/search?type=dash-db' | python3 -c "import json,sys;print(len(json.load(sys.stdin)),'个盘')"
```

**Notes:** "Before the demo, make sure three things: cluster health, no residual chaos objects, and the observability window is online."

## 1. Inject Faults (Phase One, ~2 minutes)

```bash
bash /opt/aisre/scripts/28-selfheal-loop.sh --stage prepare --target payment --duration 90s
```

The script will **automatically** do the following in sequence: clear chaos → label `payment/order/frontend` with `ground-truth` tags → establish baseline → inject `pod-failure` → poll and wait for alerts → export dataset → calculate denoising and RCA candidates.

**Notes**:
- "Label with ground-truth tags before injection to ensure the answer flows with the data, not applied retrospectively with a time window"
- "In the observation window, you can see `pending` first (unique to Prometheus), then it changes to `firing` after `for: 2m`"

## 2. Denoising and Root Cause (End of Phase One + Developer Machine)

```bash
# 阶段一末尾会打印：规则基线的 Top-1
# 开发机侧跑本地 LLM RCA（把数据集拷回本地后）
python3 scripts/19-rca-llm.py datasets/<数据集> --topology topology/topology.json --model qwen2.5:7b
python3 scripts/20-eval-rca.py datasets/<数据集> --topology topology/topology.json
```

**Notes**:
- "Denoising converges N alarm signals into K incident clusters; topology folding folds the symptoms on the chain to the root cause."
- "In this step, a real test showed that the rule baseline was selected incorrectly while the LLM was correct: when the rule baseline across clusters took the highest score, it selected `redis` (two dependency evidences of 5.0), while the LLM ranked `payment` first (with higher weight for self-failure evidence) — the correct answer was `payment`."
- "Hallucination check 0: because the prompt provided a list of candidate services and the true topology, and enforced JSON output."

## 3. Policy Validation (Beginning of Phase II)

```bash
bash /opt/aisre/scripts/28-selfheal-loop.sh --stage heal \
     --dataset /opt/aisre/datasets/<数据集> --root-cause payment
```

**Notes**:
- "After the root cause is fed in, it goes through the **Policy Engine**: 8 checks are sequentially evaluated (Action Level / Whitelist / Cool Down / Blast Radius / Rate Limiting / Idempotence / Prerequisites / Dry-run)"
- "During the demo, I will intentionally run a case that is **blocked** (e.g., L3 scaling down to 0 or out-of-bound namespace) to show you that the guardrails are indeed working."

## 4. Automatic Execution and Recovery (Main Part of Phase II)

**Notes**:
- "It performs the equivalent action of `kubectl rollout restart` (with maxUnavailable=0), and in the observation window, ready will spike to 11/9 first — that's because new and old Pods coexist during the rollout, and the service remains available."
- "**5xx errors will drop to 0 first, but the alert is still ringing** — this is not a bug: the `rate(...[5m])` has a 5-minute window, and the alert will only be resolved after the window clears, even though the SLI has recovered (this is used to explain why alerts lag behind metrics)."

## 5. Audit Trail (End of Phase II)

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

**Notes**:
- "Every action is hashed: `hash = sha256(prev_hash + 内容)`; any alteration of the history chain breaks the audit"
- "Note: **Rollbacks do not delete audits** — the value of audits lies in 'what was done must be traceable'"

## 6. Actual Timeline (Can Be Used Directly as Screen Recording Narration)

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

**End-to-end timing**: injection → alert 112 s; policy → execution → recovery 210 s (20:22:49 → 20:26:19).
**Total**: about 7 minutes (including the 5-minute rate-window wait).

## 7. The Three Most Common Questions That Can Interrupt the Demo

| Question | Response points |
|---|---|
| "Why did ready change to 11/9?" | Rolling restart surge: `maxSurge=1/maxUnavailable=0`, new and old Pods coexist briefly, service remains uninterrupted |
| "The metrics are already good, why is the alert still ringing?" | The rule uses `rate(...[5m])` with `for: 2m`, which is **intentional** lag: to avoid false positives due to jitter, at the cost of a slower recovery |
| "What if the LLM is wrong?" | ① Prompt constraints on the candidate set + topology folding; ② Post-output validation to ensure the service is within the topology (hallucination check); ③ **The policy engine still needs to pass 8 checks**; ④ The worst-case scenario is a single Deployment restart, with full audit trail for rollback |
