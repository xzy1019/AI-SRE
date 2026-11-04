# Documentation Index

[中文](../README.md) | **English** · [Translation status](../i18n.md)

> AI SRE Agent — intelligent fault self-healing and chaos verification for cloud-native environments.
>
> **Translated so far**: this index, the root `README.en.md`, and docs **03 / 05 / 08 / 10**.
> The remaining five documents are still Chinese-only — the machine-translation drafts failed a
> code-block integrity gate and are intentionally **not published** (see [translation status](../i18n.md)).

| Item | Value |
|---|---|
| Project code | AISRE-Agent |
| Documents | 12 (11 + this index) |
| Translations | English index + [README.en.md](../../README.en.md); see [i18n status](../i18n.md) |
| Project root | `ai-sre-agent/` |

---

## Document index

Read in numeric order — the numbering is the dependency order.

| # | Document | Lines | Content |
|---|---|---|---|
| 01 | [Technical design](../01-design.md) | ~1955 | Full project picture: architecture, modules, algorithms, evaluation, schedule, component internals |
| 02 | [Cluster access & host inventory](../02-cluster-access.md) | ~1105 | Credential handling, node specs, configuration record, deployment pitfalls |
| 03 | [Local LLM environment](03-local-llm.md) · [中文](../03-local-llm.md) | ~503 | Models that run on an RTX 2070 and how to configure inference |
| 04 | [Progress log](../04-progress-log.md) | ~308 | Day-by-day progress, status overview, asset inventory, risks, next steps |
| 05 | [Project report](05-project-report.md) · [中文](../05-project-report.md) | ~163 | Stage results, acceptance matrix, demo script, talking points |
| 06 | [**Silent failure post-mortems**](../06-pitfalls.md) | ~909 | **50 problems that looked fine but were broken**: symptom / root cause / evidence / fix / self-check |
| 08 | [Demo guide](08-demo-guide.md) · [中文](../08-demo-guide.md) | ~128 | End-to-end self-healing screen-recording script (3–5 min, with measured timeline) |
| 09 | [Fault matrix report](../09-matrix-report.md) | ~401 | Injection → observation → denoise/RCA, measured (F01–F07, F13, F14) |
| 10 | [Visualization guide](10-visualization-guide.md) · [中文](../10-visualization-guide.md) | ~177 | How to read each chart and what each experiment proves |
| — | **Web console** | — | Runs **inside the cluster**: `http://<node-ip>:30088` (NodePort). Tabs: Overview / LLM / Agent / Experiments / Charts |

### Jump by need

| Your goal | Read | Key sections |
|---|---|---|
| Understand the problem being solved | 01 | §1 overview, §9 chaos design, §10 evaluation |
| Understand the technical approach | 01 | §4 module design, §7 root-cause analysis, §8 guardrails |
| Prepare for an interview | 01 | §18.2 interview Q&A (8 questions), §1.5 differentiators |
| Connect to / operate the cluster | 02 | §1 credentials, §5.4 cluster state, §5.5 script list |
| Troubleshoot the environment | 02 | §5.6 three key pitfalls |
| Call the local LLM | 03 | §2 runnable model list, §4 common commands |
| Understand component internals | 01 | §11.4 observability and chaos engineering |
| Find the schedule | 01 | §14 development schedule, §16 milestones and acceptance |
| Know "how far along is it" | 04 | whole file |
| Present this project to others | 05 | §1 results, §4 demo script, §7 talking points |
| Fix / self-check a specific pitfall | 06 | whole file (each entry ends with a self-check command) |
| Read the charts | 10 | whole file ("how to read" per chart + metric cheat sheet) |
| See measured numbers / observability gaps | 09 | §0 conclusion, §3 results, §4 blind-spot root causes |

---

## Script index

