[中文](../03-local-llm.md) | **English**

> ⚠️ Machine-translated by `qwen2.5:7b` — review before trusting.

# Local Large Language Model Environment Record

| Item | Content |
|---|---|
| Recording Date | 2026-10-31 |
| Operating Environment | Windows Developer Machine (RTX 2070 / 32 GB / i9-9900KF) |
| Inference Framework | Ollama 0.40.13 |
| Model Directory | `D:\LLM` |
| API Address | `http://127.0.0.1:11434` |
| Related Documentation | [Document Index](README.md) · [01 Technical Design](01-design.md) · [02 Cluster Access and Host List](02-cluster-access.md) |

## 1. Hardware and GPU Memory Constraints

| Item | Measured Value |
|---|---|
| GPU | NVIDIA GeForce RTX 2070 |
| Total GPU Memory | 8192 MiB |
| Idle Desktop Memory | 1321 MiB |
| **Available for Model** | **Approximately 6.8 GB** |
| Computational Power | 7.5 (Turing) |
| GPU Driver | **621.01** (Updated and Verified on 2026-10-19) |
| System Memory | 32 GB |
| CPU | Intel Core i9-9900KF (8C/16T) |
| Model Disk | `D:` 894 GB Total / 736 GB Available |

### GPU Memory Conversion Formula

```
显存占用 ≈ 权重 + KV Cache + 约 0.4 GB 运行时开销

Q4_K_M 量化下：权重 ≈ 参数量(B) × 0.6 ~ 0.65 GB
  · 3B  → ~1.9 GB
  · 4B  → ~2.5 GB
  · 7B  → ~4.7 GB
  · 8B  → ~5.2 GB
  · 14B → ~9.0 GB  (超出，必须 CPU 卸载)
```

## 2. List of Runnable Models

Volume is from the measured values of the official Ollama library. The tiering is based on "whether it can fit into 6.8 GB of GPU memory."

### ✅ Comfort Zone (≤ 3.5 GB) —— Large Context, Fast Speed

| Model | Recommended Tag | Size | Description |
|---|---|---|---|
| `qwen3` | `4b` | 2.5 GB | Chinese strong + supports thinking mode, **best value for money** |
| `qwen2.5` | `3b` | 1.9 GB | Stable, reliable JSON output |
| `gemma3` | `4b` | 3.4 GB | Google, **supports image input** |
| `yi` | `6b` | 3.5 GB | Chinese optimized |
| `llama3.2` | `3b` | 2.0 GB | General English |
| `granite3.3` | `2b` | 1.5 GB | Lightweight |
| `smollm2` | `1.7b` | 1.8 GB | Extremely small |
| `qwen3` | `1.7b` | 1.4 GB | Lightweight Chinese |
| `llama3.2` | `1b` | 1.3 GB | Super lightweight |
| `qwen2.5` | `0.5b` | 986 MB | Super lightweight |
| `gemma3` | `0.5b` | 806 MB | Super lightweight |
| `qwen3` | `0.6b` | 523 MB | Extremely small |
| `qwen2.5` | `0.5b` | 398 MB | Extremely small |

### 🟡 Main Zone (3.5 – 5.5 GB) —— Context Limited to 4k–8k

| Model | Recommended Tag | Size | Description |
|---|---|---|---|
| `qwen2.5` | `7b` | 4.7 GB | **Best balance of Chinese and structured output** |
| `qwen3` | `8b` | 5.2 GB | Updated version, supports thinking mode |
| `llama3.1` | `8b` | 4.9 GB | General English mainstay |
| `glm4` | `9b` | 5.5 GB | Domestic, strong Chinese |
| `yi` | `9b` | 5.0 GB | Chinese optimized |
| `internlm2` | `7b` | 4.5 GB | Domestic |
| `granite3.3` | `8b` | 4.9 GB | IBM |
| `mistral` | `7b` | 4.4 GB | English classic |
| `deepseek-r1` | `7b` | 4.7 GB | Inference-oriented |
| `deepseek-r1` | `8b` | 5.2 GB | Inference-oriented |

