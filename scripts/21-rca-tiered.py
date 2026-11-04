#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
21-rca-tiered.py —— 两级模型 RCA：小模型初筛 + 大模型复核

用法:
    python3 21-rca-tiered.py <数据集目录> [--topology topology/topology.json]
                             [--small qwen3:0.6b] [--large qwen2.5:7b]
                             [--endpoint http://127.0.0.1:11434]

为什么做两级（AI Infra 视角的取舍）：
  · 7B 的单次 RCA 要 3~35s（取决于 prompt 长度），而真实告警量往往是每分钟几十到几百条；
  · 0.6B 虽然推理质量弱，但"这条告警要不要做 RCA / 大概是哪类故障 / 可能涉及哪几个服务"这类
    **分类与筛选任务**它够用，而且便宜（参数量差 12 倍）。
  · 于是：**0.6B 初筛（便宜、可高频）→ 只有 need_rca=true 才交给 7B 复核（贵、精）**，
    并把初筛给出的候选服务作为 7B 的**约束**，减少它跑到无关服务上（降幻觉、提精确率）。

两级流水线：
  Tier1 (0.6B): 输入精简证据 → {"need_rca":bool,"fault_type":str,"candidates":[...]}
  Tier2 (7B)  : 仅当 need_rca=true → 完整证据 + 初筛候选约束 → 根因排序（复用 19 的 prompt 与折叠）
输出: <数据集>/rca_tiered.json（含两级的原始输出、耗时与最终排序）
"""
import argparse
import io
import json
import os
import sys
import time
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import importlib.util

_spec = importlib.util.spec_from_file_location(
    "rca_llm", os.path.join(os.path.dirname(os.path.abspath(__file__)), "19-rca-llm.py"))
rca = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(rca)

TRIAGE_SYSTEM = """你是 SRE 告警初筛助手。只做三件事：判断是否需要根因分析、判断故障类型、挑出最多 3 个可疑服务。
只输出 JSON，不要解释。结构：
{"need_rca":true,"fault_type":"pod_failure|dependency|network|cascade|resource|unknown","candidates":["服务名"]}
规则：
- 若确有服务异常（指标消失/错误率升高/依赖失败），need_rca=true；纯噪声（如自身监控自检）为 false。
- candidates 只能从给定服务清单里挑，最多 3 个，按可疑程度排序。
"""


def build_triage_prompt(d, topo):
    evs = rca.load_events(d)
    firing = [e for e in evs if e.get("status") == "firing"]
    lines = []
    for e in firing[:25]:
        parts = [e.get("alertname") or "?"]
        if e.get("service"):
            parts.append("service=%s" % e["service"])
        if e.get("downstream"):
            parts.append("downstream=%s" % e["downstream"])
        lines.append("- " + " ".join(parts))
    tb = rca.topology_brief(topo)
    prompt = {
        "服务清单": tb["nodes"],
        "拓扑": tb["edges"],
        "告警(firing)": lines,
        "告警条数": len(firing),
    }
    return json.dumps(prompt, ensure_ascii=False, indent=2), len(firing)


def usage_of(resp):
    """把 Ollama 的耗时/token 字段整理成"工作记录"（与 19 号脚本口径一致）"""
    u = {
        "prompt_eval_count": resp.get("prompt_eval_count"),
        "eval_count": resp.get("eval_count"),
        "load_duration_ms": round((resp.get("load_duration") or 0) / 1e6, 1),
        "prompt_eval_duration_ms": round((resp.get("prompt_eval_duration") or 0) / 1e6, 1),
        "eval_duration_ms": round((resp.get("eval_duration") or 0) / 1e6, 1),
        "total_duration_ms": round((resp.get("total_duration") or 0) / 1e6, 1),
    }
    if u["eval_count"] and u["eval_duration_ms"]:
        u["tokens_per_second"] = round(u["eval_count"] / (u["eval_duration_ms"] / 1000), 1)
    return u


def chat(endpoint, model, system, user, timeout=600):
    body = json.dumps({
        "model": model, "stream": False, "format": "json",
        "options": {"temperature": 0},
        "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
    }).encode("utf-8")
    req = urllib.request.Request(endpoint.rstrip("/") + "/api/chat", data=body,
                                 headers={"Content-Type": "application/json"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        resp = json.loads(r.read().decode("utf-8"))
    return resp.get("message", {}).get("content", ""), time.time() - t0, usage_of(resp)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dataset")
    ap.add_argument("--topology", default="topology/topology.json")
    ap.add_argument("--small", default="qwen3:0.6b")
    ap.add_argument("--large", default="qwen2.5:7b")
    ap.add_argument("--endpoint", default="http://127.0.0.1:11434")
    args = ap.parse_args()

    d = args.dataset
    topo = rca.load_json(args.topology)
    corr = rca.load_json(os.path.join(d, "correlation.json"))

    print("  数据集     : %s" % os.path.basename(os.path.normpath(d)))
    print("  Tier1 初筛 : %s" % args.small)
    triage_prompt, n_firing = build_triage_prompt(d, topo)
    print("  Tier1 prompt: %d 字符（%d 条 firing 告警）" % (len(triage_prompt), n_firing))

    t1_raw, t1_lat, t1_usage = chat(args.endpoint, args.small, TRIAGE_SYSTEM, triage_prompt)
    try:
        triage = json.loads(t1_raw)
    except Exception:
        triage = {}
    need = bool(triage.get("need_rca", True))
    # 小模型常返回重复项或"管道枚举"（如 "pod_failure|dependency"），这里做规范化：
    #   ① 候选去重且最多 3 个；② fault_type 只取第一个枚举值。
    cands = list(dict.fromkeys([c.strip() for c in (triage.get("candidates") or [])
                                if isinstance(c, str) and c.strip()]))[:3]
    ft = (triage.get("fault_type") or "").split("|")[0].strip()
    if ft:
        triage["fault_type"] = ft
    print("  Tier1 输出 : need_rca=%s fault_type=%s candidates=%s  (%.1fs)"
          % (need, triage.get("fault_type"), cands, t1_lat))

    result = {
        "dataset": os.path.basename(os.path.normpath(d)),
        "small_model": args.small, "large_model": args.large,
        "tier1": {"raw": t1_raw, "parsed": triage, "latency_seconds": round(t1_lat, 2),
                  "prompt_chars": len(triage_prompt), "usage": t1_usage},
        "tier2": None, "final_root_causes": [], "latency_total_seconds": round(t1_lat, 2),
        "skipped_tier2": not need,
    }

    if need:
        # Tier2：完整证据 + 初筛候选作为约束（写进 notes，让 7B 优先在这些服务里选）
        full_prompt, _ = rca.build_user_prompt(d, topo, corr)
        if cands:
            full_prompt += "\n\n【初筛建议（0.6B 给出的可疑服务，请优先在这些服务里找根因，但若证据指向别处可以推翻）】\n" \
                           + json.dumps(cands, ensure_ascii=False)
        raw2, lat2, t2_usage = chat(args.endpoint, args.large, rca.SYSTEM_PROMPT, full_prompt)
        try:
            parsed2 = json.loads(raw2)
        except Exception:
            parsed2 = None
        folded, fold_info = rca.fold_root_causes(parsed2, topo)
        known = set((topo or {}).get("nodes", {}).keys())
        unknown = [rc.get("service") for rc in ((folded or {}).get("root_causes") or [])
                   if rc.get("service") and known and rc["service"] not in known]
        result["tier2"] = {"raw": raw2, "parsed": folded, "llm_raw": parsed2,
                           "fold_info": fold_info, "latency_seconds": round(lat2, 2), "usage": t2_usage,
                           "prompt_chars": len(full_prompt),
                           "unknown_services": unknown}
        result["final_root_causes"] = [rc["service"] for rc in ((folded or {}).get("root_causes") or [])]
        result["latency_total_seconds"] = round(t1_lat + lat2, 2)
        print("  Tier2 输出 : %s  (%.1fs)" % (" > ".join(result["final_root_causes"]) or "-", lat2))
        print("  Tier2 折叠 : %s" % (fold_info.get("folded") or "无"))
        print("  幻觉校验   : %s" % (unknown or "无"))
    else:
        print("  Tier2 跳过 : 初筛判定为无需 RCA（这就是两级机制省钱的地方）")

    print("  总延迟     : %.2fs（Tier1 %.2f + Tier2 %s）"
          % (result["latency_total_seconds"], t1_lat,
             "%.2f" % (result["tier2"]["latency_seconds"] if result["tier2"] else 0)))
    out = os.path.join(d, "rca_tiered.json")
    json.dump(result, io.open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    print("  结果已写入 : %s" % out)
    return 0


if __name__ == "__main__":
    sys.exit(main())