| # | Script | Where to run | Purpose |
|---|---|---|---|
| 01 | `scripts/01-baseline.sh` | all nodes | OS baseline: hostname / SELinux / time sync / sysctl |
| 02 | `scripts/02-node-runtime.sh` | all nodes | containerd + K8s components + CNI + registry mirrors |
| 03 | `scripts/03-init-cluster.sh` | k8s-cp only | control-plane init + Flannel + generate join command |
| 04 | `scripts/04-join-cluster.sh` | workers | join the cluster |
| 05 | `scripts/05-verify-cluster.sh` | k8s-cp only | cluster readiness verification (read-only) |
| 06 | `scripts/06-preload-images.sh` | all nodes | image pre-pull (mirrors + retag) — slow, fallback |
| 07 | `scripts/07-distribute-images.ps1` | workstation | **image distribution (recommended)**: pull locally → LAN transfer → `ctr import` |
| 08 | `scripts/08-verify-images.sh` | all nodes | verify image inventory (read-only) |
| 09 | `scripts/09-deploy-observability.sh` | k8s-cp only | observability stack (7 components, idempotent) |
| 10 | `scripts/10-deploy-chaos-mesh.sh` | k8s-cp only | Chaos Mesh v2.8.7 (23 CRDs, 3 local modifications) |
| 11 | `scripts/11-deploy-demo-app.sh` | k8s-cp only | demo-app (6 workloads, idempotent) |
| 12 | `scripts/12-deploy-otel-collector.sh` | k8s-cp only | OTel Collector (with OTLP→Loki self-check) |
| 13 | `scripts/13-verify-e2e.sh` | k8s-cp only | end-to-end verification (10 groups, 25 checks, read-only) |
| 14 | `scripts/14-deploy-ingestion.sh` | k8s-cp only | AIOps ingestion `aisre-ingest` (ingest/normalize/dedupe/persist) |
| 15 | `scripts/15-export-dataset.sh` | k8s-cp only | export one experiment as a self-contained dataset (events+metrics+logs+ground truth+hashes) |
| 16 | `scripts/16-correlation-baseline.py` | any (read-only) | denoising: baseline vs time-window + topology clustering; reduces/purity/over-merge |
| 17 | `scripts/17-collect-topology.sh` | k8s-cp only | collect the **real topology** from Deployment env + Service/Endpoints (call / dependency edges) |
| 18 | `scripts/18-tag-ground-truth.sh` | k8s-cp only | ground-truth label propagation (Pod label → metric → alert → event) |
| 19 | `scripts/19-rca-llm.py` | workstation (Ollama) | local-LLM RCA: structured prompt + topology folding + hallucination check + **RAG** (`--rag-kb`) |
| 20 | `scripts/20-eval-rca.py` | any (read-only) | RCA A/B: rule baseline / 0.6B / 7B / two-tier |
| 21 | `scripts/21-rca-tiered.py` | workstation (Ollama) | two-tier model: 0.6B pre-filter + 7B review |
| 22 | `scripts/22-anomaly-detect.py` | any (read-only) | three-layer anomaly detection: threshold → MAD → EWMA (debounce + merge) |
| 23 | `scripts/23-log-template.py` | any (read-only) | log template mining + abnormal template detection (lightweight Drain) |
| 24 | `scripts/24-deploy-agent.sh` | k8s-cp only | deploy self-healing layer `aisre-agent` (policy engine + executor + audit chain) |
| 25 | `scripts/25-agent-selftest.sh` | k8s-cp only | 9 positive/negative policy cases (includes a real rolling restart) |
| 26 | `scripts/26-apply-grafana-dashboards.sh` | k8s-cp only | apply 3 custom Grafana dashboards and verify via API |
| 27 | `scripts/27-ollama-logs.ps1` | workstation | local-LLM work logs: view / follow / summarize / self-check / restarted observably |
| 28 | `scripts/28-selfheal-loop.sh` | k8s-cp only | end-to-end self-healing loop driver: two stages (inject+evidence / policy·execute·recover·audit) |
| 29 | `scripts/29-run-matrix.sh` | k8s-cp only | fault matrix batch runner (F01–F07, F13, F14) + summary; includes the **alert-window drain gate** (P31) |
| 30 | `scripts/30-eval-matrix.py` | any (read-only) | matrix evaluation summary: reduction/purity/over-merge/candidate P·R/Top-1/MRR → md+json |
| 31 | `scripts/31-sync-prometheus-config.py` | any | deterministically render `_prometheus*.yml` into `03-prometheus.yaml` (with `--check`, P36) |
| 32 | `scripts/32-apply-prometheus-config.sh` | k8s-cp only | apply Prometheus config/rules: **backup → apply → restart → verify** |
| 33 | `scripts/33-check-rule-coverage.py` | any | **rule ↔ denoising coverage regression test** (P43): static + data checks |
| 34 | `scripts/34-check-metric-contracts.py` | any (queries Prometheus) | **metric contract self-check** (P38): monotonic buckets / `+Inf == _count` / mean-vs-P95 magnitude |
| 35 | `scripts/35-summarize-repeats.py` | any (read-only) | **repeatability summary**: mean ± stddev, Top-1 hit rate |
| 36 | `scripts/36-build-kb.py` | workstation (Ollama bge-m3) | **build the RAG knowledge base** from the post-mortems → `kb/pitfalls-kb.jsonl` |
| 37 | `scripts/37-sync-agent-logs.ps1` | workstation (SSH) | ~~local console data sync~~ **retired**; kept for reference |
| 38 | `scripts/38-dashboard.py` | **in-cluster only** (`--cluster`) | **web console**: 5 tabs — Overview / LLM / Agent / Experiments / Charts |
| 39 | `scripts/39-deploy-dashboard.sh` | k8s-cp only | **deploy the console into the cluster** (code+data via ConfigMap) → NodePort **30088** |
| 40 | `scripts/40-eval-rag-ab.py` | workstation (Ollama) | **RAG A/B across the matrix**: with vs without RAG |
| 41 | `scripts/41-collect-extra-datasets.py` | any (read-only) | collect experiment datasets that are **not** part of the fault matrix |

