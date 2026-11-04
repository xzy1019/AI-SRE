#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
30-eval-matrix.py —— 故障矩阵评测汇总（只读数据集，写评测报告）

把 29-run-matrix.sh 产出的 matrix.jsonl 里每个实验各跑一遍降噪/根因评测
（复用 16-correlation-baseline.py），再横向汇总成一张对照表。

用法:
    python3 30-eval-matrix.py [--datasets datasets] [--topology topology/topology.json]
                              [--window 90]
                              [--md-out datasets/matrix_eval.md]
                              [--json-out datasets/matrix_eval.json]

输入:
    <datasets>/matrix.jsonl          每行一个实验（29 号脚本产出）
    <datasets>/<EXP>-<时间戳>/        自包含数据集（含 events.jsonl + ground_truth.json）

输出:
    控制台对照表 + <md-out>（人读）+ <json-out>（机读）

三种结果分开统计（不要把"没有告警"和"评测报错"混为一谈）:
    ① 有告警   —— 正常算降噪/RCA 指标
    ② 无告警   —— 注入后监控侧**一条告警都没有**：不是脚本失败，而是**监控盲区**，单独列出
    ③ 失败     —— 数据集缺失或脚本真报错
"""
import argparse
import io
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CORRELATION = os.path.join(HERE, "16-correlation-baseline.py")


def norm_service(s):
    """与 16 号脚本一致的归一化：payment-service -> payment"""
    if not s:
        return ""
    s = s.strip().lower()
    for suf in ("-service", "_service"):
        if s.endswith(suf):
            s = s[: -len(suf)]
    return s


def read_jsonl(path):
    rows = []
    with io.open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def count_firing(path):
    """数 events.jsonl 里 status==firing 的记录条数"""
    n = 0
    with io.open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                e = json.loads(line)
            except ValueError:
                continue
            if e.get("status") == "firing":
                n += 1
    return n


def gt_of_dir(ds_dir):
    p = os.path.join(ds_dir, "ground_truth.json")
    if not os.path.isfile(p):
        return []
    d = json.load(io.open(p, encoding="utf-8"))
    xs = d.get("ground_truth_services") or ([d.get("ground_truth_service")] if d.get("ground_truth_service") else [])
    return sorted({norm_service(x) for x in xs if x and norm_service(x) != "unknown"})


def run_correlation(dataset_dir, window, topology, gt=None):
    cmd = [sys.executable, CORRELATION, dataset_dir, "--window", str(window)]
    if topology:
        cmd += ["--topology", topology]
    if gt:
        # 【权威 GT 来自矩阵定义，而不是事件标签】
        # 为什么必须这样：ground_truth 是通过 Pod 标签→指标→告警传播的，
        # 而 Prometheus 里**改标签值 = 换了一条新序列**，旧序列还要存活约 5 分钟。
        # 于是"上一轮的 GT"会混进下一轮的事件里（实测 F04 的事件带着 F03 的 order-service）。
        # 矩阵定义里的根因才是这次实验的事实，用它覆盖事件标签。
        # 详见 docs/06-pitfalls.md P44。
        cmd += ["--gt", gt]
    proc = subprocess.run(cmd, capture_output=True, text=True,
                          encoding="utf-8", errors="replace")
    if proc.returncode != 0:
        raise RuntimeError("16 号脚本失败(%s): %s" % (proc.returncode, (proc.stderr or proc.stdout or "").strip()[:300]))
    with io.open(os.path.join(dataset_dir, "correlation.json"), encoding="utf-8") as fh:
        return json.load(fh)


def pct(x):
    try:
        return "%.1f%%" % (float(x) * 100.0)
    except (TypeError, ValueError):
        return "-"


def num(x, nd=3):
    try:
        return ("%%.%df" % nd) % float(x)
    except (TypeError, ValueError):
        return "-"


def main():
    ap = argparse.ArgumentParser(add_help=True, description="故障矩阵评测汇总")
    ap.add_argument("--datasets", default=os.path.join(os.path.dirname(HERE), "datasets"))
    ap.add_argument("--topology", default=os.path.join(os.path.dirname(HERE), "topology", "topology.json"))
    ap.add_argument("--window", type=int, default=90)
    ap.add_argument("--only-latest", action="store_true",
                    help="同一实验号有多轮时只评测最后一轮（matrix.jsonl 是追加日志，修完问题重跑会有多轮）")
    ap.add_argument("--md-out", default=None)
    ap.add_argument("--json-out", default=None)
    args = ap.parse_args()

    matrix = os.path.join(args.datasets, "matrix.jsonl")
    if not os.path.isfile(matrix):
        print("找不到 %s —— 先跑 29-run-matrix.sh 或把汇总文件拷回本地" % matrix)
        return 2

    topo = args.topology if os.path.isfile(args.topology) else None
    if topo is None:
        print("! 未找到拓扑文件 %s，退化为从事件反推拓扑" % args.topology)

    rows = read_jsonl(matrix)
    if args.only_latest:
        # 追加日志里同一实验号可能有多轮（改完问题重跑）；只保留最后一条
        latest = {}
        for r in rows:
            latest[r.get("experiment_id", "?")] = r
        order = []
        seen = set()
        for r in rows:
            e = r.get("experiment_id", "?")
            if e not in seen:
                seen.add(e)
                order.append(e)
        rows = [latest[e] for e in order]
        print("  · --only-latest：按实验号取最后一轮，共 %d 条" % len(rows))
    results, no_alert, failures = [], [], []
    print("=" * 78)
    print("  故障矩阵评测汇总  (window=%ss, topology=%s)" % (args.window, os.path.basename(topo) if topo else "事件反推"))
    print("=" * 78)

    for row in rows:
        exp = row.get("experiment_id", "?")
        base = os.path.basename(str(row.get("dataset", "")).rstrip("/"))
        ds_dir = os.path.join(args.datasets, base)
        ev = os.path.join(ds_dir, "events.jsonl")
        if not os.path.isfile(ev):
            print("  ! %-4s 数据集缺失，跳过：%s" % (exp, ds_dir))
            failures.append(exp)
            continue
        n_fire = count_firing(ev)
        if n_fire == 0:
            gt = gt_of_dir(ds_dir)
            no_alert.append({"experiment_id": exp, "ground_truth": gt, "dataset": base,
                             "alerts_firing": 0, "no_alert": True})
            print("  %-4s GT=%-9s 注入后**一条告警都没有** —— 监控盲区（不是脚本失败）" % (exp, ",".join(gt) or "?"))
            continue
        try:
            corr = run_correlation(ds_dir, args.window, topo, gt=str(row.get("ground_truth") or "").strip() or None)
        except Exception as exc:  # noqa: BLE001
            print("  ✘ %-4s 评测失败：%s" % (exp, exc))
            failures.append(exp)
            continue
        m = corr.get("metrics", {})
        gt = corr.get("ground_truth_services") or m.get("ground_truth_services") or []
        gt_norm = sorted({norm_service(g) for g in gt if g and norm_service(g) != "unknown"})
        top1 = []
        for c in corr.get("clusters", []):
            for r in c.get("root_causes", [])[:1]:
                if r.get("service") and r["service"] != "unknown":
                    top1.append(norm_service(r["service"]))
        hit = any(g in top1 for g in gt_norm) if gt_norm else None
        rec = {
            "experiment_id": exp, "ground_truth": gt_norm, "dataset": base,
            "alerts_firing": m.get("alerts_firing"), "clusters": m.get("clusters"),
            "reduction_rate": m.get("reduction_rate"), "cluster_purity": m.get("cluster_purity"),
            "over_merge_rate": m.get("over_merge_rate"),
            "candidate_precision": m.get("candidate_precision"), "candidate_recall": m.get("candidate_recall"),
            "top1_precision": m.get("top1_precision"), "gt_mrr": m.get("gt_mrr"),
            "top1_hit": hit, "top1_guess": top1, "no_alert": False,
        }
        results.append(rec)
        print("  %-4s GT=%-9s 告警=%-3s 簇=%-2s 降噪=%-7s 纯度=%-7s 过度合并=%-6s 候选P/R=%s/%s Top1=%-6s MRR=%-6s 命中=%s" % (
            exp, ",".join(gt_norm) or "?", rec["alerts_firing"], rec["clusters"],
            pct(rec["reduction_rate"]), pct(rec["cluster_purity"]), pct(rec["over_merge_rate"]),
            num(rec["candidate_precision"], 2), num(rec["candidate_recall"], 2),
            num(rec["top1_precision"], 2), num(rec["gt_mrr"]), "是" if hit else "否"))

    if not results and not no_alert:
        print("没有可评测的数据集。")
        return 1

    def avg(key):
        vals = [r[key] for r in results if isinstance(r.get(key), (int, float))]
        return sum(vals) / len(vals) if vals else None

    agg = {k: avg(k) for k in ("reduction_rate", "cluster_purity", "over_merge_rate",
                               "candidate_precision", "candidate_recall", "top1_precision", "gt_mrr")}
    hits = [r for r in results if r.get("top1_hit")]
    agg["top1_hit_rate"] = (len(hits) / len(results)) if results else None

    print("-" * 78)
    if results:
        print("  汇总(有告警 n=%d)：平均降噪率=%s 纯度=%s 过度合并=%s 候选P/R=%s/%s Top1=%s MRR=%s Top1命中率=%s" % (
            len(results), pct(agg["reduction_rate"]), pct(agg["cluster_purity"]), pct(agg["over_merge_rate"]),
            num(agg["candidate_precision"], 2), num(agg["candidate_recall"], 2),
            num(agg["top1_precision"], 2), num(agg["gt_mrr"]), pct(agg["top1_hit_rate"])))
    if no_alert:
        print("  监控盲区(无告警 n=%d)：%s —— 注入后监控侧一条告警都没产生" % (
            len(no_alert), ", ".join(r["experiment_id"] for r in no_alert)))
    if failures:
        print("  失败/跳过：%s" % ", ".join(failures))

    md_out = args.md_out or os.path.join(args.datasets, "matrix_eval.md")
    json_out = args.json_out or os.path.join(args.datasets, "matrix_eval.json")

    lines = ["# 故障矩阵评测汇总\n",
             "| 实验 | 真实根因 | 告警 | 簇 | 降噪率 | 簇纯度 | 过度合并 | 候选精确率 | 候选召回率 | Top-1 | MRR | Top-1命中 |",
             "|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for r in results:
        lines.append("| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |" % (
            r["experiment_id"], ",".join(r["ground_truth"]) or "?", r["alerts_firing"], r["clusters"],
            pct(r["reduction_rate"]), pct(r["cluster_purity"]), pct(r["over_merge_rate"]),
            num(r["candidate_precision"], 2), num(r["candidate_recall"], 2),
            num(r["top1_precision"], 2), num(r["gt_mrr"]), "是" if r["top1_hit"] else "否"))
    for r in no_alert:
        lines.append("| %s | %s | 0 | — | — | — | — | — | — | — | — | **监控盲区** |" % (
            r["experiment_id"], ",".join(r["ground_truth"]) or "?"))
    if results:
        lines.append("| **平均（仅有告警）** | | | | **%s** | **%s** | **%s** | **%s** | **%s** | **%s** | **%s** | **%s** |" % (
            pct(agg["reduction_rate"]), pct(agg["cluster_purity"]), pct(agg["over_merge_rate"]),
            num(agg["candidate_precision"], 2), num(agg["candidate_recall"], 2),
            num(agg["top1_precision"], 2), num(agg["gt_mrr"]), pct(agg["top1_hit_rate"])))
    lines += ["", "> 口径与 16-correlation-baseline.py 一致；窗口 %ss，拓扑 %s。" % (
        args.window, os.path.basename(topo) if topo else "事件反推")]
    if no_alert:
        lines.append("> **监控盲区**：%s —— 注入后没有任何告警进入 Alertmanager，无法评测降噪/RCA；这是观测侧的真实缺口。" % ", ".join(r["experiment_id"] for r in no_alert))
    if failures:
        lines.append("> 失败/跳过：%s" % ", ".join(failures))
    io.open(md_out, "w", encoding="utf-8").write("\n".join(lines) + "\n")
    io.open(json_out, "w", encoding="utf-8").write(json.dumps(
        {"window": args.window, "topology": topo, "aggregate": agg, "results": results,
         "no_alert": no_alert, "failures": failures}, ensure_ascii=False, indent=2) + "\n")
    print("  已写出：%s" % md_out)
    print("  已写出：%s" % json_out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
