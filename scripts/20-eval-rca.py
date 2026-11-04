#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
20-eval-rca.py —— RCA A/B 对照：规则基线 vs 本地 LLM

用法: python3 20-eval-rca.py <数据集目录> [--topology topology/topology.json]

输入:
  correlation.json  规则基线结果（根因排序 + 证据计数）
  rca_llm.json      本地 LLM 结果（19-rca-llm.py 产出）
  ground truth      优先取事件自带的 ground_truth（标签传播），否则取 ground_truth.json

输出: 控制台对比表 + rca_eval.json

四个对比指标（口径与前面的降噪评估一致，便于横向比较）:
  Top-1 命中   : 排序第一的根因是否在 ground truth 里
  MRR          : ground truth 中每个真根因的名次倒数均值（1.0 = 全排第一）
  候选精确率   : |候选 ∩ GT| / |候选|            （有没有冤枉别的服务）
  候选召回率   : |候选 ∩ GT| / |GT|              （真根因有没有漏）
  幻觉数       : 输出里出现"拓扑之外的服务"的个数（LLM 特有风险）
  P95 延迟     : 一次 RCA 的耗时（LLM 有，规则基线接近 0）
"""
import argparse
import io
import json
import os
import sys


def norm(s):
    if not s:
        return ""
    s = s.strip().lower()
    for suf in ("-service", "_service"):
        if s.endswith(suf):
            s = s[: -len(suf)]
    return s.rstrip("-_")


def load_gt(d, topo):
    gt = set()
    # 1) 事件自带（标签传播，最可信）
    for line in io.open(os.path.join(d, "events.jsonl"), encoding="utf-8"):
        line = line.strip()
        if not line:
            continue
        e = json.loads(line)
        v = e.get("ground_truth") or (e.get("labels") or {}).get("ground_truth")
        if v:
            gt.add(norm(v))
    if gt:
        return gt, "event-labels(propagated)"
    # 2) 数据集文件（时间窗）
    p = os.path.join(d, "ground_truth.json")
    if os.path.exists(p):
        g = json.load(io.open(p, encoding="utf-8"))
        for v in (g.get("ground_truth_services") or [g.get("ground_truth_service")]):
            if v:
                gt.add(norm(v))
        return gt, "dataset-file(time-window)"
    return gt, "unknown"


def ranked_from_rule(d):
    p = os.path.join(d, "correlation.json")
    if not os.path.exists(p):
        return []
    c = json.load(io.open(p, encoding="utf-8"))
    agg = {}
    for cl in c.get("clusters", []):
        for r in cl.get("root_causes", []):
            agg[r["service"]] = agg.get(r["service"], 0.0) + float(r.get("score") or 0)
    return [s for s, _ in sorted(agg.items(), key=lambda kv: (-kv[1], kv[0]))]


def _svcs(parsed):
    return [rc.get("service", "") for rc in ((parsed or {}).get("root_causes") or []) if rc.get("service")]


def ranked_from_llm(d):
    """折叠后的结果（下游消费口径）"""
    p = os.path.join(d, "rca_llm.json")
    if not os.path.exists(p):
        return [], []
    j = json.load(io.open(p, encoding="utf-8"))
    unknown = (j.get("validation") or {}).get("unknown_services") or []
    return _svcs(j.get("parsed")), unknown


def ranked_from_file(d, fname):
    p = os.path.join(d, fname)
    if not os.path.exists(p):
        return [], None, []
    j = json.load(io.open(p, encoding="utf-8"))
    if j.get("final_root_causes") is not None:
        svcs = j["final_root_causes"]           # 两级流水线的最终结果
    else:
        svcs = _svcs(j.get("parsed"))
    lat = j.get("latency_seconds") or j.get("latency_total_seconds")
    unk = (j.get("validation") or {}).get("unknown_services") or \
          ((j.get("tier2") or {}).get("unknown_services") or [])
    return svcs, lat, unk


def ranked_from_llm_raw(d):
    """模型原始输出（未做拓扑折叠）—— 用于量化折叠带来的提升"""
    p = os.path.join(d, "rca_llm.json")
    if not os.path.exists(p):
        return []
    j = json.load(io.open(p, encoding="utf-8"))
    return _svcs(j.get("llm_raw") or j.get("parsed"))


def score(ranked, gt):
    if not gt:
        return {}
    n = [norm(x) for x in ranked]
    top1 = bool(n) and n[0] in gt
    ranks = {}
    for g in gt:
        ranks[g] = n.index(g) + 1 if g in n else 0
    mrr = sum(1.0 / r for r in ranks.values() if r > 0) / max(1, len(gt))
    cand = set(n)
    prec = len(cand & gt) / len(cand) if cand else 0.0
    rec = len(cand & gt) / len(gt)
    return {"top1": top1, "mrr": round(mrr, 3), "precision": round(prec, 3), "recall": round(rec, 3),
            "ranked": n, "ranks": ranks}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dataset")
    ap.add_argument("--topology", default="topology/topology.json")
    ap.add_argument("--gt", default=None, help="显式指定 ground truth（逗号分隔），用于标签传播覆盖不到的场景")
    args = ap.parse_args()
    d = args.dataset
    topo = json.load(io.open(args.topology, encoding="utf-8")) if os.path.exists(args.topology) else {}

    gt, gt_src = load_gt(d, topo)
    if args.gt:
        gt = set(norm(x) for x in args.gt.split(",") if x.strip())
        gt_src = "cli-override"
    rule = ranked_from_rule(d)
    llm, llm_unknown = ranked_from_llm(d)
    llm_raw = ranked_from_llm_raw(d)
    small, small_lat, small_unk = ranked_from_file(d, "rca_llm_small.json")
    tiered, tiered_lat, tiered_unk = ranked_from_file(d, "rca_tiered.json")
    rs, ls, ls_raw = score(rule, gt), score(llm, gt), score(llm_raw, gt)
    ss, ts = score(small, gt), score(tiered, gt)

    latency = None
    p = os.path.join(d, "rca_llm.json")
    if os.path.exists(p):
        latency = json.load(io.open(p, encoding="utf-8")).get("latency_seconds")

    out = {
        "dataset": os.path.basename(os.path.normpath(d)),
        "ground_truth": sorted(gt), "ground_truth_source": gt_src,
        "rule_baseline": rs,
        "llm": ls,
        "llm_raw_before_folding": ls_raw,
        "llm_small_only": ss, "llm_small_latency": small_lat,
        "llm_tiered": ts, "llm_tiered_latency": tiered_lat,
        "llm_unknown_services": llm_unknown,
        "llm_latency_seconds": latency,
    }
    json.dump(out, io.open(os.path.join(d, "rca_eval.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=2)

    print("  数据集 : %s" % out["dataset"])
    print("  GT     : %s  来源=%s" % (sorted(gt), gt_src))
    print("  ─────────────────────────────────────────────────────────────────")
    print("  %-14s %-28s %-28s" % ("", "规则基线", "本地 LLM(%s)" % ("qwen2.5:7b" if latency else "-")))
    print("  %-14s %-28s %-28s" % ("排序", " > ".join(rule) or "-", " > ".join(llm) or "-"))
    if llm_raw and llm_raw != llm:
        print("  %-14s %-28s %-28s" % ("（折叠前）", "", " > ".join(llm_raw)))
    print("  %-14s %-28s %-28s" % ("Top-1 命中", rs.get("top1"), ls.get("top1")))
    print("  %-14s %-28s %-28s" % ("MRR", rs.get("mrr"), ls.get("mrr")))
    print("  %-14s %-28s %-28s" % ("候选精确率", rs.get("precision"), ls.get("precision")))
    if llm_raw and llm_raw != llm:
        print("  %-14s %-28s %-28s" % ("  （折叠前）", "", ls_raw.get("precision")))
    print("  %-14s %-28s %-28s" % ("候选召回率", rs.get("recall"), ls.get("recall")))
    print("  %-14s %-28s %-28s" % ("幻觉数", 0, len(llm_unknown)))
    print("  %-14s %-28s %-28s" % ("耗时(s)", "~0", latency))
    print("  ─────────────────────────────────────────────────────────────────")
    if small:
        line = "Top-1=%s MRR=%s 精确率=%s 召回率=%s 幻觉=%d" % (
            ss.get("top1"), ss.get("mrr"), ss.get("precision"), ss.get("recall"), len(small_unk or []))
        print("  " + "[0.6B 单独]".ljust(14) + (" > ".join(small) or "-").ljust(28) + ("%.1fs" % (small_lat or 0)))
        print("  " + "  其指标".ljust(14) + line)
    if tiered:
        tline = "Top-1=%s MRR=%s 精确率=%s 召回率=%s 幻觉=%d" % (
            ts.get("top1"), ts.get("mrr"), ts.get("precision"), ts.get("recall"), len(tiered_unk or []))
        print("  " + "[两级]".ljust(14) + (" > ".join(tiered) or "-").ljust(28) + ("%.1fs" % (tiered_lat or 0)))
        print("  " + "  其指标".ljust(14) + tline)
    print("  结果已写入: %s/rca_eval.json" % d)
    return 0


if __name__ == "__main__":
    sys.exit(main())