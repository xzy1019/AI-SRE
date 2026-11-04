#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
41-collect-extra-datasets.py —— 收集「不在故障矩阵里」的实验数据集

背景（为什么需要它）：
    matrix.jsonl 只记录 **29-run-matrix.sh 跑的矩阵轮次**（F01–F07 的重复）。
    但项目里还有几份用早期「单实验流程」（run-experiment.sh）跑出来的数据集：
      · F13 级联（payment 全副本不可用 + order→payment 延迟 + redis 不可用）
      · F14 多根因（payment + redis + postgres 三个独立根因并发）
      · PAYMENT 自愈闭环演示（注入 → 降噪 → LLM RCA → 策略校验 → 执行 → 恢复 → 审计）
    它们各自有 correlation.json 与 ground_truth.json，指标齐全，只是**没进矩阵汇总**，
    于是图表里看不到 —— 会让人误以为"只做了 7 个实验"。

本脚本把这类数据集汇总成 extra_datasets.json，供控制台的图表页读取。

用法:
    python3 41-collect-extra-datasets.py --datasets datasets
"""
import argparse
import io
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def read_json(p, d=None):
    try:
        return json.load(io.open(p, encoding="utf-8-sig"))
    except Exception:
        return d


def norm(s):
    s = (s or "").strip().lower()
    for suf in ("-service", "_service"):
        if s.endswith(suf):
            s = s[: -len(suf)]
    return s


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--datasets", default=os.path.join(ROOT, "datasets"))
    ap.add_argument("--out", default=None)
    args = ap.parse_args()
    out = args.out or os.path.join(args.datasets, "extra_datasets.json")

    # 已在矩阵里的：既记"目录名"（精确排除），也记"实验号"（用于判断谁被取代）
    in_matrix, matrix_ids = set(), set()
    mp = os.path.join(args.datasets, "matrix.jsonl")
    if os.path.isfile(mp):
        for line in io.open(mp, encoding="utf-8"):
            line = line.strip()
            if line:
                try:
                    row = json.loads(line)
                    in_matrix.add(os.path.basename(str(row.get("dataset", "")).rstrip("/")))
                    if row.get("experiment_id"):
                        matrix_ids.add(str(row["experiment_id"]))
                except ValueError:
                    pass

    extra = []
    for d in sorted(os.listdir(args.datasets)):
        dd = os.path.join(args.datasets, d)
        if not os.path.isdir(dd) or d.startswith("_") or d in in_matrix:
            continue
        corr = read_json(os.path.join(dd, "correlation.json"))
        gt = read_json(os.path.join(dd, "ground_truth.json"))
        if not corr or not gt:
            continue                      # 没有评测结果或没有标准答案的，跳过
        m = corr.get("metrics", {})
        gts = gt.get("ground_truth_services") or ([gt.get("ground_truth_service")] if gt.get("ground_truth_service") else [])
        gtn = sorted({norm(x) for x in gts if x})
        top1 = [c.get("root_cause_guess") for c in corr.get("clusters", []) if c.get("root_cause_guess") != "unknown"]
        extra.append({
            "dataset": d,
            "id": gt.get("experiment_id") or d.split("-")[0],
            "gt": gtn,
            "reduction_rate": m.get("reduction_rate"),
            "cluster_purity": m.get("cluster_purity"),
            "over_merge_rate": m.get("over_merge_rate"),
            "candidate_precision": m.get("candidate_precision"),
            "candidate_recall": m.get("candidate_recall"),
            "alerts_firing": m.get("alerts_firing"),
            "clusters": m.get("clusters"),
            "top1_hit": bool(set(top1) & set(gtn)) if gtn and top1 else None,
            # 若这个实验号已经在矩阵里跑过（且是 11-04 之后的新数据），这份旧数据集就是**历史数据**：
            # 它由旧规则/旧时长产出，指标已不代表当前系统 —— 标出来避免与新数据混淆。
            "superseded": (gt.get("experiment_id") or d.split("-")[0]) in matrix_ids,
            "note": "单次运行（早期单实验流程；未进故障矩阵）",
        })
    res = {"count": len(extra), "datasets": extra}
    # 历史的排后面，避免和新数据混着看
    extra.sort(key=lambda e: (bool(e.get("superseded")), e["dataset"]))
    res["count"] = len(extra)
    res["superseded_count"] = sum(1 for e in extra if e.get("superseded"))
    io.open(out, "w", encoding="utf-8").write(json.dumps(res, ensure_ascii=False, indent=2) + "\n")
    print("已收集 %d 份非矩阵数据集 → %s（其中历史/已被取代 %d 份）" % (
        len(extra), out, res["superseded_count"]))
    for e in extra:
        print("   %-22s %-6s GT=%-28s 降噪=%-7s 纯度=%-7s 候选P/R=%s/%s" % (
            e["dataset"], "[历史]" if e.get("superseded") else "当前", ",".join(e["gt"]),
            e["reduction_rate"], e["cluster_purity"],
            e["candidate_precision"], e["candidate_recall"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
