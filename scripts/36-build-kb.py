#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
36-build-kb.py —— 把「沉默故障复盘」构建成可检索知识库（RAG 的 KB 侧）

为什么做这个：
    project 里已经积累了 45 条真实踩坑记录（docs/06-pitfalls.md），每条都含
    「现象 / 根因 / 识别信号 / 修法」。这些正是 RCA 时最该被引用的"历史经验"，
    但此前它们只存在于文档里，LLM 在分析时完全看不到。
    本脚本把文档切成条目、用本地 bge-m3 算向量，产出可做相似度检索的知识库。

用法:
    python3 36-build-kb.py                                   # 默认读 docs/06-pitfalls.md
    python3 36-build-kb.py --src docs/06-pitfalls.md --out kb/pitfalls-kb.jsonl
    python3 36-build-kb.py --no-embed                        # 只切分不算向量（离线调试）

产出（kb/pitfalls-kb.jsonl，一行一个条目）:
    {"id":"P38","title":"...","text":"...","chars":1234,"embedding":[...]}
"""
import argparse
import io
import json
import os
import re
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def embed(endpoint, model, text, timeout=120):
    body = json.dumps({"model": model, "prompt": text}).encode("utf-8")
    req = urllib.request.Request(endpoint.rstrip("/") + "/api/embeddings", data=body,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        d = json.loads(r.read().decode("utf-8"))
    return d.get("embedding") or []


def split_entries(text):
    """
    把复盘文档切成条目。
    标题层级不统一：P01–P08 是 `## P01 ...`，P09–P45 是 `### P09 ...` —— 两种都要认。
    """
    lines = text.split("\n")
    entries, cur, cur_id, cur_title = [], [], None, None
    pat = re.compile(r"^#{2,3}\s+(P\d+)\s*(.*)$")
    for ln in lines:
        m = pat.match(ln.strip())
        if m:
            if cur_id and cur:
                entries.append((cur_id, cur_title, "\n".join(cur).strip()))
            cur_id, cur_title, cur = m.group(1), m.group(2).strip(), []
            continue
        if cur_id is not None:
            cur.append(ln)
    if cur_id and cur:
        entries.append((cur_id, cur_title, "\n".join(cur).strip()))
    return entries


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=os.path.join(ROOT, "docs", "06-pitfalls.md"))
    ap.add_argument("--out", default=os.path.join(ROOT, "kb", "pitfalls-kb.jsonl"))
    ap.add_argument("--endpoint", default="http://127.0.0.1:11434")
    ap.add_argument("--model", default="bge-m3")
    ap.add_argument("--max-chars", type=int, default=2000, help="单条上限，超长截断（避免 prompt 爆）")
    ap.add_argument("--no-embed", action="store_true")
    args = ap.parse_args()

    if not os.path.isfile(args.src):
        print("找不到源文件：%s" % args.src)
        return 2
    text = io.open(args.src, encoding="utf-8").read()
    entries = split_entries(text)
    print("从 %s 切出 %d 个条目" % (os.path.basename(args.src), len(entries)))
    if not entries:
        print("没切出条目 —— 检查标题格式（应为 `## Pxx` 或 `### Pxx`）")
        return 1

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    n_embed, fail = 0, 0
    with io.open(args.out, "w", encoding="utf-8", newline="\n") as fo:
        for pid, title, body in entries:
            chunk = "%s %s\n%s" % (pid, title, body)
            if len(chunk) > args.max_chars:
                chunk = chunk[: args.max_chars] + "…"
            rec = {"id": pid, "title": title, "text": chunk, "chars": len(chunk)}
            if not args.no_embed:
                try:
                    rec["embedding"] = embed(args.endpoint, args.model, chunk)
                    rec["embed_model"] = args.model
                    n_embed += 1
                except Exception as exc:  # noqa: BLE001
                    print("  ! %s 向量化失败：%s" % (pid, exc))
                    fail += 1
            fo.write(json.dumps(rec, ensure_ascii=False) + "\n")
            if len(entries) <= 12 or pid in ("P01", "P38", "P45"):
                print("  · %-4s %-52s %d 字%s" % (pid, title[:50], len(chunk),
                                                  "" if args.no_embed else "  [已向量化]"))
    print()
    print("写出：%s（%d 条，向量化 %d 条，失败 %d 条）" % (args.out, len(entries), n_embed, fail))
    return 0 if fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
