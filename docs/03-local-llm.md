# 本地大模型环境记录

| 项 | 内容 |
|---|---|
| 记录日期 | 2026-10-31 |
| 运行环境 | Windows 开发机（RTX 2070 / 32 GB / i9-9900KF） |
| 推理框架 | Ollama 0.40.13 |
| 模型目录 | `D:\LLM` |
| API 地址 | `http://127.0.0.1:11434` |
| 关联文档 | [文档索引](README.md) · [01 技术设计](01-design.md) · [02 集群访问与主机清单](02-cluster-access.md) |

---

## 1. 硬件与显存约束

| 项 | 实测值 |
|---|---|
| GPU | NVIDIA GeForce RTX 2070 |
| 显存总量 | 8192 MiB |
| 桌面空闲占用 | 1321 MiB |
| **可用于模型** | **约 6.8 GB** |
| 计算能力 | 7.5 (Turing) |
| 显卡驱动 | **621.01**（2026-10-19，已更新并验证） |
| 系统内存 | 32 GB |
| CPU | Intel Core i9-9900KF（8C/16T） |
| 模型盘 | `D:` 894 GB 总 / 736 GB 可用 |

### 显存换算公式

```
显存占用 ≈ 权重 + KV Cache + 约 0.4 GB 运行时开销

Q4_K_M 量化下：权重 ≈ 参数量(B) × 0.6 ~ 0.65 GB
  · 3B  → ~1.9 GB
  · 4B  → ~2.5 GB
  · 7B  → ~4.7 GB
  · 8B  → ~5.2 GB
  · 14B → ~9.0 GB  (超出，必须 CPU 卸载)
```

---

## 2. 可运行模型清单

体积取自 Ollama 官方库实测值。分档依据是"能否完整放进 6.8 GB 显存"。

### ✅ 舒适区（≤ 3.5 GB）—— 可开大上下文，速度快

| 模型 | 推荐标签 | 下载体积 | 说明 |
|---|---|---|---|
| `qwen3` | `4b` | 2.5 GB | 中文强 + 支持思考模式，**性价比首选** |
| `qwen2.5` | `3b` | 1.9 GB | 稳定、JSON 输出可靠 |
| `gemma3` | `4b` | 3.4 GB | Google，**支持图像输入** |
| `yi` | `6b` | 3.5 GB | 中文优化 |
| `llama3.2` | `3b` | 2.0 GB | 通用英文 |
| `granite3.3` | `2b` | 1.5 GB | 轻量 |
| `smollm2` | `1.7b` | 1.8 GB | 极小 |
| `qwen3` | `1.7b` | 1.4 GB | 轻量中文 |
| `llama3.2` | `1b` | 1.3 GB | 超轻量 |
| `qwen2.5` | `1.5b` | 986 MB | 超轻量 |
| `gemma3` | `1b` | 806 MB | 超轻量 |
| `qwen3` | `0.6b` | 523 MB | 极小 |
| `qwen2.5` | `0.5b` | 398 MB | 极小 |

### 🟡 主力区（3.5 – 5.5 GB）—— 需把上下文控制在 4k–8k

| 模型 | 推荐标签 | 下载体积 | 说明 |
|---|---|---|---|
| `qwen2.5` | `7b` | 4.7 GB | **中文与结构化输出最均衡** |
| `qwen3` | `8b` | 5.2 GB | 更新版本，支持思考模式 |
| `llama3.1` | `8b` | 4.9 GB | 通用英文主力 |
| `glm4` | `9b` | 5.5 GB | 国产，中文强 |
| `yi` | `9b` | 5.0 GB | 中文优化 |
| `internlm2` | `7b` | 4.5 GB | 国产 |
| `granite3.3` | `8b` | 4.9 GB | IBM |
| `mistral` | `7b` | 4.4 GB | 英文经典 |
| `deepseek-r1` | `7b` | 4.7 GB | 推理型 |
| `deepseek-r1` | `8b` | 5.2 GB | 推理型 |

### ⚠️ 临界区（5.5 – 6.2 GB）—— 上下文压到 2k–4k，可能部分卸载到 CPU