### ⚠️ Critical Zone (5.5 – 6.2 GB) —— Context Compressed to 2k–4k, May Partially Offloaded to CPU

| Model | Recommended Tag | Size |
|---|---|---|
| `minicpm-v` | `8b` | 5.5 GB |
| `qwen2.5vl` | `7b` | 6.0 GB |

### 🧩 Specialized Models

**Code Generation**

| Model | Recommended Tag | Size |
|---|---|---|
| `qwen2.5-coder` | `7b` | 4.7 GB |
| `qwen2.5-coder` | `3b` | 1.9 GB |
| `qwen2.5-coder` | `1.5b` | 986 MB |

**Vector Embedding (RAG Retrieval, Required for This Project)**

| Model | Recommended Tag | Size | Description |
|---|---|---|---|
| `bge-m3` | `latest` | 1.2 GB | **Best for Chinese retrieval** |
| `nomic-embed-text` | `latest` | 274 MB | Lightweight English |

**Multimodal Vision (Can be used for analyzing Grafana screenshots / log screenshots)**

| Model | Recommended Tag | Size | Description |
|---|---|---|---|
| `qwen2.5vl` | `3b` | 3.2 GB | Chinese visual, **recommended** |
| `gemma3` | `4b` | 3.4 GB | Visual + Text |

### ❌ Unrunnable (Must Use CPU Inference, Speed Significantly Decreased)

| Model | Size | Overlimit Reason |
|---|---|---|
| `gemma3` | `12b` | 8.2 GB |
| `qwen2.5` | `14b` | 9.0 GB |
| `deepseek-r1` | `14b` | 9.0 GB |
| `phi4` | `14b` | 9.1 GB |
| `qwen3` | `14b` | 9.3 GB |
| `gemma3` | `27b` | 17 GB |
| `yi` | `34b` | 19 GB |
| `qwen3` | `30b` | 19 GB |
| `qwen2.5` | `32b` | 20 GB |
| `qwen3` | `235b` | 142 GB |

> Note: For 8 GB of GPU memory, **7B–9B is the practical upper limit**. Running 14B or above requires a GPU with more memory.

## 3. Recommendations for Models in This Project

AISRE-Agent project requires three types of models, each with different purposes:

| Purpose | Recommended Model | Size | Reason |
|---|---|---|---|
| **RCA Root Cause Analysis** (Structured JSON Output) | `qwen2.5:7b` | 4.7 GB | Best balance of Chinese understanding and JSON format stability |
| **Vector Embedding** (RAG Retrieval) | `bge-m3` | 1.2 GB | Best performance in Chinese semantic retrieval |
| **Lightweight Initial Screening** (Alert Classification / Intent Recognition) | `qwen3:4b` | 2.5 GB | Fast, can be frequently called |
| Code Assistance (Writing Operators) | `qwen2.5-coder:7b` | 4.7 GB | Optional |

**Recommended Starting Combination: `qwen2.5:7b` + `bge-m3` (Total 5.9 GB Disk Space)**

Note: Ollama loads models on demand, automatically unloading idle models after 5 minutes. **There is no need to permanently reside in GPU memory**. Therefore, multiple models can be prepared on disk, and switched as needed during runtime.

## 4. Installation and Configuration Records

### Completed

| Item | Value |
|---|---|
| Installation Method | `winget install Ollama.Ollama` |
| Installation Version | 0.40.13 |
| Installation Path | `C:\Users\33447\AppData\Local\Programs\Ollama\` |
| Model Directory | Environment Variable `OLLAMA_MODELS` = `D:\LLM` (user-level, persisted) |
| Service Start Method | `ollama.exe serve` (background process) |
| API Verification | `http://127.0.0.1:11434/api/version` → `{"version":"0.40.13"}` |

### Installed Models (D:\LLM)

