#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
34-check-metric-contracts.py —— 指标契约自检（防 P38 复现）

为什么需要它（P38 的教训）：
    `downstream_duration_seconds` 曾被"累积的累积"写坏了两天没人发现 ——
    桶计数随 le 线性递增、`le="+Inf"` 反而小于上界桶、histogram_quantile 把 10ms 算成 7.25s。
    它能潜伏，是因为**没有任何规则/面板消费它**；等第一条规则用它时，直接在空闲状态全线误报。
    结论：**没有被消费的指标 = 没有被验证的指标**。

契约（直方图的三条基本不变量）：
    C1 桶单调：le 从小到大，累计计数**单调不减**
    C2 总量一致：`le="+Inf"` 的计数 **==** `_count`
    C3 量级合理：均值（`_sum/_count`）与 P95 **同量级**（比值不超过阈值），
       出现"均值 18ms 而 P95 7.5s"这种自相矛盾就是坏数据

用法:
    python3 34-check-metric-contracts.py --prom http://127.0.0.1:30090
    python3 34-check-metric-contracts.py --prom http://<节点IP>:30090 --json-out /tmp/contracts.json

退出码：0 = 全部通过；1 = 有违反（可直接用于 CI / 提交前）
"""
import argparse
import json
import sys
import urllib.parse
import urllib.request


# 需要体检的直方图家族（当前系统里被业务规则消费的）
FAMILIES = [
    "http_request_duration_seconds",
    "downstream_duration_seconds",
]

# 均值与 P95 的最大允许倍数（超过就认为自相矛盾）
MAX_MEAN_P95_RATIO = 50.0


def query(prom, expr):
    url = prom.rstrip("/") + "/api/v1/query?" + urllib.parse.urlencode({"query": expr})
    with urllib.request.urlopen(url, timeout=15) as r:
        d = json.load(r)
    if d.get("status") != "success":
        raise RuntimeError("查询失败: %s" % d)
    return d["data"]["result"]


def labels_key(metric, drop=("le", "__name__")):
    # 注意：Prometheus API 返回的 metric 里含 __name__（指标名），
    # _count / _bucket / _sum 的名字当然不同 —— 不做对比的话永远匹配不上（本人踩过）。
    return tuple(sorted((k, v) for k, v in metric.items() if k not in drop))


def check_family(prom, fam):
    """返回 (violations, checked_series)"""
    violations = []
    counts = query(prom, fam + "_count")
    if not counts:
        return violations, 0
    count_by_key = {}
    for s in counts:
        count_by_key[labels_key(s["metric"])] = float(s["value"][1])

    buckets = query(prom, fam + "_bucket")
    grouped = {}
    for s in buckets:
        k = labels_key(s["metric"])
        grouped.setdefault(k, []).append((s["metric"].get("le"), float(s["value"][1])))

    sums = {}
    for s in query(prom, fam + "_sum"):
        sums[labels_key(s["metric"])] = float(s["value"][1])

    checked = 0
    for k, items in grouped.items():
        # 排序：+Inf 最大
        def le_key(t):
            le = t[0]
            if le in ("+Inf", "inf"):
                return float("inf")
            try:
                return float(le)
            except (TypeError, ValueError):
                return float("inf")
        items.sort(key=le_key)
        checked += 1
        tag = dict(k)
        name = "%s%s" % (fam, tag)

        # C1 桶单调
        prev, prev_le = None, None
        for le, v in items:
            if prev is not None and v < prev - 1e-9:
                violations.append(("C1 桶单调", name, "le=%s 的计数 %s 小于 le=%s 的 %s" % (le, v, prev_le, prev)))
            prev, prev_le = v, le

        # C2 +Inf == count
        inf_v = None
        for le, v in items:
            if le in ("+Inf", "inf"):
                inf_v = v
        cnt = count_by_key.get(k)
        if inf_v is None:
            violations.append(("C2 总量一致", name, "缺少 le=\"+Inf\" 桶"))
        elif cnt is None:
            violations.append(("C2 总量一致", name, "缺少 _count 对应序列"))
        elif abs(inf_v - cnt) > max(1.0, 0.001 * max(cnt, 1.0)):
            violations.append(("C2 总量一致", name, "le=+Inf=%s 与 _count=%s 不一致" % (inf_v, cnt)))

        # C3 量级合理：均值 vs P95
        ssum = sums.get(k)
        if ssum is not None and cnt and cnt > 0:
            mean = ssum / cnt
            q = query(prom,
                      "histogram_quantile(0.95, sum by (le) (rate(%s_bucket{%s}[5m])))" % (
                          fam, ",".join('%s="%s"' % (kk, vv) for kk, vv in k if vv != "")))
            p95 = float(q[0]["value"][1]) if q else None
            if p95 is not None and mean > 0:
                ratio = max(mean, p95) / max(min(mean, p95), 1e-9)
                if ratio > MAX_MEAN_P95_RATIO:
                    violations.append(("C3 量级合理", name,
                                       "均值 %.4fs 与 P95 %.4fs 相差 %.0f 倍（自相矛盾）" % (mean, p95, ratio)))
    return violations, checked


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--prom", default="http://127.0.0.1:30090")
    ap.add_argument("--json-out", default=None)
    args = ap.parse_args()

    print("=" * 74)
    print("指标契约自检  (prom=%s)" % args.prom)
    print("=" * 74)
    all_v, total = [], 0
    for fam in FAMILIES:
        try:
            v, n = check_family(args.prom, fam)
        except Exception as exc:  # noqa: BLE001
            print("  ✘ %-34s 查询失败：%s" % (fam, exc))
            all_v.append(("查询失败", fam, str(exc)))
            continue
        total += n
        if v:
            print("  ✘ %-34s 检查 %d 条序列，**%d 项违反**" % (fam, n, len(v)))
            for c, name, msg in v:
                print("       [%s] %s" % (c, msg))
        else:
            print("  ✔ %-34s 检查 %d 条序列，全部通过（桶单调 / +Inf==count / 量级合理）" % (fam, n))
        all_v.extend(v)

    print()
    if not total:
        print("! 没有查到任何直方图序列（Prometheus 里还没有数据？）")
        return 1
    if all_v:
        print("✘ 共 %d 项违反指标契约 —— 这些指标之上的告警/面板**都不可信**" % len(all_v))
        if args.json_out:
            json.dump([{"check": c, "series": n, "msg": m} for c, n, m in all_v],
                      open(args.json_out, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
        return 1
    print("✔ 全部通过：%d 条直方图序列均满足契约。" % total)
    return 0


if __name__ == "__main__":
    sys.exit(main())