| 模型 | 推荐标签 | 下载体积 |
|---|---|---|
| `minicpm-v` | `8b` | 5.5 GB |
| `qwen2.5vl` | `7b` | 6.0 GB |

### 🧩 专用模型

**代码生成**

| 模型 | 推荐标签 | 体积 |
|---|---|---|
| `qwen2.5-coder` | `7b` | 4.7 GB |
| `qwen2.5-coder` | `3b` | 1.9 GB |
| `qwen2.5-coder` | `1.5b` | 986 MB |

**向量嵌入（RAG 检索，本项目必需）**

| 模型 | 推荐标签 | 体积 | 说明 |
|---|---|---|---|
| `bge-m3` | `latest` | 1.2 GB | **中文检索最佳** |
| `nomic-embed-text` | `latest` | 274 MB | 轻量英文 |

**多模态视觉（可用于分析 Grafana 截图 / 日志截图）**

| 模型 | 推荐标签 | 体积 | 说明 |
|---|---|---|---|
| `qwen2.5vl` | `3b` | 3.2 GB | 中文视觉，**推荐** |
| `gemma3` | `4b` | 3.4 GB | 视觉 + 文本 |

### ❌ 跑不动（必须 CPU 推理，速度骤降）

| 模型 | 体积 | 超限原因 |
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

> 注：8 GB 显存下，**7B–9B 是实用上限**。想跑 14B 以上需要更大显存的显卡。

---

## 3. 针对本项目的选型建议

AISRE-Agent 项目需要三类模型，用途不同：

| 用途 | 推荐模型 | 体积 | 理由 |
|---|---|---|---|
| **RCA 根因分析**（结构化 JSON 输出） | `qwen2.5:7b` | 4.7 GB | 中文理解 + JSON 格式稳定性最均衡 |
| **向量嵌入**（RAG 检索） | `bge-m3` | 1.2 GB | 中文语义检索表现最好 |
| **轻量初筛**（告警分类 / 意图识别） | `qwen3:4b` | 2.5 GB | 快，可高频调用 |
| 代码辅助（写 Operator） | `qwen2.5-coder:7b` | 4.7 GB | 可选 |

**推荐起步组合：`qwen2.5:7b` + `bge-m3`（合计 5.9 GB 磁盘）**

说明：Ollama 按需加载模型，空闲 5 分钟后自动卸载，**不需要同时常驻显存**。所以磁盘上可以准备多个，运行时按需切换。

---

## 4. 安装与配置记录

### 已完成

| 项 | 值 |
|---|---|
| 安装方式 | `winget install Ollama.Ollama` |
| 安装版本 | 0.40.13 |
| 安装路径 | `C:\Users\33447\AppData\Local\Programs\Ollama\` |
| 模型目录 | 环境变量 `OLLAMA_MODELS` = `D:\LLM`（用户级，已持久化） |
| 服务启动方式 | `ollama.exe serve`（后台进程） |
| API 验证 | `http://127.0.0.1:11434/api/version` → `{"version":"0.40.13"}` |

### 已安装模型（D:\LLM）

| 模型 | 体积 | 用途 | 状态 |
|---|---|---|---|
| `qwen2.5:7b` | 4.7 GB | RCA 根因分析主力 | ✅ 已下载并验证 |
| `bge-m3` | 1.2 GB | RAG 向量嵌入 | ✅ 已下载并验证 |
| `qwen3:0.6b` | 522 MB | GPU 验证用小模型 | ✅ 已下载 |

### ⚠️ 已知问题：模型下载会在收尾阶段停滞

实测两次拉取（qwen2.5:7b、bge-m3）都在完成度约 98% 时卡住不动。`D:\LLM\blobs` 下会残留 `<sha256>-partial` 主文件和 16 个 `<sha256>-partial-N` 分块文件。

**原因**：Ollama 采用分块并行下载，在受限网络下部分分块会停滞。

**解决办法**（实测有效）：

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

**关键：不要删除 `-partial` 文件**，那是断点数据，删了就要从头下。

### 判断下载是否完成

注意文件名后缀，`-partial` 存在即为未完成。查看时要看完整文件名，容易被截断误导：