All scripts are **idempotent**; each reports `✔ / ! / ✘` and returns a non-zero exit code on failure.

```
manifests/
├── kube-flannel.yml            # CNI manifest (vendored locally)
├── chaos-mesh/chaos-mesh.yaml  # Chaos Mesh (containerd runtime + tolerations + single replica)
├── demo-app/                   # system under test
└── observability/              # namespaces → Grafana, OTel Collector
    └── _*.yml                  # leading underscore: human-readable snippets, not applied directly
```

Chaos experiment definitions live in `experiments/`:
`f01`…`f07`, `f13-cascading.yaml`, `f14-multi-root.yaml`, plus `run-experiment.sh`.

---

## Conventions

### Numbering

**Number = reading order = dependency order** — not creation time.

- `docs/` numbering follows the learning path: design → environment → components
- `scripts/` numbering follows execution order (01 must run before 02)

### Adding a document

- Filename: `NN-lowercase-hyphenated.md`
- Register it in the document index above
- Cross-link it from the adjacent documents

---

## Credentials and open source

**This repository contains no real credentials** and has been scanned before publication.

| Category | Handling |
|---|---|
| **OS root password** | **Never committed.** Scripts that need it (`07`, `37`) read `$env:LAB_ROOT_PASSWORD` and abort if unset |
| **Project-created component passwords** | Published as-is (deployment artifacts, not external secrets): Grafana `admin` / `aisre-lab-admin`; demo-app PostgreSQL `app` / `demo-pass` |
| **Host IPs** | `172.29.20.21`–`25` in the docs are an **example private range** — replace with your own |
| **kubeconfig / private keys** | Not committed (`.gitignore` covers `*.pem`, `*.key`, `id_rsa*`, `kubeconfig`) |
| **Run artifacts** | `_logs/`, `_verify/`, `datasets/*/`, `kb/` are not committed |

---

## Related locations

| Content | Location |
|---|---|
| Scripts and manifests on nodes | `/opt/aisre/{scripts,manifests}` |
| Control-plane kubeconfig | `k8s-cp:/root/.kube/config` |
| Node join command | `k8s-cp:/opt/cluster-join.sh` |
| Local LLM model directory | `D:\LLM` (workstation) |
