#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
22-anomaly-detect.py —— 时序异常检测三层实现（阈值 → MAD → EWMA）

用法: python3 22-anomaly-detect.py <数据集目录> [--mad-k 3.0] [--ewma-alpha 0.3]

输入: <数据集目录>/metrics.json（15-export-dataset.sh 采样的 PromQL query_range 结果）
      <数据集目录>/ground_truth.json（可选，用于算检测延迟、误报数）

为什么三层（而不是只用一个阈值）：
  · **静态阈值**：简单、可解释，但每条序列都要人工定阈值，且对量级变化不鲁棒；
  · **MAD（中位数绝对偏差）**：鲁棒 z-score，对离群点不敏感（相比标准差，不会被异常值自己拉偏），
     适合"这段数据里什么算异常"这种自适应判定；
  · **EWMA**：指数加权移动平均，擅长捕捉"缓慢漂移"——阈值和 MAD 都可能漏掉的渐变故障。
三层并联（任一命中即报），再按"最强证据"排序；同时输出每层各自的命中，便于人工判断。

输出: <数据集>/anomalies.json（每条异常的时间、序列、命中层、值、基线统计），
      控制台给出"检测到的故障窗口 vs ground truth 窗口"的对照。
"""
import argparse
import io
import json
import os
import statistics
import sys
from datetime import datetime, timezone

# 静态阈值表（针对本项目 demo-app 的 SLI；生产环境应从 SLO 推导）
# 每个序列的"最小绝对变化量"：低于它不报（比值判据在低方差序列上会疯狂误报 —— 实测一层就刷出 135 条）
MIN_ABS_DELTA = {
    "5xx_rate": 0.5,
    "downstream_err": 0.02,
    "qps": 2.0,
    "p95_payment": 0.05,
    "pods_ready": 1.0,
}
# 持续性要求：连续命中 N 个采样点才算一个异常事件（去抖，等价于告警规则的 for）
SUSTAIN_POINTS = 3

THRESHOLDS = {
    "5xx_rate":      {"gt": 1.0},     # 每秒 5xx 超过 1 条
    "downstream_err":{"gt": 0.05},    # 下游失败速率 > 0.05/s
    "pods_ready":    {"lt": 9},       # 就绪 Pod 少于 9
}


def load_series(d):
    m = json.load(io.open(os.path.join(d, "metrics.json"), encoding="utf-8"))
    out = {}
    for name, s in (m.get("series") or {}).items():
        res = s.get("result") or []
        pts = []
        if res and isinstance(res[0], dict):
            for v in res[0].get("values", []):
                ts, val = float(v[0]), float(v[1])
                pts.append({"t": ts, "v": val})
        elif res and isinstance(res[0], list):
            for ts, val in res:
                pts.append({"t": float(ts), "v": float(val)})
        if pts:
            out[name] = sorted(pts, key=lambda p: p["t"])
    return out, m.get("window") or {}


def mad_flags(pts, k, series=""):
    vals = [p["v"] for p in pts]
    med = statistics.median(vals)
    dev = [abs(v - med) for v in vals]
    mad = statistics.median(dev) or 1e-9
    # 尺度下限：故障前序列若恒为常数，mad≈0，z 会爆到 1e9（实测 2.7e9，读数完全不可用）。
    # 用"与量级相关的最小尺度"兜底，避免零方差放大。
    scale = max(1.4826 * mad, 0.01 * max(abs(med), 1e-3))
    out = []
    for p in pts:
        z = abs(p["v"] - med) / scale
        if z > k and abs(p["v"] - med) >= MIN_ABS_DELTA.get(series, 0.0):
            out.append((p, round(z, 2), round(med, 4), round(scale, 4)))
    return out


def ewma_flags(pts, alpha, k=3.0, series=""):
    out = []
    if not pts:
        return out
    e = pts[0]["v"]
    hist = []
    for p in pts:
        e = alpha * p["v"] + (1 - alpha) * e
        hist.append(e)
        if len(hist) < 5:
            continue
        window = hist[-20:]
        mu = statistics.mean(window)
        sd = statistics.pstdev(window) or 1e-9
        z = abs(p["v"] - mu) / sd
        if z > k and abs(p["v"] - mu) >= MIN_ABS_DELTA.get(series, 0.0):
            out.append((p, round(z, 2), round(mu, 4), round(e, 4)))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dataset")
    ap.add_argument("--mad-k", type=float, default=3.0)
    ap.add_argument("--ewma-alpha", type=float, default=0.3)
    args = ap.parse_args()
    d = args.dataset

    series, window = load_series(d)
    if not series:
        print("  ✘ metrics.json 里没有可用序列"); return 1

    anomalies, per_layer = [], {}
    for name, pts in series.items():
        # L1 静态阈值
        th = THRESHOLDS.get(name)
        if th:
            for p in pts:
                hit = ("gt" in th and p["v"] > th["gt"]) or ("lt" in th and p["v"] < th["lt"])
                if hit:
                    anomalies.append({"layer": "threshold", "series": name, "t": p["t"], "value": p["v"],
                                      "rule": ("value > %s" % th["gt"]) if "gt" in th else ("value < %s" % th["lt"])})
                    per_layer["threshold"] = per_layer.get("threshold", 0) + 1
        # L2 MAD
        for p, z, med, scale in mad_flags(pts, args.mad_k, name):
            anomalies.append({"layer": "mad", "series": name, "t": p["t"], "value": p["v"],
                              "z": z, "median": med, "scale": scale})
            per_layer["mad"] = per_layer.get("mad", 0) + 1
        # L3 EWMA
        for p, z, mu, e in ewma_flags(pts, args.ewma_alpha, series=name):
            anomalies.append({"layer": "ewma", "series": name, "t": p["t"], "value": p["v"],
                              "z": z, "ewma_mean": mu, "ewma": e})
            per_layer["ewma"] = per_layer.get("ewma", 0) + 1

    anomalies.sort(key=lambda a: a["t"])

    # ---- 持续性 + 事件合并 ----
    # 把 (series, layer) 相同的连续命中合并成一个"异常事件"；
    # 只有连续点数 ≥ SUSTAIN_POINTS 的事件才保留（去抖）。
    raw = anomalies

    # 按 (series, layer) 归组 → 再按时间间隔切窗口。
    # 第一版是"相邻两条同组才合并"，但多序列/多层是**交错**出现的，
    # 连续段会被打断 → 实测 threshold 层 18 个命中一个事件都没留下。
    STEP_HINT = 30.0     # metrics.json 采样步长 30s
    groups = {}
    for a in raw:
        groups.setdefault((a["series"], a["layer"]), []).append(a)

    kept = []
    for (s_name, s_layer), pts in groups.items():
        pts.sort(key=lambda x: x["t"])
        cur = []
        for a in pts:
            if cur and (a["t"] - cur[-1]["t"]) > STEP_HINT * 2.5:
                if len(cur) >= SUSTAIN_POINTS:
                    kept.append({"series": s_name, "layer": s_layer,
                                 "from": cur[0]["t"], "to": cur[-1]["t"], "points": len(cur),
                                 "peak_value": max(x["value"] for x in cur),
                                 "peak_z": max((x.get("z") or 0) for x in cur)})
                cur = []
            cur.append(a)
        if len(cur) >= SUSTAIN_POINTS:
            kept.append({"series": s_name, "layer": s_layer,
                         "from": cur[0]["t"], "to": cur[-1]["t"], "points": len(cur),
                         "peak_value": max(x["value"] for x in cur),
                         "peak_z": max((x.get("z") or 0) for x in cur)})
    anomalies = kept
    first_ts = anomalies[0]["from"] if anomalies else None
    kept.sort(key=lambda e: e["from"])
    anomalies = kept
    first_ts = anomalies[0]["from"] if anomalies else None

    # 与 ground truth 窗口对比：检测延迟
    gt = {}
    gp = os.path.join(d, "ground_truth.json")
    if os.path.exists(gp):
        gt = json.load(io.open(gp, encoding="utf-8"))
    delay = None
    if first_ts and gt.get("injected_at"):
        try:
            t0 = datetime.fromisoformat(gt["injected_at"].replace("Z", "+00:00")).timestamp()
            delay = round(first_ts - t0, 1)
        except Exception:
            pass

    out = {
        "dataset": os.path.basename(os.path.normpath(d)),
        "layers": {"threshold": "静态阈值", "mad": "MAD 鲁棒 z-score(k=%s)" % args.mad_k,
                   "ewma": "EWMA(alpha=%s)" % args.ewma_alpha},
        "window": window,
        "anomaly_count": len(anomalies),
        "raw_hits": len(raw),
        "sustain_points": SUSTAIN_POINTS,
        "min_abs_delta": MIN_ABS_DELTA,
        "per_layer": per_layer,
        "first_anomaly_ts": first_ts,
        "detection_delay_seconds": delay,
        "anomalies": anomalies[:200],
    }
    json.dump(out, io.open(os.path.join(d, "anomalies.json"), "w", encoding="utf-8"),
              ensure_ascii=False, indent=2)

    print("  数据集     : %s" % out["dataset"])
    print("  序列数     : %d（%s）" % (len(series), ", ".join(sorted(series))))
    print("  原始命中   : %d 点 → 经持续性(≥%d 点)过滤后: **%d 个异常事件**" % (len(raw), SUSTAIN_POINTS, len(anomalies)))
    print("  按层命中   : %s" % (per_layer or "无"))
    if first_ts:
        ts = datetime.fromtimestamp(first_ts, tz=timezone.utc).strftime("%H:%M:%S")
        print("  首次异常   : %s UTC   检测延迟(相对注入): %s s" % (ts, delay))
    for e in anomalies[:8]:
        print("    [%-9s] %-16s %s → %s  持续%d点  峰值=%s  peak_z=%s" % (
            e["layer"], e["series"],
            datetime.fromtimestamp(e["from"], tz=timezone.utc).strftime("%H:%M:%S"),
            datetime.fromtimestamp(e["to"], tz=timezone.utc).strftime("%H:%M:%S"),
            e["points"], round(e["peak_value"], 4), e["peak_z"]))
    print("  结果已写入 : %s/anomalies.json" % d)
    return 0


if __name__ == "__main__":
    sys.exit(main())