```powershell
Get-ChildItem 'D:\LLM\blobs' -File | ForEach-Object {
  $s = if ($_.Name -match '(-partial(-\d+)?)$') { '未完成' } else { '已完成' }
  "{0,10:N0} MB  {1}" -f ($_.Length/1MB), $s
}
```

### 注意事项

1. **修改 `OLLAMA_MODELS` 后必须重启 Ollama 进程**，否则沿用旧的环境块。
2. 若通过 `Start-Process` 启动，需在当前会话先设置 `$env:OLLAMA_MODELS = 'D:\LLM'`，否则子进程不会继承。
3. 托盘程序（`ollama app.exe`）与服务（`ollama.exe serve`）是两个进程；只重启托盘程序不会重启服务。

### 常用命令

```powershell
$O = "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe"
& $O list                    # 列出已下载模型
& $O pull qwen2.5:7b         # 下载模型（落到 D:\LLM）
& $O ps                      # 查看运行中的模型 + 是否用 GPU
& $O rm <model>              # 删除模型
& $O show qwen2.5:7b         # 查看模型参数
```

---

## 5. 显卡驱动更新记录（已完成）

### 5.1 更新前后

| 项 | 更新前 | 更新后 |
|---|---|---|
| 驱动版本 | 516.94（2022-09） | **621.01（2026-10-19）** |
| CUDA 支持 | CUDA 11.7 | 当前版本 |
| 设备状态 | 正常 | 正常 |
| Ollama GPU 加速 | 未验证 | ✅ **100% GPU** |

### 5.2 为什么必须更新

Ollama 当前版本内置的 CUDA 运行时要求显卡驱动 ≥ 522.06，而 516.94 只支持到 CUDA 11.7。不更新则 GPU 卸载不会生效，自动回退 CPU 推理（速度差一个数量级）。

### 5.3 兼容性确认（实测证据）

更新前先确认 621.01 支持 RTX 2070，三份独立证据：

1. **NVIDIA 官方驱动查询服务**：以 RTX 20 系列产品 ID 查询，返回的最新驱动即为 621.01
2. **驱动元数据声明**：`Game Ready Driver 升级将面向 Maxwell、Pascal、Turing、Ampere 系列提供` —— Turing 在主线支持内（被终止支持的是 Kepler）
3. **官方发布说明 PDF**（`621.01-geforce-win11-x64-release-notes.pdf` 第 32 页）受支持产品表明确列出：
   ```
   NVIDIA GeForce RTX 2070        ← 本机显卡
   ...
   GeForce GTX 1660 SUPER     Turing
   ```

本机显卡硬件 ID：`PCI\VEN_10DE&DEV_1F54`（TU106）。

### 5.4 安装包

| 项 | 值 |
|---|---|
| 路径 | `D:\nvidia-driver\621.01-setup.exe` |
| 大小 | 989.1 MB |
| 签名 | Valid — NVIDIA Corporation（DigiCert 时间戳 2026） |
| SHA256 | `9624C64705D8C6B0FB034C69FAF176F2C85C804C434E478B15E6CA4E00965211` |
| 安装方式 | 手动运行 GUI 安装程序（提权需 UAC 授权） |

**踩坑记录**：首次尝试用静默参数 `-s -clean` 安装，`-clean` 先卸载旧驱动、随后安装阶段返回 `0x80070005`（拒绝访问），导致系统一度无 NVIDIA 驱动，由 Windows 回滚到更旧的 457.20。**最终用 GUI 手动安装成功**。结论：跨大版本升级时，`-clean` 在受限会话下风险高，建议用交互式安装。

**安装过程中的无害报错**：安装界面会弹出「脚本错误」对话框，指向 `nvidia.com .../20110601/root/js/jquery.js`（2011 年的失效路径）。这是安装程序内嵌浏览器控件的界面报错，与驱动安装无关，**点「否」即可**。

### 5.5 验证结果（2026-10-31）