| Model | Size | Purpose | Status |
|---|---|---|---|
| `qwen2.5:7b` | 4.7 GB | Main RCA Root Cause Analysis Model | ✅ Downloaded and Verified |
| `bge-m3` | 1.2 GB | RAG Vector Embedding | ✅ Downloaded and Verified |
| `qwen3:0.6b` | 522 MB | Small GPU Verification Model | ✅ Downloaded |

### ⚠️ Known Issue: Model Download Stalls at the End

Both pulls (qwen2.5:7b, bge-m3) were stuck at around 98% completion. Partial files `<sha256>-partial` and 16 partial chunks `<sha256>-partial-N` were left in `D:\LLM\blobs`.

**Cause**: Ollama uses parallel chunk downloads, which can stall in limited network conditions.

**Solution** (tested effective):

```powershell
# 1. 停掉所有 ollama 进程
Get-Process -Name 'ollama*' | Stop-Process -Force
Start-Sleep 4
# 2. 重启服务（记得带 OLLAMA_MODELS）
$env:OLLAMA_MODELS = 'D:\LLM'
Start-Process "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe" -ArgumentList 'serve' -WindowStyle Hidden
Start-Sleep 8
# 3. 重新拉取 —— 会从断点续传，不要删 -partial 文件
& "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe" pull <模型名>
```

**Key**: Do not delete the `-partial` files, as they contain the breakpoint data and need to be retained for resuming the download.

### Determine if Download is Complete

Be aware of the file suffix; the download is incomplete if `-partial` exists. Check the full filename to avoid being misled:

```powershell
Get-ChildItem 'D:\LLM\blobs' -File | ForEach-Object {
  $s = if ($_.Name -match '(-partial(-\d+)?)$') { '未完成' } else { '已完成' }
  "{0,10:N0} MB  {1}" -f ($_.Length/1MB), $s
}
```

### Notes

1. **Restart the Ollama process after modifying `OLLAMA_MODELS`** to ensure the new environment block is applied.
2. If starting via `Start-Process`, set `$env:OLLAMA_MODELS = 'D:\LLM'` in the current session to ensure the child process inherits it.
3. The tray program (`ollama app.exe`) and the service (`ollama.exe serve`) are two separate processes; restarting the tray program alone will not restart the service.

### Common Commands

```powershell
$O = "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe"
& $O list                    # 列出已下载模型
& $O pull qwen2.5:7b         # 下载模型（落到 D:\LLM）
& $O ps                      # 查看运行中的模型 + 是否用 GPU
& $O rm <model>              # 删除模型
& $O show qwen2.5:7b         # 查看模型参数
```

## 5. Record of GPU Driver Updates (Completed)

### 5.1 Before and After

| Item | Before | After |
|---|---|---|
| Driver Version | 516.94 (2022-09) | **621.01 (2026-10-19)** |
| CUDA Support | CUDA 11.7 | Current Version |
| Device Status | Normal | Normal |
| Ollama GPU Acceleration | Unverified | ✅ **100% GPU** |

### 5.2 Why the Update is Necessary

The current version of Ollama requires a GPU driver version ≥ 522.06 for its built-in CUDA runtime, while 516.94 only supports CUDA 11.7. If the update is not performed, GPU offloading will not take effect, and the system will automatically fallback to CPU inference (a speed difference of an order of magnitude).

### 5.3 Compatibility Confirmation (Test Evidence)

Before the update, confirm that 621.01 supports RTX 2070 with three independent pieces of evidence:

1. **NVIDIA Official Driver Query Service**: Querying with the product ID of the RTX 20 series returns the latest driver as 621.01.
2. **Driver Metadata Declaration**: `Game Ready Driver upgrade will provide support for Maxwell, Pascal, Turing, and Ampere series` —— Turing is supported in the mainline (the supported series that were terminated are Kepler).
3. **Official Release Notes PDF** (`621.01-geforce-win11-x64-release-notes.pdf`, page 32) clearly lists the supported products:
   ```
   NVIDIA GeForce RTX 2070        ← 本机显卡
   ...
   GeForce GTX 1660 SUPER     Turing
   ```

The local GPU hardware ID is: `PCI\VEN_10DE&DEV_1F54` (TU106).

