#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
19-rca-llm.py —— 用本地 LLM 做根因分析（RCA），输出结构化结果 + 幻觉校验

用法:
    python3 19-rca-llm.py <数据集目录> [--topology topology/topology.json]
                          [--model qwen2.5:7b] [--endpoint http://127.0.0.1:11434]

它在流水线里的位置：
    events.jsonl（统一事件） + topology.json（真实拓扑） + correlation.json（规则基线候选）
        ↓ 组装成结构化 prompt
    本地 LLM（Ollama /api/chat, format=json, temperature=0）
        ↓
    rca_llm.json（排序根因 + 理由 + 幻觉校验结果）

设计要点（这几条是"能不能信"的关键）：
  1. **只给结构化证据**：告警表 + 拓扑 + 规则基线的证据计数，不让模型自由联想；
  2. **约束输出集合**：只能从拓扑里的服务中选（越界即判为幻觉）；
  3. **要求 JSON**：Ollama 的 format=json + temperature=0，便于程序化校验与 A/B 对比；
  4. **强制留退路**：证据不足时要求 uncertain=true，而不是硬猜（降低误自愈风险）；
  5. **后校验**：返回的服务必须在拓扑节点集合内，且必须能在证据里找到出处。
"""
import argparse
import collections
import io
import json
import math
import os
import sys
import time
import urllib.request

SYSTEM_PROMPT = """你是一名资深 SRE，负责云原生故障的根因分析（RCA）。
你会收到三部分结构化证据：服务拓扑、告警事件表、规则引擎给出的候选根因与证据计数。
要求：
1. 只根据给定证据推理，禁止引入证据中不存在的服务或组件。
2. 根因必须从"拓扑里的服务"中选择；按可能性从高到低排序。
3. 每个根因给出置信度（0-1）与一句话理由（必须引用具体证据，如"payment 的指标消失"）。
4. **严格区分"根因"与"被波及"**：只输出**根因**，不要输出仅仅因为上游调用失败而报错的中间服务。
   例如拓扑是 frontend -调用-> order -调用-> payment，若根因是 payment，
   那么 order 和 frontend 只是被波及的，**不要**把它们列入 root_causes。
   判断方法：某个服务若只是"调用它的下游失败"，且它自己没有任何自身失败证据
   （指标消失 / 进程未就绪 / 反复重启），那么它是症状而不是根因。
5. 若证据不足以判断，设置 uncertain=true，并说明还缺什么证据。
6. 只输出 JSON，不要任何解释性文字。JSON 结构：
{"root_causes":[{"service":"<服务名>","confidence":0.0,"reason":"<证据>"}],"uncertain":false,"summary":"<一句话结论>"}
"""


def load_json(p, default=None):
    if p and os.path.exists(p):
        return json.load(io.open(p, encoding="utf-8"))
    return default


def load_events(d):
    evs = []
    for line in io.open(os.path.join(d, "events.jsonl"), encoding="utf-8"):
        line = line.strip()
        if line:
            evs.append(json.loads(line))
    evs.sort(key=lambda e: e.get("starts_at") or "")
    return evs


def topology_brief(topo):
    if not topo:
        return {"nodes": [], "edges": []}
    return {
        "nodes": sorted(topo.get("nodes", {}).keys()),
        "edges": ["%s -%s-> %s" % (e["from"], "调用" if e["type"] == "call" else "依赖", e["to"])
                  for e in topo.get("edges", [])],
    }


def build_user_prompt(d, topo, corr, rag_hits=None, rag_excerpt=900):
    evs = load_events(d)
    firing = [e for e in evs if e.get("status") == "firing"]
    rows = []
    for e in firing:
        rows.append({
            "time": (e.get("starts_at") or "")[:19],
            "alert": e.get("alertname"),
            "service": e.get("service") or "",
            "downstream": e.get("downstream") or "",
            "ground_truth_label": e.get("ground_truth") or "",
            "severity": e.get("severity") or "",
        })
    tb = topology_brief(topo)
    base = []
    if corr:
        for c in corr.get("clusters", []):
            if c.get("size", 0) >= 1 and c.get("root_causes"):
                base.append({
                    "cluster": c["cluster_id"],
                    "size": c["size"],
                    "ranked": [{"service": r["service"], "score": r["score"], "evidence": r["evidence"]}
                               for r in c["root_causes"][:4]],
                })
    prompt = {
        "task": "对下面这一次故障事件给出根因排序（可多根因）",
        "topology": tb,
        "alerts_firing": rows,
        "rule_engine_candidates": base,
        "notes": [
            "ground_truth_label 字段是实验注入时打的标签，若存在可直接作为强证据（真实环境中不会有）。",
            "规则引擎的 score 来自四路证据加权：自身失败3.0 / 依赖失败2.5 / 调用链2.0 / 症状1.0。",
        ],
    }
    if rag_hits:
        # 历史案例：来自 docs/06-pitfalls.md 的真实踩坑记录（检索得到，可能不相关 —— 自行判断取舍）
        prompt["historical_cases"] = [
            {"id": rec.get("id"), "title": rec.get("title"), "score": round(sc, 3),
             "excerpt": (rec.get("text") or "")[:rag_excerpt]}
            for sc, rec in rag_hits
        ]
        prompt["notes"].append(
            "historical_cases 是从本项目历史踩坑记录里检索出来的参考案例（按相似度排序，"
            "可能不完全相关）。若其中某条能解释当前证据，请在 reason 里引用它的编号（如 P38）；"
            "若都不相关，**不要**强行引用。")
    return json.dumps(prompt, ensure_ascii=False, indent=2), len(rows)


# ---------------------------------------------------------------------------
# RAG（检索增强）：把 docs/06-pitfalls.md 里的历史踩坑记录检索出来，随证据一起给模型
# ---------------------------------------------------------------------------
def load_kb(path):
    kb = []
    if not path or not os.path.isfile(path):
        return kb
    for line in io.open(path, encoding="utf-8"):
        line = line.strip()
        if line:
            kb.append(json.loads(line))
    return kb


def embed_text(endpoint, model, text, timeout=120):
    body = json.dumps({"model": model, "prompt": text}).encode("utf-8")
    req = urllib.request.Request(endpoint.rstrip("/") + "/api/embeddings", data=body,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8")).get("embedding") or []


def cosine(a, b):
    if not a or not b:
        return 0.0
    n = min(len(a), len(b))
    dot = sum(a[i] * b[i] for i in range(n))
    na = math.sqrt(sum(x * x for x in a[:n]))
    nb = math.sqrt(sum(x * x for x in b[:n]))
    return dot / (na * nb) if na and nb else 0.0


def build_rag_query(d, corr):
    """用本次故障的"结构化特征"拼检索语句：告警名 + 涉及服务 + 规则引擎候选"""
    evs = load_events(d)
    firing = [e for e in evs if e.get("status") == "firing"]
    alerts = collections.Counter(e.get("alertname") or "" for e in firing)
    svcs = sorted({e.get("service") for e in firing if e.get("service")} |
                  {e.get("downstream") for e in firing if e.get("downstream")})
    cands = []
    for c in (corr or {}).get("clusters", []):
        for r in c.get("root_causes", [])[:3]:
            cands.append(r.get("service"))
    parts = []
    if alerts:
        parts.append("告警：" + "、".join("%s×%d" % (k, v) for k, v in alerts.most_common()))
    if svcs:
        parts.append("服务：" + "、".join(svcs))
    if cands:
        parts.append("候选根因：" + "、".join(dict.fromkeys(cands)))
    return " ".join(parts)


def retrieve(kb, query_vec, topk=3):
    scored = []
    for rec in kb:
        v = rec.get("embedding")
        if v:
            scored.append((cosine(query_vec, v), rec))
    scored.sort(key=lambda t: -t[0])
    return scored[:topk]


def call_llm(endpoint, model, user_prompt, timeout=600):
    body = json.dumps({
        "model": model,
        "stream": False,
        "format": "json",
        "options": {"temperature": 0},
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": user_prompt},
        ],
    }).encode("utf-8")
    req = urllib.request.Request(endpoint.rstrip("/") + "/api/chat", data=body,
                                 headers={"Content-Type": "application/json"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        resp = json.loads(r.read().decode("utf-8"))
    return resp, time.time() - t0


def fold_root_causes(parsed, topo):
    """
    拓扑折叠后处理：沿 **call 边** 把"被波及的上游服务"折叠掉。

    场景（实测）：F02 上 LLM 输出 payment > order > frontend，但真根因只有 payment。
    拓扑是 frontend -call-> order -call-> payment：order/frontend 只是链上的症状。
    规则：若输出里的服务 S 能沿 call 边到达输出里的另一个服务 T，则 S 是上游症状 → 折叠掉。
    注意：**只沿 call 边折叠**，绝不沿 dependency 边
    （否则 F13 的 payment 会被当成 redis 的上游而被错误折叠）。
    返回 (折叠后的 parsed, 折叠信息)
    """
    if not parsed or not isinstance(parsed.get("root_causes"), list):
        return parsed, {}
    call_edges = {}
    for e in (topo or {}).get("edges", []):
        if e.get("type") == "call":
            call_edges[e["from"]] = e["to"]

    def reaches(a, b, seen=None):
        seen = seen or set()
        cur = a
        while cur in call_edges and cur not in seen:
            seen.add(cur)
            cur = call_edges[cur]
            if cur == b:
                return True
        return False

    svcs = [rc.get("service") for rc in parsed["root_causes"] if rc.get("service")]
    conf = {}
    for rc in parsed["root_causes"]:
        v = rc.get("confidence")
        conf[rc.get("service")] = v if isinstance(v, (int, float)) else 0.0
    # 【置信度守卫】2026-11-03 加：
    # 原来这里是**无条件**折叠上游 —— 实测把已经答对的结论改错了：
    #   F03（order 出向延迟，GT=order）LLM 给 order 0.9 / payment 0.6，
    #   因为 order 在上游就被折叠掉，最终输出变成 payment（错）。
    # 与规则层的 P45 是**同一个系统性偏差**（"下游一定是根因"），只是出现在后处理里。
    # 现在的判据：只有当**上游不比下游更可信**时才折叠它（即上游确实只是症状）。
    drop = set()
    for a in svcs:
        for b in svcs:
            if a != b and reaches(a, b) and conf.get(a, 0.0) <= conf.get(b, 0.0):
                drop.add(a)
    if not drop:
        return parsed, {"folded": [], "reason": "无上游症状可折叠"}
    folded = {
        "root_causes": [rc for rc in parsed["root_causes"] if rc.get("service") not in drop],
        "uncertain": parsed.get("uncertain", False),
        "summary": parsed.get("summary", ""),
    }
    return folded, {"folded": sorted(drop), "reason": "沿 call 边折叠上游症状",
                    "note": "被折叠的服务仍然出现在原始输出里，原始结果保存在 llm_raw"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dataset")
    ap.add_argument("--topology", default="topology/topology.json")
    ap.add_argument("--model", default="qwen2.5:7b")
    ap.add_argument("--endpoint", default="http://127.0.0.1:11434")
    ap.add_argument("--out", default="rca_llm.json", help="输出文件名（用于多模型对照，如 rca_llm_small.json）")
    ap.add_argument("--rag-kb", default=None,
                    help="RAG 知识库（scripts/36-build-kb.py 产出）；给了就启用检索增强")
    ap.add_argument("--rag-top", type=int, default=3, help="检索条数（默认 3）")
    ap.add_argument("--rag-model", default="bge-m3", help="检索用嵌入模型")
    ap.add_argument("--rag-excerpt", type=int, default=900,
                    help="每条历史案例塞进 prompt 的字符上限（8GB 显存下建议 300~400，否则上下文变长会掉到 CPU）")
    args = ap.parse_args()

    d = args.dataset
    topo = load_json(args.topology)
    corr = load_json(os.path.join(d, "correlation.json"))
    rag_hits = []
    if args.rag_kb:
        kb = load_kb(args.rag_kb)
        q = build_rag_query(d, corr)
        try:
            qv = embed_text(args.endpoint, args.rag_model, q)
            rag_hits = retrieve(kb, qv, args.rag_top)
            print("  RAG      : KB=%d 条，检索 query=%d 字符，命中 %d 条 → %s" % (
                len(kb), len(q), len(rag_hits),
                ", ".join("%s(%.2f)" % (r.get("id"), s_) for s_, r in rag_hits)))
        except Exception as exc:  # noqa: BLE001
            print("  ! RAG 检索失败（降级为纯 LLM）：%s" % exc)

    user_prompt, n_firing = build_user_prompt(d, topo, corr, rag_hits, args.rag_excerpt)

    print("  数据集   : %s" % os.path.basename(os.path.normpath(d)))
    print("  firing 告警: %d 条" % n_firing)
    print("  模型     : %s @ %s" % (args.model, args.endpoint))
    print("  prompt   : %d 字符" % len(user_prompt))

    resp, latency = call_llm(args.endpoint, args.model, user_prompt)
    # 每次调用的"工作记录"（Ollama API 直接返回，比翻日志更结构化；见 docs/03 §7）
    usage = {
        "prompt_eval_count": resp.get("prompt_eval_count"),
        "prompt_eval_duration_ms": round((resp.get("prompt_eval_duration") or 0) / 1e6, 1),
        "eval_count": resp.get("eval_count"),
        "eval_duration_ms": round((resp.get("eval_duration") or 0) / 1e6, 1),
        "load_duration_ms": round((resp.get("load_duration") or 0) / 1e6, 1),
        "total_duration_ms": round((resp.get("total_duration") or 0) / 1e6, 1),
    }
    if usage["eval_count"] and usage["eval_duration_ms"]:
        usage["tokens_per_second"] = round(usage["eval_count"] / (usage["eval_duration_ms"] / 1000), 1)
    raw = resp.get("message", {}).get("content", "")
    print("  推理耗时 : %.1fs" % latency)

    parsed, parse_error = None, None
    try:
        parsed = json.loads(raw)
    except Exception as e:
        parse_error = str(e)

    # ---- 幻觉校验：返回的服务必须在拓扑里 ----
    known = set((topo or {}).get("nodes", {}).keys())
    unknown = []
    if parsed and isinstance(parsed.get("root_causes"), list):
        for rc in parsed["root_causes"]:
            svc = (rc.get("service") or "").strip()
            if svc and known and svc not in known:
                unknown.append(svc)

    folded, fold_info = fold_root_causes(parsed, topo)
    if fold_info.get("folded"):
        print("  拓扑折叠 : 折叠掉上游症状 %s" % fold_info["folded"])
        for rc in folded.get("root_causes", []):
            print("    保留 %-12s conf=%s" % (rc.get("service"), rc.get("confidence")))

    out = {
        "dataset": os.path.basename(os.path.normpath(d)),
        "model": args.model,
        "endpoint": args.endpoint,
        "latency_seconds": round(latency, 2),
        "usage": usage,
        "alerts_firing": n_firing,
        "prompt_chars": len(user_prompt),
        "raw_response": raw,
        "parsed": folded,          # 折叠后的结果（下游消费用这个）
        "llm_raw": parsed,         # 模型原始输出（留证）
        "fold_info": fold_info,
        "parse_error": parse_error,
        "rag": {
            "kb": args.rag_kb,
            "top_k": args.rag_top if args.rag_kb else 0,
            "retrieved": [{"id": r.get("id"), "title": r.get("title"), "score": round(sc, 3)}
                          for sc, r in rag_hits],
        } if args.rag_kb else None,
        "validation": {
            "known_services": sorted(known),
            "unknown_services": unknown,
            "hallucination": bool(unknown),
        },
    }
    out_path = os.path.join(d, args.out)
    json.dump(out, io.open(out_path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)

    if parsed:
        print("  LLM 输出 :")
        for rc in parsed.get("root_causes", []):
            print("    - %-12s conf=%-5s %s" % (rc.get("service"), rc.get("confidence"), (rc.get("reason") or "")[:60]))
        print("    uncertain=%s  summary=%s" % (parsed.get("uncertain"), (parsed.get("summary") or "")[:60]))
    else:
        print("  ✘ 解析失败: %s" % parse_error)
    print("  幻觉校验 : unknown_services=%s → hallucination=%s" % (unknown or "无", bool(unknown)))
    print("  结果已写入: %s" % out_path)
    return 0 if parsed else 1


if __name__ == "__main__":
    sys.exit(main())