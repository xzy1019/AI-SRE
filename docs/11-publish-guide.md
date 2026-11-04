# 推送与凭据配置说明

| 项 | 内容 |
|---|---|
| 用途 | 把本仓库推送到 GitHub / AtomGit，以及**凭据怎么配、密钥怎么填** |
| 关联 | [02 集群访问](02-cluster-access.md)（集群凭据） · [i18n](i18n.md) |
| 适用环境 | 本项目开发机（Windows）：**DNS 不可用**，必须走本机代理 |

---

## 0. 先看结论（本项目的实际情况）

| 方式 | 能否用 | 原因 |
|---|---|---|
| **SSH 密钥** | ❌ **本机不可用** | 这台机器 **DNS 解析不了任何域名**（`ssh: Could not resolve hostname github.com`）。SSH 不经过 HTTP 代理，所以走不通 |
| **HTTPS + 访问令牌（PAT）** | ✅ **推荐** | 可以显式指定代理 `127.0.0.1:7897`，实测可用 |

> **如果你在别的机器（或修好了 DNS）上开发，SSH 是更省事的方案** —— 见 §2。

---

## 1. 本机可用方案：HTTPS + 令牌

### 1.1 推送命令（必须带两个参数）

```powershell
cd "C:\Users\33447\Desktop\AI 项目\ai-sre-agent"

# 推 GitHub（用户名填你的 GitHub 用户名，密码粘贴 PAT）
git -c credential.helper= `
    -c http.proxy=http://127.0.0.1:7897 `
    -c https.proxy=http://127.0.0.1:7897 `
    push -u github main
```

两个参数缺一不可：

| 参数 | 为什么必须加 |
|---|---|
| `-c http.proxy=... / -c https.proxy=...` | 本机 DNS 坏，不显式指定代理就报 `Could not resolve host` |
| `-c credential.helper=` | Git for Windows **系统级**配了 `credential.helper=manager`，它会弹一个**后台看不见的窗口**，导致推送卡死。清空它才会走终端提示 |

### 1.2 令牌怎么建

| 平台 | 路径 | 需要的权限 |
|---|---|---|
| **GitHub（Classic）** | Settings → Developer settings → Personal access tokens → **Tokens (classic)** | 勾 **`repo`** |
| **GitHub（Fine-grained）** | 同上 → **Fine-grained tokens** | Repository access 选目标仓库；Permissions → **Contents: Read and write** |
| **AtomGit** | 设置 → 访问令牌 | **仓库读写** |

> 令牌**只显示一次**，生成后立刻复制。不要贴进聊天、issue、commit。

---

## 2. 其它机器可用方案：SSH 密钥

### 2.1 生成密钥

```bash
# 推荐 ed25519（比 RSA 更短更安全）
ssh-keygen -t ed25519 -C "xzy1019@example.com" -f ~/.ssh/id_ed25519
# 一路回车（密码短语可留空，留空表示免交互）
```

**`-C` 后面的注释写什么：** 它只是**公钥末尾的一个标签**，方便你在服务器端辨认这把钥匙属于谁。
推荐写成 `邮箱` 或 `用户名@机器`，例如 `xzy1019@DESKTOP-DH7O2UQ`。**它不影响认证，写错也能用。**

### 2.2 把公钥添加到 GitHub（表单怎么填）

打开 https://github.com/settings/keys → **New SSH key**，表单有三个字段：

| 字段 | 填什么 | 说明 |
|---|---|---|
| **Title** | `DESKTOP-DH7O2UQ (Windows 工作站)` | **就是给这把钥匙起个名字**，帮你以后分辨是哪台机器加的。写 `我的电脑` / `codex-dev-2026` 都可以，**不参与认证** |
| **Key type** | `Authentication Key` | 用于 git 推送/拉取。另一个 `Signing Key` 是用来给 commit 签名的，本项目不需要 |
| **Key** | 粘贴 **公钥全文** | 打开 `~/.ssh/id_ed25519.pub`，**整行复制**（形如 `ssh-ed25519 AAAAC3Nza... xzy1019@example.com`） |

> ⚠️ **只粘贴 `.pub` 那个文件**。`id_ed25519`（没有 `.pub` 后缀）是**私钥**，永远不要发给任何人、不要粘贴到任何网页。

查看公钥内容：

```powershell
Get-Content $HOME\.ssh\id_ed25519.pub      # Windows
cat ~/.ssh/id_ed25519.pub                  # Linux / macOS
```

### 2.3 验证

```bash
ssh -T git@github.com
# 成功会看到：Hi <username>! You've successfully authenticated...
```

### 2.4 把 remote 换成 SSH

```bash
git remote set-url github git@github.com:xzy1019/AI-SRE.git
git remote -v
```

---

## 3. 本项目的远端配置

| 名称 | 地址 | 认证 |
|---|---|---|
| `origin` | `https://atomgit.com/xzyy1022/AI-SRE.git` | HTTPS + AtomGit 令牌 |
| `github` | `https://github.com/xzy1019/AI-SRE.git` | HTTPS + GitHub PAT |

**推完之后两端应该一模一样**：

```powershell
# 核对：三个哈希要一致
git rev-parse HEAD
git ls-remote origin refs/heads/main
git ls-remote github refs/heads/main
```

---

## 4. 常见错误对照表（都是本项目实际踩过的）

| 报错 | 原因 | 修法 |
|---|---|---|
| `Could not resolve host: github.com` | 本机 DNS 坏 | 加 `-c http.proxy=http://127.0.0.1:7897` |
| `could not read Username ... terminal prompts disabled` | 没有凭据且禁用了交互 | 去掉 `GIT_TERMINAL_PROMPT=0`，或在终端里手输令牌 |
| 推送**卡住不动**（无报错） | 系统级 `credential.helper=manager` 弹了看不见的窗口 | 加 `-c credential.helper=` |
| `HTTP Basic: Access denied. ... use your personal access token` | 把账号密码当令牌用了，或令牌值不对 | 用 PAT，别用登录密码；确认令牌完整复制 |
| `dubious ownership in repository` | 仓库属主与当前用户不一致（沙箱/多用户） | `git config --global --add safe.directory '<仓库绝对路径>'` |
| `Permission denied (publickey)` | SSH 公钥没加到平台，或私钥没加载 | 检查 `ssh -T git@github.com`；`ssh-add ~/.ssh/id_ed25519` |

---

## 5. 安全约定

| 规则 | 说明 |
|---|---|
| **令牌 / 私钥永不入库** | `.gitignore` 已覆盖 `*.pem` `*.key` `id_rsa*` `id_ed25519*` `kubeconfig` `.env` |
| **用 askpass 而不是写进 URL** | 把令牌写进 remote URL 会落到 `.git/config`（明文）。本项目用 `GIT_ASKPASS` 临时传入 |
| **不要提交 `known_hosts`** | 它记录了连过哪些主机，属于本机信息 |
| **推送后检查** | `git grep -n "<令牌片段>"` 应为空；`git remote get-url --all` 里不应含 `@` 前带凭据的 URL |