```
$ ollama ps
NAME          ID              SIZE      PROCESSOR    CONTEXT    RUNNER
qwen2.5:7b    845dbda0ea48    4.8 GB    100% GPU     4096       llamacpp

$ nvidia-smi --query-gpu=clocks.current.sm,power.draw,temperature.gpu,utilization.gpu --format=csv
1905 MHz, 115.71 W, 52 C, 94 %
```

| 模型 | 生成速度 | 显存占用 | 说明 |
|---|---|---|---|
| `qwen2.5:7b` | **57.7 token/s** | ~5,226 MiB | 250 token 长文本实测 |
| `qwen3:0.6b` | 185 token/s | ~1,534 MiB | GPU 通路验证用 |

> **测量陷阱**：短生成（25 token）测出 3.0 token/s，长生成（250 token）测出 57.7 token/s。差异来自固定的加载与首 token 开销。**测速务必用足够长的输出**，否则会得出错误结论。

`bge-m3` 向量测试：输出 1024 维向量，正常。

GPU 状态：SM 时钟 1905 MHz（上限 2100）、功耗 115.7 W、温度 52 °C、利用率 94%。降频检查全部 `Not Active`（无功耗墙、无温度墙）。

| 检查项 | 结果 |
|---|---|
| `ollama ps` PROCESSOR | **100% GPU** ✅ |
| 显存占用 | 1534 MiB（模型已载入显存） |
| 生成速度 | 185 token/s（CPU 推理约为其 1/10） |
| 全部 NVIDIA 设备状态 | 正常（USB / 音频 / 系统设备同时恢复） |
| 系统待重启标记 | 无（驱动已生效，重启非必需） |

**结论：GPU 加速已启用，7B–9B 级模型可以正常运行。**
## 6. 与 AISRE-Agent 项目的衔接

项目设计要求 LLM 抽象为 `LLMProvider` 接口，本机作为**本地推理节点**，集群通过 HTTP 调用：

```
k8s 集群节点  →  http://<开发机IP>:11434/api/chat  →  本机 Ollama  →  RTX 2070
```

**待做**：把 `OLLAMA_HOST` 设为 `0.0.0.0:11434` 允许局域网访问（当前仅监听 127.0.0.1），并放行 Windows 防火墙。集群建好后按需配置。

---

## 变更记录

| 版本 | 日期 | 修改内容 |
|---|---|---|
| v1.0 | 2026-10-31 | 建立本地大模型记录：硬件约束、可运行模型清单、选型建议、安装配置、驱动待验证项 |
| v1.1 | 2026-10-31 | **显卡驱动更新至 621.01 并验证通过（100% GPU）**；新增驱动兼容性证据、踩坑记录、验证结果 |
| v1.2 | 2026-10-31 | 下载并验证 qwen2.5:7b（57.7 token/s）与 bge-m3；记录模型下载停滞问题与续传解法 |
| v1.3 | 2026-10-31 | 文档编号为 **03**；补充关联文档索引 |


---

## 6. 用本地模型做根因分析（RCA）—— 已落地

### 6.1 调用链

```
数据集 events.jsonl + topology.json + correlation.json（规则基线候选）
        ↓ scripts/19-rca-llm.py 组装结构化 prompt
Ollama /api/chat（qwen2.5:7b, format=json, temperature=0）
        ↓
rca_llm.json（排序根因 + 置信度 + 理由 + 幻觉校验）
        ↓ scripts/20-eval-rca.py 与规则基线做 A/B
rca_eval.json（Top-1 / MRR / 精确率 / 召回率 / 幻觉数 / 延迟）
```

### 6.2 常用命令

```bash
# 启动服务（模型目录在 D:\LLM）
$env:OLLAMA_MODELS='D:\LLM'; & "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe" serve

# 对某个数据集做 RCA
python3 scripts/19-rca-llm.py datasets/F13-20261102-1556 --topology topology/topology.json --model qwen2.5:7b

# 与规则基线 A/B 对照
python3 scripts/20-eval-rca.py datasets/F13-20261102-1556
```

### 6.3 实测数据（RTX 2070 8GB，qwen2.5:7b Q4_K_M）

