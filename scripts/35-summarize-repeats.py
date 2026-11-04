#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
35-summarize-repeats.py —— 重复性实验汇总（每个故障多轮 → 均值/标准差/命中率）

为什么需要它：
    单个样本的"降噪 90.9%"说明不了稳定性 —— 可能是运气好。
    重复性实验要回答的是：**同一故障跑 N 遍，指标抖不抖、结论稳不稳**。
    本项目此前所有数字都只有 1 个样本，这是最薄弱的一环。

用法:
    python3 35-summarize-repeats.py --datasets datasets --topology topology/topology.json
    python3 35-summarize-repeats.py --since 2026-11-03T09:19:14Z   # 只统计某时间之后的轮次

输入:
    <datasets>/matrix.jsonl          每行一轮实验（29 号脚本追加）
    <datasets>/repeat-base.env       可选；里面有 REPEAT_BASE=<ISO>，作为默认 --since

输出:
    控制台表格 + <datasets>/repeats_summary.md|json
"""
import argparse
import io
import json
import os
import statistics
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CORRELATION = os.path.join(HERE, "16-correlation-baseline.py")

METRICS = ["reduction_rate", "cluster_purity", "over_merge_rate",
           "candidate_precision", "candidate_recall", "top1_precision", "gt_mrr"]


def norm_service(s):
    if not s:
        return ""
    s = s.strip().lower()
    for suf in ("-service", "_service"):
        if s.endswith(suf):
            s = s[: -len(suf)]
    return s


def read_since(datasets):
    p = os.path.join(datasets, "repeat-base.env")
    if os.path.isfile(p):
        for line in io.open(p, encoding="utf-8"):
            if line.startswith("REPEAT_BASE="):
                return line.split("=", 1)[1].strip()
    return None


def count_firing(ds_dir):
    """数 events.jsonl 里 status==firing 的条数（为 0 说明这一轮压根没产生告警）"""
    n = 0
    fp = os.path.join(ds_dir, "events.jsonl")
    if not os.path.isfile(fp):
        return 0
    for line in io.open(fp, encoding="utf-8"):
        line = line.strip()
        if line:
            try:
                if json.loads(line).get("status") == "firing":
                    n += 1
            except ValueError:
                pass
    return n


def run_correlation(ds_dir, window, topology, gt):
    cmd = [sys.executable, CORRELATION, ds_dir, "--window", str(window)]
    if topology:
        cmd += ["--topology", topology]
    if gt:
        cmd += ["--gt", gt]
    proc = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if proc.returncode != 0:
        return None
    with io.open(os.path.join(ds_dir, "correlation.json"), encoding="utf-8") as fh:
        return json.load(fh)


def pct(x):
    return "-" if x is None else "%.1f%%" % (x * 100.0)


def num(x, nd=3):
    return "-" if x is None else ("%%.%df" % nd) % x


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--datasets", default=os.path.join(os.path.dirname(HERE), "datasets"))
    ap.add_argument("--topology", default=os.path.join(os.path.dirname(HERE), "topology", "topology.json"))
    ap.add_argument("--window", type=int, default=90)
    ap.add_argument("--since", default=None, help="只统计 injected_at >= 该时间的轮次（ISO8601）")
    ap.add_argument("--md-out", default=None)
    ap.add_argument("--json-out", default=None)
    args = ap.parse_args()

    since = args.since or read_since(args.datasets)
    matrix = os.path.join(args.datasets, "matrix.jsonl")
    if not os.path.isfile(matrix):
        print("找不到 %s" % matrix)
        return 2
    rows = [json.loads(l) for l in io.open(matrix, encoding="utf-8") if l.strip()]
    if since:
        rows = [r for r in rows if str(r.get("injected_at", "")) >= since]
        print("· 只统计 injected_at >= %s 的轮次（共 %d 轮）" % (since, len(rows)))
    if not rows:
        print("没有符合条件的轮次。")
        return 1

    topo = args.topology if os.path.isfile(args.topology) else None
    by_exp = {}
    fails = []
    for r in rows:
        exp = r.get("experiment_id", "?")
        ds = os.path.join(args.datasets, os.path.basename(str(r.get("dataset", "")).rstrip("/")))
        if not os.path.isfile(os.path.join(ds, "events.jsonl")):
            print("  ! %s 数据集缺失，跳过：%s" % (exp, ds))
            continue
        # 【先区分"这一轮没产生告警"和"评测真出错"】
        # 前者是**实验可复现性**问题（该故障这一轮没触发任何规则），不是脚本故障；
        # 静默跳过会把"F06 经常不触发"这种事实藏起来（本轮实测 F06 3/3、F01 1/3 无告警）。
        nfire = count_firing(ds)
        if nfire == 0:
            by_exp.setdefault(exp, []).append({"no_alert": True, "dataset": os.path.basename(ds),
                                               "top1_hit": None})
            print("  · %s 无告警（不可评测）：%s" % (exp, os.path.basename(ds)))
            continue
        corr = run_correlation(ds, args.window, topo, str(r.get("ground_truth") or ""))
        if not corr:
            print("  ! %s 评测失败：%s" % (exp, ds))
            fails.append("%s/%s" % (exp, os.path.basename(ds)))
            continue
        m = corr.get("metrics", {})
        gt = str(r.get("ground_truth") or "")
        gt_norm = sorted({norm_service(x) for x in gt.split(",") if x.strip()})
        top1 = [c.get("root_cause_guess") for c in corr.get("clusters", []) if c.get("root_cause_guess") != "unknown"]
        hit = bool(set(top1) & set(gt_norm)) if gt_norm and top1 else False
        rec = {k: m.get(k) for k in METRICS}
        rec["top1_hit"] = hit
        rec["dataset"] = os.path.basename(ds)
        by_exp.setdefault(exp, []).append(rec)

    if not by_exp:
        print("没有可统计的轮次。")
        return 1

    print()
    print("=" * 92)
    print("重复性汇总：每个故障多轮 → 均值 ± 标准差（n=轮数）")
    print("=" * 92)
    print("%-5s %-4s %-14s %-14s %-14s %-16s %-10s" % ("实验", "n", "降噪率", "簇纯度", "过度合并", "候选P/R", "Top-1命中"))
    print("-" * 92)
    out = {}
    for exp in sorted(by_exp):
        all_runs = by_exp[exp]
        runs = [r for r in all_runs if not r.get("no_alert")]
        n_na = len(all_runs) - len(runs)
        n = len(runs)
        if n == 0:
            print("%-5s %-4d %-14s %-14s %-14s %-16s 0/%d（全部无告警）"
                  % (exp, 0, "-", "-", "-", "-", n_na))
            out[exp] = {"n": 0, "no_alert": n_na, "top1_hit": 0, "top1_hit_rate": None,
                        "runs": all_runs, "mean": {}, "stdev": {}}
            continue

        def st(key):
            vals = [r[key] for r in runs if isinstance(r.get(key), (int, float))]
            if not vals:
                return None, None
            return statistics.mean(vals), (statistics.pstdev(vals) if len(vals) > 1 else 0.0)

        red_m, red_s = st("reduction_rate")
        pur_m, pur_s = st("cluster_purity")
        ov_m, ov_s = st("over_merge_rate")
        cp_m, _ = st("candidate_precision")
        cr_m, _ = st("candidate_recall")
        hits = sum(1 for r in runs if r.get("top1_hit"))
        print("%-5s %-4d %-14s %-14s %-14s %-16s %s/%d%s" % (
            exp, n,
            "%s±%s" % (pct(red_m), pct(red_s)),
            "%s±%s" % (pct(pur_m), pct(pur_s)),
            "%s±%s" % (pct(ov_m), pct(ov_s)),
            "%s/%s" % (num(cp_m, 2), num(cr_m, 2)),
            hits, n, ("   （另有 %d 轮无告警）" % n_na) if n_na else ""))
        out[exp] = {"n": n, "no_alert": n_na, "top1_hit": hits, "top1_hit_rate": hits / n,
                    "runs": runs,
                    "mean": {k: st(k)[0] for k in METRICS},
                    "stdev": {k: st(k)[1] for k in METRICS}}

    all_hits = sum(v["top1_hit"] for v in out.values())
    all_n = sum(v["n"] for v in out.values())
    all_na = sum(v.get("no_alert", 0) for v in out.values())
    print("-" * 92)
    print("总体：可评测 %d 轮，Top-1 命中 %d 轮（%.1f%%）；另有 %d 轮无告警（不可评测）"
          % (all_n, all_hits, (100.0 * all_hits / all_n) if all_n else 0.0, all_na))
    if fails:
        print("评测失败：%s" % ", ".join(fails))

    md = ["# 重复性实验汇总\n",
          "| 实验 | 轮数 | 降噪率 | 簇纯度 | 过度合并 | 候选P/R | Top-1命中 |",
          "|---|---|---|---|---|---|---|"]
    for exp in sorted(out):
        v = out[exp]
        if not v["n"]:
            # 全部轮次都没告警（如 F06）→ 指标不可算，如实标成"不可评测"
            md.append("| %s | 0 | — | — | — | — | 0/%d（全部无告警） |" % (exp, v.get("no_alert", 0)))
            continue
        md.append("| %s | %d | %s±%s | %s±%s | %s±%s | %s/%s | %d/%d%s |" % (
            exp, v["n"], pct(v["mean"]["reduction_rate"]), pct(v["stdev"]["reduction_rate"]),
            pct(v["mean"]["cluster_purity"]), pct(v["stdev"]["cluster_purity"]),
            pct(v["mean"]["over_merge_rate"]), pct(v["stdev"]["over_merge_rate"]),
            num(v["mean"]["candidate_precision"], 2), num(v["mean"]["candidate_recall"], 2),
            v["top1_hit"], v["n"], (" (+%d 无告警)" % v["no_alert"]) if v.get("no_alert") else ""))
    md.append("")
    md.append("> 统计区间：injected_at >= %s" % (since or "全部"))
    md.append("> 总体：可评测 %d 轮，Top-1 命中 %d 轮（%.1f%%）；另有 **%d 轮无告警**（不可评测）"
              % (all_n, all_hits, (100.0 * all_hits / all_n) if all_n else 0.0, all_na))
    md.append(">")
    md.append("> 「无告警」指该轮注入后监控侧**一条告警都没产生** —— 属于**实验可复现性**问题"
              "（本轮实测 F06 三轮全无告警、F01 有一轮无告警），不是评测脚本故障。")
    md_out = args.md_out or os.path.join(args.datasets, "repeats_summary.md")
    json_out = args.json_out or os.path.join(args.datasets, "repeats_summary.json")
    io.open(md_out, "w", encoding="utf-8").write("\n".join(md) + "\n")
    json.dump(out, io.open(json_out, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    print("已写出：%s" % md_out)
    print("已写出：%s" % json_out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