### 5.4 Installation Package

| Item | Value |
|---|---|
| Path | `D:\nvidia-driver\621.01-setup.exe` |
| Size | 989.1 MB |
| Signature | Valid — NVIDIA Corporation (DigiCert timestamp 2026) |
| SHA256 | `9624C64705D8C6B0FB034C69FAF176F2C85C804C434E478B15E6CA4E00965211` |
| Installation Method | Run the GUI installer manually (UAC authorization required for elevation) |

**Bugs to Watch Out For**: The first attempt to install using silent parameters `-s -clean` resulted in an `0x80070005` (Access Denied) error during the installation phase, causing the system to revert to an older 457.20 driver. **The installation was ultimately successful using the GUI manually**. Conclusion: When upgrading across major versions, the `-clean` parameter carries high risks in restricted sessions; it is recommended to use an interactive installation.

**Harmless Errors During Installation**: The installation interface will pop up a "Script Error" dialog box, pointing to `nvidia.com .../20110601/root/js/jquery.js` (an outdated path from 2011). This is an error in the embedded browser control within the installer and is unrelated to the driver installation. **Clicking "No" will resolve the issue**.

### 5.5 Verification Results (2026-10-31)

```
$ ollama ps
NAME          ID              SIZE      PROCESSOR    CONTEXT    RUNNER
qwen2.5:7b    845dbda0ea48    4.8 GB    100% GPU     4096       llamacpp

$ nvidia-smi --query-gpu=clocks.current.sm,power.draw,temperature.gpu,utilization.gpu --format=csv
1905 MHz, 115.71 W, 52 C, 94 %
```

| Model | Generation Speed | Memory Usage | Notes |
|---|---|---|---|
| `qwen2.5:7b` | **57.7 token/s** | ~5,226 MiB | 250 token long text test |
| `qwen3:0.6b` | 185 token/s | ~1,534 MiB | GPU path validation |

> **Measurement Trap**: A 25-token generation measured 3.0 token/s, while a 250-token generation measured 57.7 token/s. The difference is due to fixed loading and the first token overhead. **Ensure that speed measurements use sufficiently long outputs** to avoid drawing incorrect conclusions.

`bge-m3` Vector Test: Output a 1024-dimensional vector, normal.

GPU Status: SM clock 1905 MHz (max 2100), power consumption 115.7 W, temperature 52 °C, utilization 94%. Frequency scaling checks all `Not Active` (no power wall, no temperature wall).

| Check Item | Result |
|---|---|
| `ollama ps` PROCESSOR | **100% GPU** ✅ |
| Memory Usage | 1534 MiB (model loaded into GPU memory) |
| Generation Speed | 185 token/s (CPU inference is about 1/10 of this) |
| Status of All NVIDIA Devices | Normal (USB / audio / system devices also recovered) |
| System Reboot Flag | None (driver is effective, reboot is not necessary) |

**Conclusion: GPU acceleration is enabled, and 7B–9B models can run normally.**

## 6. Integration with AISRE-Agent Project

The project design requires the LLM to be abstracted as the `LLMProvider` interface, with the local environment acting as a **local inference node**. The cluster calls it via HTTP:

```
k8s 集群节点  →  http://<开发机IP>:11434/api/chat  →  本机 Ollama  →  RTX 2070
```

**Todo**: Set `OLLAMA_HOST` to `0.0.0.0:11434` to allow LAN access (it currently only listens on 127.0.0.1) and disable the Windows firewall. Configure as needed after the cluster is set up.

## Change Log

| Version | Date | Changes |
|---|---|---|
| v1.0 | 2026-10-31 | Established local large model records: hardware constraints, list of runnable models, selection recommendations, installation and configuration, items to verify for drivers |
| v1.1 | 2026-10-31 | **Updated GPU driver to 621.01 and verified (100% GPU)**; Added evidence of driver compatibility, pitfall records, verification results |
| v1.2 | 2026-10-31 | Downloaded and verified qwen2.5:7b (57.7 token/s) and bge-m3; Recorded model download stall issues and resumption solutions |
| v1.3 | 2026-10-31 | Document number is **03**; Added references to related documents |

