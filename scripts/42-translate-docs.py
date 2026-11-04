#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
42-translate-docs.py —— 用本地 Ollama 批量翻译文档（保护代码块）

为什么单独写一个：
    全部文档约 6 万中文字，人工逐篇翻译成本极高；而**直接丢给模型翻会毁掉代码块**
    （命令、路径、PromQL、指标名被翻译后文档就不能用了）。
    本脚本把代码块先抽出来换成占位符，翻完再原样填回 —— **代码 100% 不被改动**。

用法:
    # 看会做什么（不调用模型）
    python3 42-translate-docs.py --doc docs/05-project-report.md --dry-run

    # 翻一篇
    python3 42-translate-docs.py --doc docs/05-project-report.md --lang en

    # 翻全部还没翻的
    python3 42-translate-docs.py --all --lang en

产出:
    docs/05-project-report.md  ->  docs/en/05-project-report.md
    README.md                  ->  README.en.md

设计取舍（重要）:
    · **机翻产物必须人工校对**：7B 模型对技术内容只能算"可用草稿"。
      脚本会在输出顶部插入一行提示，提醒读者这是机器翻译 + 校对状态。
    · 按 `##` 一级小节分块翻译（保留上下文，又不会撑爆上下文窗口）。
    · 表格、链接、行内代码 `xxx` 交给模型时明确要求原样保留。
"""
import argparse
import io
import json
import os
import re
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

LANG_NAMES = {"en": "English", "zh": "Simplified Chinese", "ja": "Japanese"}

SYSTEM = """你是一名技术文档译者。请把用户给出的 Markdown 片段从中文翻译成{lang}。

硬性要求：
1. **只翻译自然语言**。以下内容必须原样保留，一个字都不要改：
   - 代码块（``` 包裹的内容）
   - 行内代码（`xxx` 包裹的内容）
   - 文件路径、脚本名、K8s 资源名、PromQL 表达式、指标名、commit hash
   - 数字、单位、URL、图片/链接目标地址
2. 保留原有 Markdown 结构：标题层级（# 的数量）、列表符号、表格管道符 |、加粗 **、行内代码 `。
3. 代码块占位符形如 ⟦CODE0⟧，必须**原样保留**，不得翻译或改动。
4. 术语统一：降噪=denoising、事件簇=incident cluster、簇纯度=cluster purity、
   过度合并率=over-merge rate、候选集合=candidate set、根因分析=RCA、拓扑折叠=topology folding、
   幻觉校验=hallucination check、策略校验=policy validation、审计哈希链=audit hash chain、
   自愈=self-healing、沉默故障=silent failure、爆炸半径=blast radius、冷却期=cooldown、干跑=dry-run。
5. **标题、粗体标签、表格单元格里的中文一律要翻**，包括括号里的补充说明。
   例如 `## 0. 演示前检查（约 1 分钟）` → `## 0. Pre-Demo Checks (~1 minute)`；
   `**演示说明**` → `**Presentation notes**`。只在代码块里保留中文。
