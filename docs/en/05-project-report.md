[中文](../05-project-report.md) | **English**

> ⚠️ Machine-translated by `qwen2.5:7b` — review before trusting.

# Project Presentation

| Item | Content |
|---|---|
| Presentation Date | 2026-11-01 |
| Project | AI SRE Agent —— An Intelligent Fault Self-healing and Chaos Validation Platform for Cloud-native Environments |
| Phase | Week 1 'Environment and Data Integration' **Completed Ahead of Schedule** (Original Plan: 11/02–11/08) |
| Stage conclusion | **Faults can be created, data can be collected, and alerts can be generated**; the analysis layer (denoising/RCA/self-healing) has not yet started |
| Related Documents | [Document Index](README.md) · [01 Technical Design](01-design.md) · [02 Cluster Access](02-cluster-access.md) · [04 Project Progress](04-progress-log.md) · [06 Silent Failure Retrospective](06-pitfalls.md) |

## 1. What Was Actually Accomplished in This Phase

### 1.1 A Rebuildable 5-Node Experimental Environment

```
k8s-cp(21)   k8s-obs(22)   k8s-app1(23)   k8s-app2(24)   k8s-ai(25)
 控制面       可观测性栈      业务 frontend    业务 payment     OTel Collector
 Flannel     Prometheus        order          postgres        （AIOps 组件将落在此）
 Chaos Mesh  Loki/Grafana      loadgen         redis
```

- From Zero to Cluster: `scripts/01 → 05`, all idempotent, can be executed repeatedly
- Solution for Wall-Mirrored Images: Development machine `crane pull` → Intranet scp → Nodes `ctr import` (scripts/07/08)
- All scripts and manifests are stored in the repository and nodes `/opt/aisre/`, with changes synchronized in both places

### 1.2 A Business with Built-In Tracing (Critical Asset)

`demo-app`: `loadgen → frontend → order → payment → postgres/redis`, frontend/order on app1, payment on app2 (**deliberately across nodes** to make network-related chaos meaningful).
Each service exposes `/metrics` (Prometheus text format) and `/healthz`, with logs in JSON structure (Loki can directly query by fields).

**Why Not Use the Existing Online Boutique**: That service set is too complex, the images are too heavy, and it cannot be pulled due to network restrictions; building this 20-line Python (standard library, no third-party dependencies) code is controllable, allows arbitrary tracing point insertion, and enables precise fault injection—**experimental controllability is more important than "production-like"**.

### 1.3 End-to-End Traced Observability Chain

| Stage | Evidence |
|---|---|
| Metrics | `up{job="demo-app"}==1` → 6/6; Business average latency: frontend 36ms / order 25ms / payment 12ms |
| Logs | `{namespace="demo-app"}` queryable; OTLP → Collector → Loki self-check logs with full metadata |
| Alerts | 13 rules loaded (8 base + 5 business SLI); `DemoAppDownstreamFailure` triggered in the experiment |
| Chaos | Chaos Mesh v2.8.7, chaos-daemon 5/5; F01/F02 injection effective and data produced |

### 1.4 A Complete "Injection → Collection" Loop (Reproducible)

```bash
# 控制面执行
bash /opt/aisre/experiments/run-experiment.sh \
     /opt/aisre/experiments/f02-pod-failure-payment.yaml 90
```

The results are stored in `/var/lib/aisre/experiments/F02-...-<timestamp>/`:

| File | Content | Evidence |
|---|---|---|
| `meta.json` | Experiment ID, **ground truth**, injection/recovery time | `ground_truth: payment-service` |
| `baseline.json` | Baseline for the 30 seconds before injection | 5xx=0 |
| `samples.jsonl` | One sample every 10 seconds (one JSON per line) | 9 samples, each line parseable |
| `summary.json` | Peak/final metrics | **Peak 5xx = 264**, final ready=9 |

**This data with ground truth is the foundation for the denoising/RCA evaluation.** Without it, the model's quality cannot be judged.

## 2. Week 1 Acceptance Criteria

