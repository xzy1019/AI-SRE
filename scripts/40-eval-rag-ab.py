#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
40-eval-rag-ab.py —— RAG 的**全矩阵 A/B 对照**：同一批数据集，跑「不带 RAG」vs「带 RAG」

为什么需要它：
    此前 RAG 只在 F03 单点上验证过（Top-1 由 payment 纠正为 order）。
    单点结果说明不了普遍增益 —— 可能只是那一条恰好检索到了强相关的历史案例。

做法：
    对每个实验的**最新一轮**数据集：
      ① 确保有 correlation.json（没有就跑 16 号，带权威 GT）
      ② 跑 19 号：不带 RAG → rca_ab_norag.json；带 RAG → rca_ab_rag.json
      ③ 比对 Top-1 是否命中 GT，并记录耗时/tokens-per-second/检索命中
    最后输出对照表：命中数、平均耗时、以及「RAG 纠正了哪些 / 带偏了哪些」

用法:
    python3 40-eval-rag-ab.py --datasets datasets --topology topology/topology.json \
        --kb kb/pitfalls-kb.jsonl --rag-top 2 --rag-excerpt 350
"""
import argparse
import io
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def norm(s):
    s = (s or "").strip().lower()
    for suf in ("-service", "_service"):
        if s.endswith(suf):
            s = s[: -len(suf)]
    return s


def read_json(p, d=None):
    try:
        return json.load(io.open(p, encoding="utf-8"))
    except Exception:
        return d


def latest_runs(datasets):
    """matrix.jsonl 里每个实验取最后一轮"""
    rows = []
    mp = os.path.join(datasets, "matrix.jsonl")
    if os.path.isfile(mp):
        for line in io.open(mp, encoding="utf-8"):
            line = line.strip()
            if line:
                try:
                    rows.append(json.loads(line))
                except ValueError:
                    pass
    last = {}
    for r in rows:
        last[r.get("experiment_id")] = r
    return last


def run(cmd):
    p = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
    return p.returncode, (p.stdout or "") + (p.stderr or "")


def top1_of(rec):
    if not rec:
        return None
    p = rec.get("parsed") or {}
    rcs = p.get("root_causes") or []
    return norm(rcs[0].get("service")) if rcs else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--datasets", default=os.path.join(ROOT, "datasets"))
    ap.add_argument("--topology", default=os.path.join(ROOT, "topology", "topology.json"))
    ap.add_argument("--kb", default=os.path.join(ROOT, "kb", "pitfalls-kb.jsonl"))
    ap.add_argument("--model", default="qwen2.5:7b")
    ap.add_argument("--rag-top", type=int, default=2)
    ap.add_argument("--rag-excerpt", type=int, default=350)
    ap.add_argument("--only", default=None, help="只跑某个实验，如 F03")
    args = ap.parse_args()

    last = latest_runs(args.datasets)
    exps = sorted(last)
    if args.only:
        exps = [e for e in exps if e == args.only]
    if not exps:
        print("没有可用的实验记录")
        return 1

    print("=" * 90)
    print("RAG A/B 对照（模型 %s · KB=%s · top=%d · excerpt=%d）"
          % (args.model, os.path.basename(args.kb), args.rag_top, args.rag_excerpt))
    print("=" * 90)
    results = []
    for exp in exps:
        row = last[exp]
        ds = os.path.join(args.datasets, os.path.basename(str(row.get("dataset", "")).rstrip("/")))
        gt = norm(str(row.get("ground_truth") or "").split(",")[0])
        if not os.path.isfile(os.path.join(ds, "events.jsonl")):
            print("  ! %s 数据集缺失，跳过" % exp)
            continue
        if not os.path.isfile(os.path.join(ds, "correlation.json")):
            run([sys.executable, os.path.join(HERE, "16-correlation-baseline.py"), ds,
                 "--topology", args.topology, "--gt", str(row.get("ground_truth") or "")])

        base = [sys.executable, os.path.join(HERE, "19-rca-llm.py"), ds,
                "--topology", args.topology, "--model", args.model]
        rc1, _ = run(base + ["--out", "rca_ab_norag.json"])
        rc2, _ = run(base + ["--out", "rca_ab_rag.json", "--rag-kb", args.kb,
                             "--rag-top", str(args.rag_top), "--rag-excerpt", str(args.rag_excerpt)])
        if rc1 != 0 or rc2 != 0:
            print("  ! %s RCA 执行失败（norag rc=%s rag rc=%s）" % (exp, rc1, rc2))
            continue
        n = read_json(os.path.join(ds, "rca_ab_norag.json"), {}) or {}
        r = read_json(os.path.join(ds, "rca_ab_rag.json"), {}) or {}
        t1n, t1r = top1_of(n), top1_of(r)
        hitn, hitr = (t1n == gt), (t1r == gt)
        rig = [x.get("id") for x in ((r.get("rag") or {}).get("retrieved") or [])]
        results.append({"exp": exp, "gt": gt, "norag": t1n, "rag": t1r,
                        "hit_norag": hitn, "hit_rag": hitr,
                        "lat_norag": n.get("latency_seconds"), "lat_rag": r.get("latency_seconds"),
                        "tps_norag": (n.get("usage") or {}).get("tokens_per_second"),
                        "tps_rag": (r.get("usage") or {}).get("tokens_per_second"),
                        "retrieved": rig})
        mark = "RAG 纠正 ✓" if (not hitn and hitr) else ("RAG 带偏 ✗" if (hitn and not hitr) else
                                                        ("都对" if hitn and hitr else "都错"))
        print("  %-4s GT=%-9s 无RAG=%-9s RAG=%-9s  %s   检索=%s"
              % (exp, gt, t1n or "-", t1r or "-", mark, ",".join(rig) or "-"))

    if not results:
        print("没有可对比的结果")
        return 1
    hn = sum(1 for r in results if r["hit_norag"])
    hr = sum(1 for r in results if r["hit_rag"])
    ln = [r["lat_norag"] for r in results if r["lat_norag"]]
    lr = [r["lat_rag"] for r in results if r["lat_rag"]]
    print("-" * 90)
    print("  Top-1 命中： 无 RAG %d/%d（%.0f%%）  →  RAG %d/%d（%.0f%%）"
          % (hn, len(results), 100.0 * hn / len(results), hr, len(results), 100.0 * hr / len(results)))
    if ln and lr:
        print("  平均耗时：  无 RAG %.1fs  →  RAG %.1fs（+%.1fs）"
              % (sum(ln) / len(ln), sum(lr) / len(lr),
                 sum(lr) / len(lr) - sum(ln) / len(ln)))
    out = {"model": args.model, "rag_top": args.rag_top, "rag_excerpt": args.rag_excerpt,
           "results": results, "top1_norag": hn, "top1_rag": hr, "n": len(results)}
    op = os.path.join(args.datasets, "rag_ab_summary.json")
    json.dump(out, io.open(op, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    print("  已写出：%s" % op)
    return 0


if __name__ == "__main__":
    sys.exit(main())