| 数据集 | 场景 | 输出排序 | Top-1 | MRR | 候选精确率 | 候选召回率 | 幻觉 | 耗时 |
|---|---|---|---|---|---|---|---|---|
| F02-20261102-1800 | 单故障（payment） | payment > order > frontend | ✅ | 1.00 | 0.333 | 1.00 | 0 | 24.1 s |
| F13-20261102-1556 | 级联 + 双根因 | payment > redis | ✅ | 0.75 | 1.00 | 1.00 | 0 | 4.1 s |

对照规则基线（四路证据打分）：两者 **Top-1 与召回率完全一致**，
F13 上 LLM 甚至**复述出了与规则基线相同的排序与证据**（payment 自身告警最多 + redis 依赖告警）。

### 6.4 两个必须知道的局限

| 局限 | 现象 | 处理方向 |
|---|---|---|
| **LLM 会把链上症状当候选根因** | F02 上输出 `payment > order > frontend`，而真根因只有 payment → 候选精确率 0.333（规则基线 0.5） | prompt 里明确"只给根因，不要给被波及的中间服务"；或后处理用拓扑把链上服务折叠到最深层 |
| **延迟随 prompt 增长** | 短 prompt 4.1s，长 prompt 24.1s（含首次模型加载） | 保持 prompt 结构化精简；高频场景用 qwen3:0.6b 做初筛 |


### 6.5 改进：prompt 约束 + 拓扑折叠（候选精确率 0.333 → 1.000）

针对 6.4 里"LLM 会把链上症状当根因"的问题，做了两件事：

1. **prompt 约束**：明确要求"严格区分根因与被波及的服务"，并给出判断方法
   （只调用下游失败、且自身无失败证据的服务 = 症状，不要列入 root_causes）；
2. **拓扑折叠后处理**：沿 **call 边**把"能到达另一个输出服务的上游服务"折叠掉
   （只沿 call 边，绝不沿 dependency 边 —— 否则 F13 的 payment 会被错当成 redis 的上游而折叠）。

| 数据集 | 折叠前 | 折叠后 | 候选精确率（前 → 后） |
|---|---|---|---|
| F02（单故障） | payment > order | **payment** | 0.500 → **1.000** |
| F13（级联双根因） | payment > redis | payment > redis（未折叠，正确） | 1.000 → 1.000 |

结果：**改进后的 LLM 候选精确率（F02 1.000）已经超过规则基线（0.500）**，
且 F13 上折叠逻辑没有误伤依赖边 —— 说明"prompt 约束 + 结构后处理"这条路线是有效的。
延迟：模型常驻后 2.75–3.12s。


### 6.6 两级机制：0.6B 初筛 + 7B 复核（量化延迟 vs 准确率）

**动机**：7B 单次 RCA 要 3~36s，而真实告警是每分钟几十到几百条。
`qwen3:0.6b` 参数量只有 1/12，做"要不要 RCA / 哪类故障 / 可疑服务是谁"这类**分类筛选**够用。

**流水线**（`scripts/21-rca-tiered.py`）：

```
Tier1  qwen3:0.6b  精简证据（服务清单+拓扑+告警列表）→ {need_rca, fault_type, candidates[≤3]}
Tier2  qwen2.5:7b  仅当 need_rca=true → 完整证据 + 初筛候选作为约束 → 根因排序（复用 19 的 prompt 与拓扑折叠）
```

**四路对照（同一批数据集，模型热态）**：

| 数据集 | 路径 | 排序 | Top-1 | MRR | 候选精确率 | 候选召回率 | 幻觉 | 耗时 |
|---|---|---|---|---|---|---|---|---|
| F02 | 规则基线 | payment > unknown | ✅ | 1.00 | 0.500 | 1.00 | 0 | ~0 |
| F02 | 0.6B 单独 | payment > payment | ✅ | 1.00 | 1.000 | 1.00 | 0 | 6.8s |
| F02 | 7B 单独 | payment | ✅ | 1.00 | 1.000 | 1.00 | 0 | 3.1s |
| F02 | **两级** | payment | ✅ | 1.00 | 1.000 | 1.00 | 0 | 5.4s |
| F13 | 0.6B 单独 | payment | ✅ | 0.50 | 1.000 | **0.50** | 0 | 3.0s |
| F13 | 7B 单独 | payment > redis | ✅ | 0.75 | 1.000 | 1.00 | 0 | 2.8s |
| F13 | **两级** | payment > redis | ✅ | 0.75 | 1.000 | 1.00 | 0 | 6.3s |
| F14 | 规则基线 | payment > unknown > postgres > redis | ✅ | 0.528 | 0.750 | 1.00 | 0 | ~0 |
| F14 | 0.6B 单独 | payment | ✅ | 0.333 | 1.000 | **0.333** | 0 | 4.6s |
| F14 | 7B 单独 | payment > postgres > redis | ✅ | 0.611 | 1.000 | 1.00 | 0 | 35.7s |
| F14 | **两级** | payment > postgres > redis | ✅ | **0.611** | **1.000** | **1.00** | 0 | **6.9s** |