| Acceptance Item in Schedule | Result | Notes |
|---|---|---|
| Able to Spin Up a Complete Environment from Scratch (Scripted) | ✅ | `scripts/01`–`13` are all idempotent, with numbering indicating execution order |
| Inject Fault → Data Collected | ✅ | Both F01 (pod-kill) and F02 (pod-failure) produced usable data |
| Grafana Shows Anomaly Curves | ✅ | Business Metrics + 6 Business SLI Rules |
| (No AI Code Written This Week) | ✅ | No model code was touched, adhering to the schedule discipline |

## 3. Issues Found and Fixed in This Phase (All Looked Normal but Were Not Working)

| # | Phenomenon | Root Cause | Impact | Handling |
|---|---|---|---|---|
| 1 | Alertmanager Long-term 0 Alarms | `rule_files` set to `/etc/prometheus/rules/*.yml`, but ConfigMap flattened mounted as `/etc/prometheus/rules.yml` | **8 Rules Never Took Effect** | Change path; Validate with `/api/v1/rules` (13 rules) |
| 2 | Full Node False Alarms `KubeletDown` on 5 Nodes | kubelet job not configured with `authorization.credentials_file`, scrape without token → 403 | Noise Overwhelms True Alarms | Add token → 5/5 `health=up` |
| 3 | Deployment Stuck at 1/2 Not Converging | `limits.cpu` Quota = 6, while Rolling Update (maxSurge=1) Requires an Additional Instance | Update Silent Failure | Increase Quota to 12 and Comment on Reason |
| 4 | Container Repeatedly Killed (exit 137) | Probe Default 1s Timeout + `socketserver` Accept Queue Only 5 | Business Jitters, False Failures | Change Probe Timeout to 3s/Threshold 5 + Set `request_queue_size=128` for Application |
| 5 | OTel Container Unable to Start, Reports "File Not Found" | 0.116.0 Binary Dynamically Linked, No glibc Loader in Image (ENOENT Misread as "Image Not Pulled") | Component Unavailable | Switch to 0.113.0; Validate with `ctr run ... --version` Instead of `ls` |
| 6 | Promtail on 3 Nodes Permanently `0/1` and Trigger `PodNotReady` | `/ready` Returns 500 When No Collection Targets Present | False Alarm | Change Readiness Probe to `tcpSocket` |
| 7 | Experimental Data "Has Files but All Null" | Pure Scalar Query Returns `resultType=scalar`, Script Only Parses Vectors; JSONL Written as Multi-line | Data Unavailable | Both Return Types Compatible + Compress to Single Line; Add Line-by-Line Parsing Check |
| 8 | P95 Constant 7.5s, Delay Alarm Never Recovers | Tracing Point Aggregates Already Accumulated Buckets Again (`cum += h[i]`): `le="10.0"`=1139 While `_count`=116 | True 10ms Counted as 7.5s, Noise Directly Enters AIOps Input | Correct According to Histogram Contract (Monotonic / `+Inf==count`), Write Unit Test `_verify/verify_histogram.py`; After Fix, P95 = 0.023–0.046s |

> The Common Theme of These 7 Issues: **"Configuration Written / File Generated / Process Started" Does Not Equal "Function Actually Effective"**. 
> It Is Necessary to Check Runtime Status and End-to-End Data. This Is Exactly Where AIOps Projects Are Most Likely to Fail—The Upstream Data Itself Is Incorrect, 
> and Any Smart Algorithm Afterward Is Just Learning Noise.

## 4. Demo Script (5 minutes to cover)

1. **Show the environment** (30s): `bash scripts/13-verify-e2e.sh` → all 19 checks green (nodes / Pods / metrics / logs / alerts / chaos / OTel / rules).
2. **Show the business** (30s): Open the business panel in Grafana → See the QPS and latency curves of frontend/order/payment running.
3. **Inject a fault** (60s): `run-experiment.sh f02-pod-failure-payment.yaml 90` → Demonstrate the full unavailability of the payment pod.
4. **Watch the data** (60s): Within the same time window: payment data missing on Prometheus, order 5xx errors spike to a peak of 264, and "downstream call failure" logs appear in Loki.
5. **Watch the alerts** (30s): `DemoAppDownstreamFailure` triggers in Alertmanager, indicating the root cause direction (order calling payment failed).
6. **收尾** (60s): Experiment output directory + `summary.json` numbers; explain that the next step is to integrate this alert into Ingestion for denoising and RCA.

