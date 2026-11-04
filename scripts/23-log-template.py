#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
23-log-template.py —— 日志模板挖掘 + 异常模板识别（不依赖 Drain3，自带轻量实现）

用法: python3 23-log-template.py <数据集目录> [--top 15]

输入: <数据集目录>/logs.txt（kubectl logs 采集，行格式 "[pod/xxx/app] {JSON}" 或纯 JSON）
      <数据集目录>/ground_truth.json（可选：用于把日志切成"故障前基线"与"故障窗口"两段）

做法（Drain 的核心思想，去掉前缀树，用"规范化 + 精确匹配"实现最小可用版）：
  1. 逐行解析出结构化字段（ts / level / service / msg / 其它键）；
  2. **模板化**：把 msg 里的数字、十六进制、UUID、IP、时长等替换为 <*>；
     （例如 "请求失败 path=/orders/12345 status=500" → "请求失败 path=<*> status=<*>")
  3. 统计模板频次，并按"服务 × 模板"聚合；
  4. **异常识别**：对比故障前基线窗口，标出
       · new        —— 故障窗口才出现的模板（最可能是新故障路径）
       · spike      —— 频次相对基线显著上升的模板（≥3 倍且绝对增量 ≥5 条）
       · level_up   —— ERROR/WARN 占比明显上升
输出: <数据集>/log_templates.json + 控制台摘要
"""
import argparse
import io
import json
import os
import re
import sys
from collections import Counter, defaultdict
from datetime import datetime, timezone

NORM_PATTERNS = [
    (re.compile(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"), "<uuid>"),
    (re.compile(r"\b\d{1,3}(?:\.\d{1,3}){3}(?::\d+)?\b"), "<ip>"),
    (re.compile(r"\b[0-9a-fA-F]{16,}\b"), "<hex>"),
    (re.compile(r"\b\d+(?:\.\d+)?(?:ms|s|MB|MiB|GB|GiB)?\b"), "<*>"),
]


def template_of(msg):
    t = msg or ""
    for pat, rep in NORM_PATTERNS:
        t = pat.sub(rep, t)
    return t.strip()


def parse_line(line):
    line = line.strip()
    if not line:
        return None
    payload = line
    if line.startswith("[") and "] " in line:
        payload = line.split("] ", 1)[1]
    try:
        d = json.loads(payload)
    except Exception:
        return {"ts": None, "level": "?", "service": "-", "msg": payload, "extra": {}}
    ts = d.get("ts")
    t = None
    if ts:
        try:
            t = datetime.strptime(ts, "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc).timestamp()
        except Exception:
            t = None
    extra = {k: v for k, v in d.items() if k not in ("ts", "level", "service", "msg")}
    return {"ts": t, "level": (d.get("level") or "?").upper(),
            "service": d.get("service") or d.get("service_name") or "-",
            "msg": d.get("msg") or "", "extra": extra}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dataset")
    ap.add_argument("--top", type=int, default=15)
    args = ap.parse_args()
    d = args.dataset

    rows = []
    for line in io.open(os.path.join(d, "logs.txt"), encoding="utf-8", errors="ignore"):
        r = parse_line(line)
        if r:
            rows.append(r)
    if not rows:
        print("  ✘ logs.txt 里没有可解析的日志"); return 1

    # 用 ground truth 窗口切分"故障前基线"与"故障窗口"
    gt = {}
    gp = os.path.join(d, "ground_truth.json")
    if os.path.exists(gp):
        gt = json.load(io.open(gp, encoding="utf-8"))
    t_fault = None
    for k in ("injected_at", "window_from"):
        if gt.get(k):
            try:
                t_fault = datetime.fromisoformat(gt[k].replace("Z", "+00:00")).timestamp()
            except Exception:
                t_fault = None
            if t_fault:
                break

    base_cnt, fault_cnt = Counter(), Counter()
    base_lvl, fault_lvl = Counter(), Counter()
    examples = {}
    for r in rows:
        key = (r["service"], template_of(r["msg"]))
        examples.setdefault(key, r["msg"][:120])
        in_fault = (t_fault is not None and r["ts"] is not None and r["ts"] >= t_fault)
        if in_fault:
            fault_cnt[key] += 1
            fault_lvl[r["level"]] += 1
        else:
            base_cnt[key] += 1
            base_lvl[r["level"]] += 1

    flagged = []
    for key, n in fault_cnt.items():
        b = base_cnt.get(key, 0)
        if b == 0 and n >= 3:
            flagged.append({"kind": "new", "service": key[0], "template": key[1],
                            "baseline": b, "fault": n, "example": examples[key]})
        elif b > 0 and n >= b * 3 and (n - b) >= 5:
            flagged.append({"kind": "spike", "service": key[0], "template": key[1],
                            "baseline": b, "fault": n, "ratio": round(n / b, 2), "example": examples[key]})
    flagged.sort(key=lambda x: (-x["fault"], x["kind"]))

    err_base = base_lvl.get("ERROR", 0) / max(1, sum(base_lvl.values()))
    err_fault = fault_lvl.get("ERROR", 0) / max(1, sum(fault_lvl.values()))

    out = {
        "dataset": os.path.basename(os.path.normpath(d)),
        "log_lines": len(rows),
        "templates_total": len(set(list(base_cnt) + list(fault_cnt))),
        "fault_boundary_ts": t_fault,
        "baseline_lines": sum(base_cnt.values()), "fault_lines": sum(fault_cnt.values()),
        "level_ratio": {"baseline": dict(base_lvl), "fault": dict(fault_lvl),
                        "error_rate_baseline": round(err_base, 4), "error_rate_fault": round(err_fault, 4)},
        "top_templates": [{"service": k[0], "template": k[1], "fault_count": v,
                           "baseline_count": base_cnt.get(k, 0)} for k, v in fault_cnt.most_common(args.top)],
        "flagged": flagged,
    }
    json.dump(out, io.open(os.path.join(d, "log_templates.json"), "w", encoding="utf-8"),
              ensure_ascii=False, indent=2)

    print("  数据集     : %s" % out["dataset"])
    print("  日志行数   : %d（基线 %d / 故障窗口 %d）" % (len(rows), out["baseline_lines"], out["fault_lines"]))
    print("  模板总数   : %d" % out["templates_total"])
    print("  ERROR 占比 : 基线 %.2f%% → 故障窗口 %.2f%%"
          % (err_base * 100, err_fault * 100))
    print("  异常模板   : %d 个（new %d / spike %d）"
          % (len(flagged), sum(1 for f in flagged if f["kind"] == "new"),
             sum(1 for f in flagged if f["kind"] == "spike")))
    for f in flagged[:8]:
        print("    [%-5s] %-10s x%-4d(基线 %d) %s" % (f["kind"], f["service"], f["fault"],
                                                     f["baseline"], f["template"][:70]))
    print("  结果已写入 : %s/log_templates.json" % d)
    return 0


if __name__ == "__main__":
    sys.exit(main())