6. 只输出译文，不要任何解释、不要前言后语、不要再包一层代码块。
"""


# 模型"不翻译、改当聊天"的典型痕迹（实测 7B 翻长文档时会出现）
DRIFT_MARKERS = ["感谢你", "感谢您", "以下是对", "以下是", "希望能帮助", "希望这些建议",
                 "我们按照", "在本次迭代中", "总结如下", "总的来说", "I hope this helps",
                 "Let me know", "Here is a summary", "In summary, the"]


def verify_translation(src_text, dst_text):
    """
    质检：不合格就不许写出。三条硬指标（都是实测踩过的）：
      C1 代码块**数量与内容**必须与源完全一致（7B 翻长文时曾把 43 个代码块丢到只剩 4 个）
      C2 正文残留中文不能成片（说明某些小节没翻）
      C3 不能出现模型"自述/评论"痕迹（说明它没在翻译，而是在答复你）
    返回 (是否通过, 问题列表)
    """
    problems = []
    cs = re.findall(r"```[\s\S]*?```", src_text)
    cd = re.findall(r"```[\s\S]*?```", dst_text)
    if len(cs) != len(cd):
        problems.append("C1 代码块数量不一致：源 %d / 译 %d" % (len(cs), len(cd)))
    else:
        bad = [i for i, (a, b) in enumerate(zip(cs, cd), 1) if a.strip() != b.strip()]
        if bad:
            problems.append("C1 代码块内容被改动：第 %s 个" % bad[:6])
    prose = re.sub(r"```[\s\S]*?```", "", dst_text)
    prose_lines = [l for l in prose.split("\n") if l.strip()]
    zh = [l for l in prose_lines if len(re.findall(r"[\u4e00-\u9fff]", l)) >= 3]
    limit = max(5, int(len(prose_lines) * 0.03))
    if len(zh) > limit:
        problems.append("C2 正文残留中文过多：%d 行（上限 %d）" % (len(zh), limit))
    drift = [d for d in DRIFT_MARKERS if d in dst_text]
    if drift:
        problems.append("C3 出现模型自述/评论痕迹：%s" % "、".join(drift[:4]))
    return (not problems), problems


def ollama_chat(endpoint, model, system, user, timeout=900):
    body = json.dumps({
        "model": model, "stream": False, "options": {"temperature": 0},
        "messages": [{"role": "system", "content": system},
                     {"role": "user", "content": user}],
    }).encode("utf-8")
    req = urllib.request.Request(endpoint.rstrip("/") + "/api/chat", data=body,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8")).get("message", {}).get("content", "")


def protect_code(text):
    """把代码块抽出来换成占位符，返回 (带占位符的文本, 代码块列表)"""
    blocks = []
    def repl(m):
        blocks.append(m.group(0))
        return "⟦CODE%d⟧" % (len(blocks) - 1)
    return re.sub(r"```[\s\S]*?```", repl, text), blocks


def restore_code(text, blocks):
    for i, b in enumerate(blocks):
        text = text.replace("⟦CODE%d⟧" % i, b)
        # 模型偶尔会把全角/半角括号写乱，兜一下
        text = text.replace("【CODE%d】" % i, b).replace("[CODE%d]" % i, b)
    return text


def split_sections(text):
    """按 `## ` 切块（保留标题在块首）"""
    parts, cur = [], []
    for line in text.split("\n"):
        if line.startswith("## ") and cur:
            parts.append("\n".join(cur)); cur = [line]
        else:
            cur.append(line)
    if cur:
        parts.append("\n".join(cur))
    return parts


def target_path(src, lang):
    src = src.replace("\\", "/")
    base = os.path.basename(src)
    if lang == "zh":
        return src
    if base.lower() == "readme.md":
        if os.path.dirname(src) in ("", "."):
            return "README.%s.md" % lang
        return os.path.join(os.path.dirname(src), lang, base)
    stem, ext = os.path.splitext(base)
    return os.path.join(os.path.dirname(src), lang, "%s%s" % (stem, ext))


def translate_doc(src, lang, endpoint, model, dry_run=False, force=False):
    out = target_path(src, lang)
    if not dry_run and os.path.exists(out) and not force:
        print("  · 已存在，跳过（--force 可覆盖）: %s" % out)
        return "skip"
    text = io.open(src, encoding="utf-8").read()
    sections = split_sections(text)
    print("  %s -> %s" % (src, out))
    print("    源 %d 字 / %d 个小节" % (len(text), len(sections)))
    if dry_run:
        for i, sec in enumerate(sections[:8], 1):
            head = sec.split("\n", 1)[0][:60]
            print("      [%d] %s ..." % (i, head))
        if len(sections) > 8:
            print("      ...（还有 %d 个小节）" % (len(sections) - 8))
        return "dry"

    system = SYSTEM.format(lang=LANG_NAMES.get(lang, lang))
    translated = []
    for i, sec in enumerate(sections, 1):
        if not sec.strip():
            continue
        protected, blocks = protect_code(sec)
        t0 = time.time()
        try:
            zh = ollama_chat(endpoint, model, system, protected)
        except Exception as exc:  # noqa: BLE001
            print("      ✘ 第 %d 节翻译失败：%s" % (i, exc))
            zh = protected
        restored = restore_code(zh.strip(), blocks)
        translated.append(restored)
        print("      [%d/%d] %5d 字  %.1fs" % (i, len(sections), len(restored), time.time() - t0))

    header = "[中文](%s) | **%s**\n\n> ⚠️ Machine-translated by `%s` — review before trusting.\n" % (
        os.path.relpath(src, os.path.dirname(out)).replace("\\", "/"), LANG_NAMES.get(lang, lang), model)
    body = "\n\n".join(translated) + "\n"
    ok, problems = verify_translation(text, body)
    if not ok and not force:
        print("    ✘ 质检未通过 —— **拒绝写出**（避免把坏译文当成果发布）：")
        for pb in problems:
            print("        - " + pb)
        rej = out + ".rejected"
        os.makedirs(os.path.dirname(rej) or ".", exist_ok=True)
        io.open(rej, "w", encoding="utf-8", newline="\n").write(header + "\n" + body)
        print("    （草稿另存为 %s，供人工参考，不入库）" % rej)
        return "rejected"

    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    io.open(out, "w", encoding="utf-8", newline="\n").write(header + "\n" + body)
    io.open(out, "w", encoding="utf-8", newline="\n").write(header + "\n" + body)
    print("    ✔ 写出 %s（%d 字）" % (out, len(body)))

    # 【自检】把代码块挖掉后，正文里不该再有成片中文 —— 有就列出来，提醒人工校对
    prose = re.sub(r"```[\s\S]*?```", "", body)
    leftovers = [l.strip() for l in prose.split("\n")
                 if re.search(r"[\u4e00-\u9fff]", l) and len(re.findall(r"[\u4e00-\u9fff]", l)) >= 3]
    if leftovers:
        print("    ! 正文仍有 %d 行中文（含代码块内的中文注释属正常，其余需校对）:" % len(leftovers))
        for l in leftovers[:6]:
            print("        " + l[:88])
    return "done"


def all_docs():
    docs = ["README.md", "docs/README.md", "docs/i18n.md"]
    for f in sorted(os.listdir(os.path.join(ROOT, "docs"))):
        if f.endswith(".md") and f != "README.md" and re.match(r"^\d", f):
            docs.append("docs/" + f)
    return docs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--doc", action="append", help="源文档（可多次）")
    ap.add_argument("--all", action="store_true", help="翻译 docs/ 下所有编号文档 + README")
    ap.add_argument("--lang", default="en", choices=list(LANG_NAMES))
    ap.add_argument("--model", default="qwen2.5:7b")
    ap.add_argument("--endpoint", default="http://127.0.0.1:11434")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--list", action="store_true", help="列出待翻译文档及状态")
    args = ap.parse_args()

    docs = args.doc or (all_docs() if args.all else None)
    if args.list or not docs:
        print("文档\t\t\t目标\t\t状态")
        for d in all_docs():
            out = target_path(d, args.lang)
            print("%-28s %-30s %s" % (d, out, "已存在" if os.path.exists(out) else "待翻译"))
        return 0

    os.chdir(ROOT)
    done = skip = rejected = 0
    for d in docs:
        if not os.path.isfile(d):
            print("  ! 找不到 %s" % d); continue
        r = translate_doc(d, args.lang, args.endpoint, args.model, args.dry_run, args.force)
        done += (r == "done"); skip += (r == "skip"); rejected += (r == "rejected")
    print()
    print("通过质检并写出 %d 篇，跳过 %d 篇，**质检未通过被拒 %d 篇**" % (done, skip, rejected))
    print("提醒：机翻产物是**草稿**，发布前请人工校对（尤其表格与术语）。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