**Presentation note**: The project provides a **repeatable, ground-truth, quantifiable** fault dataset, not just a Kubernetes installation.

## 5. Data and Product Locations

| Content | Location |
|---|---|
| Experiment raw data (including ground truth) | `/var/lib/aisre/experiments/<experiment>-<timestamp>/` |
| Prometheus TSDB | `k8s-obs:/var/lib/aisre/prometheus` (retained for 15 days / 8GB) |
| Loki logs | `k8s-obs` (retained for 7 days) |
| Cluster scripts/blueprints | `/opt/aisre/{scripts,manifests,experiments}` |
| Local repository copy | `ai-sre-agent/` (docs 01–05, scripts 01–13, manifests, experiments) |

## 6. Risks and Next Steps

| Risk | Description | Mitigation |
|---|---|---|
| Analysis Layer Not Started | Currently only "Data", no "Intelligence" | Focus on Ingestion + Denoising (No LLM, build baseline first) in the second week |
| Single Point of Failure | 1. Control Plane and OBS nodes have only 15 GiB of memory | No additional load during the experiment; TSDB limited to 8GB |
| Weak Local Model | 8 GB GPU memory → 7B level | RCA only produces structured output, evaluation includes comparison between small model and cloud API |
| Small Data Scale | Per experiment in minutes, single cluster | Clearly state limitations, do not claim "production readiness" |

**Next Steps (in dependency order)**:
1. Ingestion (Go): Alertmanager Webhook → Unified Event → Fingerprint Deduplication → NATS (**Alerts finally have a consumer**)
2. Automatically export alert streams/metrics/logs of each experiment to `datasets/` (including ground truth)
3. Three-stage Denoising Engine (Python, no LLM for now, establish a baseline for comparison)
4. Anomaly Detection (Threshold → MAD → EWMA) + Log Template Mining (Drain3)
5. RCA + RAG (Candidate Set → Four Evidence → Local LLM Structured Output → Hallucination Check)
6. Agent Execution + Security Guardrails (CRD + Policy Engine + Audit Hash Chain)

## 7. Presentation notes (three statements and likely follow-ups)

**Three sentences**
1. I set up a 5-node Kubernetes experimental environment, including observability stack and chaos engineering, all scripted and fully reproducible.
2. I built a service with built-in tracing and an experimental data collection toolchain with ground truth, successfully running the "inject fault → metrics/log/alarm" loop.
3. The next step is to perform alert denoising and root cause analysis on this dataset, proving the effectiveness with metrics like false self-healing rate, rather than just running a demo.

**Five likely follow-up questions**

| Question | Response points |
|---|---|
| Why not use kind/k3s? | The goal includes node-level chaos and real node topology (inter-node network failures), which kind cannot simulate. Also, using openEuler to closely mimic a domestic environment. |
| Is your data volume sufficient? | Clear limitations: single cluster, minute-level; the value lies in ground truth and reproducibility, not scale. Scalability path: multiple clusters and long-term data collection. |
| How do you evaluate alert denoising? | Three metrics: denoising rate, cluster purity, **over-merge rate**; evaluated using ground truth experimental data, A/B testing. |
| How do you prevent agents from misbehaving? | Four-level action grading (L0 observation ~ L3 high risk), 8 policy validations, cooldown period, audit hash chain, successful only after SLI recovery. |
| Why emphasize the "false self-healing rate"? | In SRE scenarios, **incorrect automatic recovery is more costly than no recovery**: it hides faults, expands their impact, and makes them harder to debug. Therefore, the false self-healing rate is the primary metric. |

## Change Log

| Version | Date | Changes |
|---|---|---|
| v1.0 | 2026-11-01 | First report: stage results, acceptance matrix, 7 resolved issues, demo script, and presentation notes |