## 6. Perform Root Cause Analysis (RCA) Using Local Model —— Already Deployed

### 6.1 Call Chain

```
数据集 events.jsonl + topology.json + correlation.json（规则基线候选）
        ↓ scripts/19-rca-llm.py 组装结构化 prompt
Ollama /api/chat（qwen2.5:7b, format=json, temperature=0）
        ↓
rca_llm.json（排序根因 + 置信度 + 理由 + 幻觉校验）
        ↓ scripts/20-eval-rca.py 与规则基线做 A/B
rca_eval.json（Top-1 / MRR / 精确率 / 召回率 / 幻觉数 / 延迟）
```

### 6.2 Common Commands

```bash
# 启动服务（模型目录在 D:\LLM）
$env:OLLAMA_MODELS='D:\LLM'; & "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe" serve

# 对某个数据集做 RCA
python3 scripts/19-rca-llm.py datasets/F13-20261102-1556 --topology topology/topology.json --model qwen2.5:7b

# 与规则基线 A/B 对照
python3 scripts/20-eval-rca.py datasets/F13-20261102-1556
```

### 6.3 Real-World Data (RTX 2070 8GB, qwen2.5:7b Q4_K_M)

| Dataset | Scenario | Output Sorting | Top-1 | MRR | Candidate Precision | Candidate Recall | Hallucination | Duration |
|---|---|---|---|---|---|---|---|---|
| F02-20261102-1800 | Single Fault (payment) | payment > order > frontend | ✅ | 1.00 | 0.333 | 1.00 | 0 | 24.1 s |
| F13-20261102-1556 | Cascading + Dual Root Causes | payment > redis | ✅ | 0.75 | 1.00 | 1.00 | 0 | 4.1 s |

Compared to the rule-based baseline (four-evidence scoring): The **Top-1 and recall rate are exactly the same**. On F13, the LLM even **repeatedly stated the same sorting and evidence as the rule-based baseline** (payment had the most alerts + redis had dependency alerts).

### 6.4 Two Must-Know Limitations

| Limitation | Phenomenon | Handling Direction |
|---|---|---|
| **LLM Will Treat Symptoms on the Chain as Candidate Root Causes** | On F02, the output was `payment > order > frontend`, while the true root cause was only payment → Candidate Precision 0.333 (rule-based baseline 0.5) | Explicitly prompt "only give root causes, do not include affected services"; or post-process by folding the chain services to the deepest level using topology |
| **Latency Increases with Prompt Length** | Short prompt 4.1s, long prompt 24.1s (including initial model loading) | Keep prompt structure simple; use qwen3:0.6b for initial screening in high-frequency scenarios |

### 6.5 Improvement: Prompt Constraints + Topology Folding (Candidate Precision 0.333 → 1.000)

To address the issue of "LLM treating symptoms on the chain as root causes" from 6.4, two things were done:

1. **Prompt Constraints**: Explicitly required "strictly distinguish root causes from affected services" and provided a judgment method (services that only call downstream services and have no failure evidence = symptoms, do not include in root_causes);
2. **Topology Folding Post-Processing**: Folded "services that can reach another output service via call edges" (only along call edges, never along dependency edges — otherwise, payment on F13 would be incorrectly folded as redis's upstream).

| Dataset | Before Folding | After Folding | Candidate Precision (Before → After) |
|---|---|---|---|
| F02 (Single Fault) | payment > order | **payment** | 0.500 → **1.000** |
| F13 (Cascading Dual Root Causes) | payment > redis | payment > redis (not folded, correct) | 1.000 → 1.000 |

Result: **The improved LLM candidate precision (F02 1.000) has exceeded the rule-based baseline (0.500)**, and the folding logic on F13 did not misfire on dependency edges — indicating that the "prompt constraints + structural post-processing" approach is effective. Latency: 2.75–3.12s after model warm-up.

### 6.6 Two-Level Mechanism: 0.6B Initial Screening + 7B Final Review (Quantifying Latency vs. Accuracy)

**Motivation**: A single 7B RCA takes 3–36 seconds, while real alerts occur every minute in the hundreds. The `qwen3:0.6b` model, with only 1/12 the parameters, is sufficient for "whether to perform RCA, what type of fault, and which suspicious services" classification screening.

**Pipeline** (`scripts/21-rca-tiered.py`):

```
Tier1  qwen3:0.6b  精简证据（服务清单+拓扑+告警列表）→ {need_rca, fault_type, candidates[≤3]}
Tier2  qwen2.5:7b  仅当 need_rca=true → 完整证据 + 初筛候选作为约束 → 根因排序（复用 19 的 prompt 与拓扑折叠）
```

**Four-way Comparison (Same Dataset, Model Warm State)**:

| Dataset | Path | Sorting | Top-1 | MRR | Candidate Precision | Candidate Recall | Hallucination | Duration |
|---|---|---|---|---|---|---|---|---|
| F02 | Rule-Based Baseline | payment > unknown | ✅ | 1.00 | 0.500 | 1.00 | 0 | ~0 |
| F02 | 0.6B Alone | payment > payment | ✅ | 1.00 | 1.000 | 1.00 | 0 | 6.8s |
| F02 | 7B Alone | payment | ✅ | 1.00 | 1.000 | 1.00 | 0 | 3.1s |
| F02 | **Two-Level** | payment | ✅ | 1.00 | 1.000 | 1.00 | 0 | 5.4s |
| F13 | 0.6B Alone | payment | ✅ | 0.50 | 1.000 | **0.50** | 0 | 3.0s |
| F13 | 7B Alone | payment > redis | ✅ | 0.75 | 1.000 | 1.00 | 0 | 2.8s |
| F13 | **Two-Level** | payment > redis | ✅ | 0.75 | 1.000 | 1.00 | 0 | 6.3s |
| F14 | Rule-Based Baseline | payment > unknown > postgres > redis | ✅ | 0.528 | 0.750 | 1.00 | 0 | ~0 |
| F14 | 0.6B Alone | payment | ✅ | 0.333 | 1.000 | **0.333** | 0 | 4.6s |
| F14 | 7B Alone | payment > postgres > redis | ✅ | 0.611 | 1.000 | 1.00 | 0 | 35.7s |
| F14 | **Two-Level** | payment > postgres > redis | ✅ | **0.611** | **1.000** | **1.00** | 0 | **6.9s** |

**Three Conclusions**:

1. **0.6B Cannot Perform Root Cause Determination Alone**: Its Top-1 is always correct (always picks the most obvious service), but **multi-root cause recall is broken** — F13 only gave payment (missed redis, recall 0.50), F14 only gave payment (missed two, recall 0.333).
2. **Two-Level = 7B Accuracy + Significantly Lower Latency in Complex Scenarios**: On F14, the two-level approach reached the same MRR 0.611 / precision 1.000 / recall 1.00 in 6.9s, while 7B alone took 35.7s (long prompt).
3. **The Candidate List from Tier1 is Actually Accurate**: On F14, 0.6B gave `[payment, postgres, redis]` — all three true root causes were included in the candidate list, it just did not sort or converge. Therefore, its correct usage is **as a filter**, not as a judge.

**Trade-off Curve**: In simple scenarios (F02/F13), the two-level path is 2–3.5s slower than a single 7B request because it makes an extra call. In the complex F14 case (16 alerts, 4,812-character prompt), it is five times faster because the first-stage filter reduces the search space for 7B.

## 7. Local Large Model Work Log (How to View)

### 7.1 First, Understand: Ollama Logs Have Two Streams

| Stream | Content | Script Mode |
|---|---|---|
| **stdout** → `ollama-server.log` | HTTP Access Log (GIN): Request method/path/status/duration per request | `-Summary` Read it for request statistics |
| **stderr** → `ollama-server.err.log` | Server Running Log: **Model loading, GPU/vRAM, runner startup, WARN/ERROR** | `-Summary` Read it for loading and alert statistics |

Both streams must be **separately redirected** to be seen (stdout/stderr of a process are two streams).

Log Location (This Project): `ai-sre-agent/_logs/ollama/`

### 7.2 Four Ways to View

```powershell
# ① 看日志路径 + 两路各最后 30 行
pwsh -File scripts/27-ollama-logs.ps1

# ② 实时跟随（Ctrl+C 退出）—— 排查"为什么这次调用很慢"最有用
pwsh -File scripts/27-ollama-logs.ps1 -Follow

# ③ 汇总：请求数 / 状态码分布 / 平均与最慢耗时 / 模型加载次数 / WARN·ERROR / 最近 GPU 行
pwsh -File scripts/27-ollama-logs.ps1 -Summary

# ④ 发一次真实推理，并打印"这次调用"的 token、耗时、生成速率 + 它在日志里留下的痕迹
pwsh -File scripts/27-ollama-logs.ps1 -Test

# ⑤ 以可观测方式重启（把两路日志重定向到项目目录）
pwsh -File scripts/27-ollama-logs.ps1 -Restart
```

### 7.3 Request-Level "Work Records" (More Structured than Logs)

The **response body** of `/api/chat` itself contains complete work records, which are written into the dataset JSON by the project scripts:

```json
"usage": {
  "prompt_eval_count": 1917,          // 提示词 token 数
  "prompt_eval_duration_ms": 1645.4,  // 提示词处理耗时
  "eval_count": 170,                  // 生成 token 数
  "eval_duration_ms": 3289.3,         // 生成耗时
  "load_duration_ms": 3.6,            // 模型加载耗时（已常驻时接近 0）
  "total_duration_ms": 4951.8,        // 端到端耗时
  "tokens_per_second": 51.7           // 生成速率（8GB 显存跑 7B Q4 的实测值）
}
```

| Script | Disk Location |
|---|---|
| `19-rca-llm.py` | `usage` in `<dataset>/rca_llm.json` |
| `21-rca-tiered.py` | `tier1.usage` and `tier2.usage` in `<dataset>/rca_tiered.json` |

**The Purpose of These Three Fields**: `tokens_per_second` is used to determine if the model is truly running on the GPU (local test result: ~50 tokens/s; if it drops to single digits, it indicates a fallback to CPU);
`prompt_eval_count` is used to control prompt inflation (RCA's prompt increased from 2968 to 4812 characters, and tokens from ~800 to 1917).

### 7.4 Real-World Example (What a 7B Inference Looks Like in the Log)

```
# stdout（GIN 访问日志）
[GIN] 2026/11/02 - 20:10:41 | 200 |     3.6s |       127.0.0.1 | POST     "/api/chat"

# stderr（服务端日志，节选）
level=INFO  msg="disabling mmap for llama-server load by default" model=D:\LLM\blobs\sha256-2ba...
level=INFO  msg="starting llama-server" cmd="...ollama.exe ..."
level=INFO  msg="system memory" total="31.9 GiB" free="18.5 GiB"
level=INFO  msg="gpu memory" id=0 library=CUDA available="6.5 GiB" free="7.0 GiB"
level=INFO  msg="loading model via llama-server"
ggml_cuda_init: found 1 CUDA devices (Total VRAM: 8191 MiB):
  Device 0: NVIDIA GeForce RTX 2070, compute capability 7.5, VRAM: 8191 MiB
```

### 7.5 Pitfall: Local Service Launched This Way **Does Not Have Logs by Default**

See `docs/06-pitfalls.md` Page 30: When `Start-Process ollama serve` is not redirected, stdout/stderr go into a hidden console, and Ollama's own `%LOCALAPPDATA%\Ollama\server.log` is **0 bytes** when started via the CLI —— the result is "the model is running, but there's nowhere to see what it's doing." The fix: `Start-Process ... -RedirectStandardOutput/-RedirectStandardError` (Script 27 in this repository already encapsulates this).