**三条结论**：

1. **0.6B 不能单独做根因判定**：它的 Top-1 永远是对的（总能挑出最显眼的那个服务），
   但**多根因召回崩了** —— F13 只给 payment（漏 redis，召回 0.50）、F14 只给 payment（漏两个，召回 0.333）。
2. **两级 = 7B 的准确率 + 复杂场景下显著更低的延迟**：F14 上两级 6.9s 达到与 7B 相同的
   MRR 0.611 / 精确率 1.000 / 召回率 1.00，而 7B 单跑要 35.7s（长 prompt）。
3. **Tier1 的候选列表其实是准的**：F14 上 0.6B 给出 `[payment, postgres, redis]` —— 3 个真根因都进了
   候选，它只是不会排序与收敛。所以它的正确用法是**当筛子**，不是当裁判。

**取舍曲线**（可作为 AI Infra 面试素材）：简单场景（F02/F13）两级比单 7B 慢 2~3.5s（多一次调用），
复杂场景（F14，16 条告警、prompt 4812 字符）两级快 5 倍 —— 因为初筛把 7B 的搜索空间压小了。


---

## 7. 本地大模型的工作日志（怎么看）

### 7.1 先搞清楚：Ollama 的日志分两路

| 路 | 内容 | 脚本模式 |
|---|---|---|
| **stdout** → `ollama-server.log` | HTTP 访问日志（GIN）：每个请求的方法/路径/状态/耗时 | `-Summary` 读它做请求统计 |
| **stderr** → `ollama-server.err.log` | 服务端运行日志：**模型加载、GPU/显存、runner 启动、WARN/ERROR** | `-Summary` 读它做加载与告警统计 |

两路必须**分别重定向**才都能看到（一个进程的 stdout/stderr 是两条流）。

日志位置（本项目）：`ai-sre-agent/_logs/ollama/`

### 7.2 四种查看方式

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

### 7.3 请求级的"工作记录"（比日志更结构化）

`/api/chat` 的**响应体本身**就带完整的工作记录，项目脚本已把它写进数据集 JSON：

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

| 脚本 | 落盘位置 |
|---|---|
| `19-rca-llm.py` | `<数据集>/rca_llm.json` 的 `usage` |
| `21-rca-tiered.py` | `<数据集>/rca_tiered.json` 的 `tier1.usage` 与 `tier2.usage` |

**这三个字段的用处**：`tokens_per_second` 用来判断是否真的跑在 GPU（本机实测 ~50 token/s；若掉到个位数说明回退到 CPU）；
`prompt_eval_count` 用来控制 prompt 膨胀（RCA 的 prompt 从 2968 → 4812 字符，token 从 ~800 → 1917）。

### 7.4 实测样例（一次 7B 推理在日志里长什么样）

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

### 7.5 坑：这样启动的本地服务**默认没有日志**

见 `docs/06-pitfalls.md` P30：`Start-Process ollama serve` 不重定向时，stdout/stderr 进了一个隐藏控制台，
而 Ollama 自己的 `%LOCALAPPDATA%\Ollama\server.log` 在 CLI 启动方式下是 **0 字节** —— 结果就是
"模型明明在跑，但想看它干了什么却没地方看"。修法：`Start-Process ... -RedirectStandardOutput/-RedirectStandardError`（本仓库的 27 号脚本已封装）。
