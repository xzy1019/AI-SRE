#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
16-correlation-baseline.py —— 告警降噪：基线 + 第一段（时间窗口聚类），只读

用法:
    python3 16-correlation-baseline.py <数据集目录> [--window 90] [--no-cluster]

输入: <数据集目录>/events.jsonl（aisre-ingest 产出的统一 Event 模型）
        <数据集目录>/ground_truth.json（可选，用于判定"是否指向正确根因"）

输出: 控制台表格 + <数据集目录>/correlation.json

两档对照（同一份数据，唯一的区别是有没有做聚类）:
  ① 基线   --no-cluster : 每条 firing 告警 = 1 个事件簇  → 降噪率 0%
  ② 方案A  （默认）     : 同命名空间、时间相邻（≤ window 秒）的告警并成一簇

四个指标（这就是"降噪的体现"）:
  降噪率     = 1 - 簇数/告警数            —— 值班人要看的东西少了多少
  簇纯度     = 簇内同根因告警的占比        —— 有没有把不相干的告警硬凑在一起
  过度合并率 = 簇内出现多个不同候选根因的比例 —— 最危险的错误（把两个故障揉成一个）
  根因命中率 = 簇的候选根因 == ground truth 的比例

根因候选的推断规则（第一版，写清楚便于质疑与迭代）:
  · DemoAppScrapeDown           → 候选 = service（这个服务的指标消失了）
  · 带 downstream 标签的告警     → 候选 = downstream（"我调下游失败" ⇒ 问题更可能在下游）
  · 其它                        → 候选 = service
"""
import io
import json
import os
import sys
from datetime import datetime, timezone

WINDOW_DEFAULT = 90

# 本次载入时折叠掉的重复告警数（由 load_events 回填，写进结果便于审计）
COLLAPSED_DUPLICATES = 0


def norm_service(s):
    """
    服务名归一化：数据集里的 ground truth 习惯写成 payment-service，
    而告警标签/拓扑节点是 payment。不归一化就会出现"明明命中却算 0%"的假阴性。
    """
    if not s:
        return ""
    s = s.strip().lower()
    for suffix in ("-service", "_service", "service"):
        if s.endswith(suffix) and len(s) > len(suffix):
            s = s[: -len(suffix)]
            break
    return s.rstrip("-_")


def parse_args(argv):
    if len(argv) < 2:
        print(__doc__)
        sys.exit(2)
    d = argv[1]
    window = WINDOW_DEFAULT
    cluster = True
    topo = None
    gt_override = None
    i = 2
    while i < len(argv):
        if argv[i] == "--window":
            window = int(argv[i + 1]); i += 2
        elif argv[i] == "--no-cluster":
            cluster = False; i += 1
        elif argv[i] == "--topology":
            topo = argv[i + 1]; i += 2
        elif argv[i] == "--gt":
            gt_override = argv[i + 1]; i += 2
        else:
            print("未知参数: %s" % argv[i]); sys.exit(2)
    return d, window, cluster, topo, gt_override


def ts(s):
    if not s:
        return None
    s = s.replace("Z", "+00:00")
    try:
        return datetime.fromisoformat(s).astimezone(timezone.utc)
    except Exception:
        return None


def build_topology(evs):
    """
    从事件自身反推调用拓扑：带 downstream 的告警就是一条边 service → downstream。
    这一步是"降噪第 2 段（拓扑关联合并）"的最小可用版本：
    没有它，级联故障会被误判成"多个根因混在一个簇里"（见下方 break_down）。

    【第一版踩的坑，留证】
    最初的候选根因规则是：有 downstream 取 downstream、否则取自己的 service。
    在合成对照数据上立刻暴露问题：一次 payment 故障引发
      DemoAppScrapeDown(payment) / DemoAppDownstreamFailure(order→payment) /
      DemoAppHighErrorRate(order) / DemoAppHighErrorRate(frontend)
    会被算成 payment / payment / order / frontend 四个"不同根因"，
    于是"簇纯度 50%、过度合并率 50%"——**把一条级联链错判成了过度合并**。
    修正：沿拓扑把每个告警下钻到"最深的下游"，整条链才会收敛到同一个根因。
    """
    edges = {}
    for e in evs:
        s, d = e.get("service"), e.get("downstream")
        # 只有"我调用下游失败"这类告警才表达调用拓扑；
        # DemoAppDependencyDown(payment → redis) 表达的是"我依赖 redis"，
        # 若也当成调用边，会把整条链错误地拽到 redis（第二版实测踩到过）。
        if s and d and e.get("alertname") == "DemoAppDownstreamFailure":
            edges.setdefault(s, d)
    return edges


def load_topology_file(path):
    """
    读取 17-collect-topology.sh 采集的真实拓扑。边分两类：
      · call       : 调用边（order 调 payment）—— 症状沿它下钻
      · dependency : 依赖边（payment 依赖 redis）—— 只用于"依赖不可用"类告警的归因
    这个区分是本轮修正的核心：第一版把依赖边当调用边，导致整条级联链被拽到 redis。
    """
    t = json.load(io.open(path, encoding="utf-8"))
    call = {e["from"]: e["to"] for e in t.get("edges", []) if e.get("type") == "call"}
    dep = {(e["from"], e["to"]) for e in t.get("edges", []) if e.get("type") == "dependency"}
    nodes = set(t.get("nodes", {}).keys())
    return call, dep, nodes


EVIDENCE_WEIGHTS = {
    "self":       3.0,   # E1 自身失败：指标消失/未就绪/反复重启 —— 最强证据
    "dependency": 2.5,   # E2 依赖失败：我调不通我的依赖 —— 指向依赖
    "call":       2.0,   # E3 调用链失败：我调不通下游 —— 指向下游子树
    "symptom":    1.0,   # E4 症状：错误率/延迟升高 —— 只说明"这里难受"，不说明根在哪
    "other":      0.5,
}


def evidence_type(e, dep_edges=None):
    """
    给每条告警标注它属于哪一类证据（四路证据的最小实现，对应设计文档 §7.3）。
    权重差异是这套打分的核心：**自身的失败证据(3.0) 要能压过链上的症状(1.0)**，
    否则"下游最深的那个服务"永远会赢，而那可能只是症状的终点。
    """
    a = e.get("alertname", "")
    if a in ("DemoAppScrapeDown", "PodNotReady", "PodRestartingFrequently", "PodCrashLooping"):
        return "self"
    if a == "DemoAppDependencyDown":
        return "dependency"
    if a in ("DemoAppDownstreamFailure", "DemoAppDownstreamFailureFast"):
        svc, down = e.get("service"), e.get("downstream")
        if dep_edges and svc and down and (svc, down) in dep_edges:
            return "dependency"
        return "call"
    # 【2026-11-03 补：新规则也要有证据分类】（P43）
    # 新增规则若都落到 "other"(0.5)，会被旧症状规则(1.0)压住 —— 规则加了等于白加。
    if a == "DemoAppDownstreamLatencyHigh":
        # 边上的延迟：属于"调用链"证据（指向这条边），不是纯症状
        return "call"
    if a in ("ContainerCPUHigh", "ContainerMemoryHigh"):
        # 容器资源被压（CPU / 内存）：这是**自身失败**类证据（和数据层 ScrapeDown 同级）
        return "self"
    if a in ("DemoAppHighErrorRate", "DemoAppHighLatency", "DemoAppHighErrorRateFast",
             "DemoAppTrafficCollapse"):
        return "symptom"
    return "other"


def deepest(node, edges, seen=None):
    """沿 service → downstream 走到最深（带环保护）"""
    seen = seen or set()
    cur = node
    while cur in edges and edges[cur] not in seen:
        seen.add(cur)
        cur = edges[cur]
    return cur


def pod_to_service(pod, topo_nodes=None):
    """
    把 Pod 名还原成服务名（资源类告警需要）。
    为什么需要：cAdvisor 的容器指标**只有 pod/container 标签，没有 service 标签**，
    于是 ContainerCPUHigh 这类告警的 service 字段是空的、推断会落到 unknown（P43）。
    还原规则（先准后糙）：
      1) 拓扑节点集合里有能匹配的前缀 → 取最长的那个（最可靠）
      2) 否则取第一段：demo-app 的命名是 <app>-<rs span hash>-<suffix> / <app>-<index>
    """
    if not pod:
        return None
    if topo_nodes:
        for n in sorted(topo_nodes, key=len, reverse=True):
            if pod == n or pod.startswith(n + "-"):
                return n
    return pod.split("-")[0] or None


def candidates(e, edges, dep_edges=None, topo_nodes=None):
    """
    返回**候选集合**（而不是唯一答案）。

    按告警语义分四类，避免"一刀切下钻"（第二版实测把 payment 故障拽到了 redis）:
      · 依赖不可用 (DemoAppDependencyDown)        → 根因就是那个依赖
      · 自身指标消失 (DemoAppScrapeDown)          → 根因就是该服务自己（不下钻）
      · 资源被压 (ContainerCPUHigh)              → 自身失败类；无 service 时用 pod 名还原
      · 调用边上的告警 (Downstream* + downstream) → **候选集合 = {最深下游, 调用方}**
        理由："A→B 这条边不健康"无法从告警本身区分"A 的出向路径坏"还是"B 变慢"，
        给出两端才是诚实的答案（复用 P16 的候选集合口径）。
        主候选仍取"最深下游"，以保持原有排序行为稳定。
      · 其余（错误率 / 延迟 / 流量塌陷）           → 症状，沿调用链下钻到最深下游
    """
    a = e.get("alertname", "")
    svc, down = e.get("service"), e.get("downstream")
    dep_edges = dep_edges or set()
    if not svc:
        svc = pod_to_service(e.get("pod"), topo_nodes)   # 资源类：从 pod 还原服务
    if a == "DemoAppDependencyDown" and down:
        return [down]
    # 显式依赖失败（有真实 dependency 边佐证）→ 根因就是那个依赖
    if down and svc and (svc, down) in dep_edges and a in ("DemoAppDownstreamFailure",
                                                          "DemoAppDownstreamFailureFast",
                                                          "DemoAppDependencyDown"):
        return [down]
    if a == "DemoAppScrapeDown" and svc:
        return [svc]
    if a in ("ContainerCPUHigh", "ContainerMemoryHigh") and svc:
        return [svc]          # 资源压力 = 自身失败信号，不下钻
    # 【边类告警已经"自带判责"，降噪层据此收敛候选】
    # 规则 DemoAppDownstreamLatencyHigh 在 2026-11-03 之后**只在被调方自身 P95 正常时才 firing**
    # （见 _prometheus-rules.yml 里的 and on(downstream) label_replace 条件）。
    # 也就是说：这条告警出现 ⇒ "被调方是健康的" 已经由规则保证 ⇒ 根因在**调用方的出向路径**。
    # 因此候选 = 调用方自己（而不是两端）—— 被调方已被证据排除，放进候选反而是冤枉。
    # 历史说明：这条规则第一版没有判责条件，导致 F05（payment 分区）里它也会 firing，
    #   把 payment 之外的 order 带进候选集合（过度合并 50%）。加判责后 F05 不再误报该告警。
    if a == "DemoAppDownstreamLatencyHigh" and svc:
        return [svc]
    if down:
        return [deepest(down, edges)]
    if svc:
        return [deepest(svc, edges)]
    return ["unknown"]


def candidate(e, edges, dep_edges=None, topo_nodes=None):
    """单值接口（保留给历史调用/展示）：取候选集合的第一个作为主候选"""
    return candidates(e, edges, dep_edges, topo_nodes)[0]


def load_events(d, topo_path=None):
    path = os.path.join(d, "events.jsonl")
    evs = []
    raw = []
    with io.open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            e = json.loads(line)
            if e.get("status") != "firing":
                continue
            e["_t"] = ts(e.get("starts_at")) or ts(e.get("received_at"))
            raw.append(e)
    if topo_path:
        edges, dep_edges, topo_nodes = load_topology_file(topo_path)   # 真实拓扑（推荐）
    else:
        edges, dep_edges, topo_nodes = build_topology(raw), set(), None   # 回退：从告警反推（旧口径）
    for e in raw:
        e["_cands"] = candidates(e, edges, dep_edges, topo_nodes)
        e["_cand"] = e["_cands"][0]        # 主候选（排序用），保持原行为
        e["_evi"] = evidence_type(e, dep_edges)

    # 【边瓶颈截断】—— 解决"沿链下沉把症状全送到链尾"的系统性偏差
    # 场景（F03 实测）：注入的是 order 的出向延迟，但级联症状（frontend 错误率、
    #   frontend→order 调用失败…）都会沿拓扑**一路下沉到 payment**，把 payment 的分数堆到 7.0，
    #   而真正的瓶颈 order 只拿到 1 条边告警的 2.0 —— Top-1 因此指向被调方。
    # 判据：若某条调用边 A→B 上有"**被调方健康**的边延迟告警"（规则已保证），
    #   说明瓶颈在 A 的出向路径 ⇒ 所有"**穿过 A→B**"的症状/调用证据应**截断在 A**，不再继续下沉。
    # 注意：`self` 类证据（如 DemoAppScrapeDown(payment)）**不截断** ——
    #   被调方自己指标消失是强证据，不能被上游截断掉（否则会把真根因抹掉）。
    blocked = {}
    for e in raw:
        if e.get("alertname") == "DemoAppDownstreamLatencyHigh":
            s, d = e.get("service"), e.get("downstream")
            if s and d and edges.get(s) == d:
                blocked[s] = d
    if blocked:
        for e in raw:
            if e.get("alertname") == "DemoAppDownstreamLatencyHigh" or e.get("_evi") == "self":
                continue
            start = e.get("downstream") or e.get("service")
            if not start:
                continue
            path, cur, seen = set(), start, set()
            while cur in edges and cur not in seen:
                seen.add(cur)
                path.add((cur, edges[cur]))
                cur = edges[cur]
            for caller, callee in blocked.items():
                if (caller, callee) in path:
                    e["_cands"] = [caller]
                    e["_cand"] = caller
                    break
    # 【第 4 次校准：必须用 dedup_key 折叠重复】
    # ingest 会把每一次重复推送都落盘（duplicate=true 只是标记，不丢弃——这是刻意的：
    # 重复次数本身是"告警风暴"的信号）。但算降噪/根因投票时必须按去重键折叠，
    # 否则同一条告警重复 5 次就有 5 票：实测把 7 条簇的根因从 payment 投成了 redis。
    seen = {}
    evs = []
    for e in raw:
        k = (e.get("dedup_key") or e.get("event_id") or id(e), e.get("status"))
        seen[k] = seen.get(k, 0) + 1
        if seen[k] == 1:
            e["_dup_seen"] = 0
            evs.append(e)
        else:
            evs[-1]["_dup_seen"] = seen[k] - 1 if evs else 0
    collapsed = sum(v - 1 for v in seen.values() if v > 1)
    global COLLAPSED_DUPLICATES
    COLLAPSED_DUPLICATES = collapsed
    evs.sort(key=lambda x: (x["_t"] or datetime.min.replace(tzinfo=timezone.utc)))
    return evs, topo_nodes


def clusterize(evs, window):
    """同命名空间 + 时间相邻（相邻两条间隔 ≤ window 秒）→ 同簇"""
    clusters = []
    for e in evs:
        if not clusters:
            clusters.append([e]); continue
        last = clusters[-1][-1]
        same_ns = (e.get("namespace") or "") == (last.get("namespace") or "")
        gap = (e["_t"] - last["_t"]).total_seconds() if (e["_t"] and last["_t"]) else 1e9
        if same_ns and gap <= window:
            clusters[-1].append(e)
        else:
            clusters.append([e])
    return clusters


def main():
    d, window, do_cluster, topo_path, gt_override = parse_args(sys.argv)
    gt_path = os.path.join(d, "ground_truth.json")
    gt = json.load(io.open(gt_path, encoding="utf-8")) if os.path.exists(gt_path) else {}
    gt_service = gt.get("ground_truth_service")
    gt_set = gt.get("ground_truth_services") or ([gt_service] if gt_service else [])
    gt_norm = set(norm_service(x) for x in gt_set if x)

    # 【标签传播优先】如果事件自身带了 ground_truth 字段（来自 Pod 标签 -> 指标 -> 告警），
    # 就以它为准：这是"数据自带的答案"，比事后按时间窗贴的答案可信。
    ev_gt = set()
    for line in io.open(os.path.join(d, "events.jsonl"), encoding="utf-8"):
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
        except Exception:
            continue
        v = e.get("ground_truth") or e.get("labels", {}).get("ground_truth")
        if v:
            ev_gt.add(norm_service(v))
    gt_from_events = bool(ev_gt)
    if ev_gt:
        gt_norm = ev_gt
    # --gt 覆盖：当根因服务本身不暴露指标（如 F14 的 redis/postgres），
    # 标签传播到不了它的告警上，此时只能显式给出 ground truth 集合。
    if gt_override:
        gt_norm = set(norm_service(x) for x in gt_override.split(",") if x.strip())
        gt_from_events = False

    evs, topo_nodes = load_events(d, topo_path)
    if not evs:
        print("数据集里没有 firing 事件: %s" % d); sys.exit(1)

    clusters = clusterize(evs, window) if do_cluster else [[e] for e in evs]

    # ---- 指标 ----
    n_alert = len(evs)
    n_cluster = len(clusters)
    reduction = 1 - n_cluster / n_alert
    pure = 0
    over = 0
    hit = 0
    matched = []
    detail = []
    # 【第 6 次校准：根因是"候选集合"，不是唯一答案】
    # 实测教训（F13 + 真实拓扑）：payment 与 redis 同时故障时，症状链同时归因于两者，
    # 一个簇里出现 {payment, redis} 是**正确的**，不是"过度合并"。
    # 于是三个指标改成集合口径：
    #   candidate_precision = |候选 ∩ ground truth| / |候选|      （候选里有没有冤枉别人）
    #   candidate_recall    = |ground truth ∩ 全部候选| / |GT|    （真根因有没有被漏掉）
    #   over_merge_rate     = 候选里出现 ground-truth 之外根因的簇占比（真·误并）
    all_cands = set()          # 域内簇的候选（参与精确率）
    all_cands_any = set()      # 全部候选（含域外，仅用于排查）
    bad_clusters = 0
    out_of_scope = 0
    multi_root_clusters = 0
    top1_hit = 0
    top1_in_scope = []
    gt_ranks = {}
    for i, c in enumerate(clusters, 1):
        cands = [x for e in c for x in e.get("_cands", [e["_cand"]])]   # 候选集合摊平（P43）
        # 【并列依赖 = 独立根因】
        # 场景（F14）：payment 同时依赖 redis 与 postgres，三者同时失效。
        # 此时簇里有 3 条"自身失败"证据（各自的 ScrapeDown），它们**互不构成上下游**，
        # 应当各自成为独立根因；把它们合并成一个才是"过度合并"。
        # 判据：若簇内存在多个"自身失败"证据指向不同服务，且这些服务之间在 call 边上不可达，
        #      则它们都是独立根因（各自保留，不折叠）。
        self_fail = {}
        for e in c:
            if e.get("_evi") == "self":
                s = e.get("service")
                if s:
                    self_fail[s] = self_fail.get(s, 0) + 1
        if len(self_fail) > 1:
            # 记录哪几个服务是"并列自身失败"（下游消费方应把它们都视为根因）
            pass

        uniq = sorted(set(cands))
        majority = max(set(cands), key=cands.count) if cands else "unknown"
        purity = cands.count(majority) / len(cands) if cands else 0
        cand_set = set(norm_service(x) for x in uniq)
        if len(self_fail) > 1:
            multi_root_clusters += 1
        if len(uniq) == 1:
            pure += 1
        # ---- 证据打分 + 根因排序（第 7 步）----
        scores, evi_log = {}, {}
        for e in c:
            tgt = e["_cand"]
            et = e.get("_evi", "other")
            w = EVIDENCE_WEIGHTS.get(et, 0.5)
            scores[tgt] = scores.get(tgt, 0.0) + w
            evi_log.setdefault(tgt, {})
            evi_log[tgt][et] = evi_log[tgt].get(et, 0) + 1
        ranked = sorted(scores.items(), key=lambda kv: (-kv[1], kv[0]))
        total = sum(scores.values()) or 1.0
        root_causes = []
        for rank, (svc, sc) in enumerate(ranked, 1):
            root_causes.append({
                "rank": rank,
                "service": svc,
                "score": round(sc, 2),
                "score_share": round(sc / total, 3),
                "evidence": evi_log.get(svc, {}),
            })
        top1 = ranked[0][0] if ranked else "unknown"
        confidence = round(ranked[0][1] / total, 3) if ranked else 0.0

        # 真·过度合并 = 候选里出现 GT 之外的根因（把无辜服务当根因）
        extra = cand_set - gt_norm
        in_scope = not (extra and (extra == {"unknown"} or (topo_nodes is not None and not (extra & topo_nodes))))
        all_cands_any |= cand_set
        if in_scope:
            all_cands |= cand_set
        if gt_norm and extra:
            if not in_scope:
                # 数据集窗口里混进来的"非本次故障"告警（例如自身监控/部署自检），单独计数
                out_of_scope += 1
            else:
                over += 1
                bad_clusters += 1
        # Top-1 命中：排序第一的根因是否在 ground truth 里（域内簇才计）
        if gt_norm and in_scope:
            top1_in_scope.append(top1)
            if norm_service(top1) in gt_norm:
                top1_hit += 1
            rank_map = {norm_service(r["service"]): r["rank"] for r in root_causes}
            for g in gt_norm:
                gt_ranks.setdefault(g, []).append(rank_map.get(g, 0))
        if gt_norm and (cand_set & gt_norm):
            hit += 1
            matched.append("INC-%03d" % i)
        detail.append({
            "cluster_id": "INC-%03d" % i,
            "size": len(c),
            "from": min(e["_t"] for e in c).isoformat() if c else None,
            "to": max(e["_t"] for e in c).isoformat() if c else None,
            "span_seconds": (max(e["_t"] for e in c) - min(e["_t"] for e in c)).total_seconds() if c else 0,
            "candidates": uniq,
            "candidate_set": [norm_service(x) for x in uniq],
            "ambiguous": len(uniq) > 1,
            "root_cause_guess": top1,
            "confidence": confidence,
            "root_causes": root_causes,
            "independent_roots": sorted(self_fail.keys()) if len(self_fail) > 1 else [],
            "purity": round(purity, 3),
            "members": ["%s(%s%s)" % (e.get("alertname"), e.get("service") or "-",
                                      "/" + e["downstream"] if e.get("downstream") else "")
                        for e in c],
        })

    result = {
        "dataset": os.path.basename(os.path.normpath(d)),
        "mode": "cluster" if do_cluster else "baseline",
        # 只记文件名，不记绝对路径 —— 否则同一份数据在本地/集群算出不同哈希（实测踩到）
        "topology_source": (os.path.basename(topo_path) if topo_path else "alert-labels(heuristic fallback)"),
        "window_seconds": window if do_cluster else None,
        "ground_truth_service": gt_service,
        "ground_truth_source": ("event-labels(propagated)" if gt_from_events else ("cli-override" if gt_override else "dataset-file(time-window)")),
        "metrics": {
            "alerts_firing": n_alert,
            "clusters": n_cluster,
            "reduction_rate": round(reduction, 4),
            "cluster_purity": round(pure / n_cluster, 4) if n_cluster else 0,
            "over_merge_rate": round(over / n_cluster, 4) if n_cluster else 0,
            # 口径：单故障数据集 -> ground truth 服务是否被某个簇识别出来（1=命中）
            "ground_truth_services": sorted(gt_norm) or None,
            "ground_truth_matched": (len(matched) if gt_norm else None),
            "candidate_precision": (round(len(all_cands & gt_norm) / len(all_cands), 4) if (gt_norm and all_cands) else None),
            "candidate_recall": (round(len(all_cands & gt_norm) / len(gt_norm), 4) if gt_norm else None),
            "top1_hit_clusters": (top1_hit if gt_norm else None),
            "top1_precision": (round(top1_hit / len(top1_in_scope), 4) if (gt_norm and top1_in_scope) else None),
            # MRR：每个真根因在排序里的名次的倒数均值（1.0 = 全部排第 1）
            "gt_mrr": (round(sum(1.0 / r for rs in gt_ranks.values() for r in rs if r > 0)
                             / max(1, sum(len(rs) for rs in gt_ranks.values())), 3)
                       if gt_norm else None),
            "over_merge_clusters": (bad_clusters if gt_norm else None),
            "multi_root_clusters": multi_root_clusters,
            "out_of_scope_clusters": (out_of_scope if gt_norm else None),
            "duplicates_collapsed": COLLAPSED_DUPLICATES,
            "ground_truth_expected": (len(gt_norm) if gt_norm else None),
            "ground_truth_matched_clusters": matched,
            "extraneous_clusters": max(0, n_cluster - len(matched)) if gt_norm else None,
            # 口径：每个 ground-truth 根因"至少有一个簇命中"才算召回（否则单例簇会刷出 >100% 的假指标）
            "root_cause_recall": (round(len(set(norm_service(c["root_cause_guess"]) for c in detail) & gt_norm) / len(gt_norm), 4) if gt_norm else None),
        },
        "clusters": detail,
    }
    out = os.path.join(d, "correlation.json" if do_cluster else "correlation_baseline.json")
    json.dump(result, io.open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=2)

    m = result["metrics"]
    print("  数据集 : %s" % result["dataset"])
    print("  GT 来源: %s" % result["ground_truth_source"])
    print("  模式   : %s%s" % (result["mode"], "" if not do_cluster else "（window=%ss）" % window))
    print("  ─────────────────────────────────────────────")
    print("  firing 告警数 : %d" % m["alerts_firing"])
    print("  事件簇数      : %d" % m["clusters"])
    print("  降噪率        : %.1f%%" % (m["reduction_rate"] * 100))
    print("  候选集中度    : %.1f%%   （原本叫簇纯度：一个簇里主候选的占比；多根因耦合时它天然低于 100%%）" % (m["cluster_purity"] * 100))
    print("  过度合并率    : %.1f%%" % (m["over_merge_rate"] * 100))
    if m.get("top1_precision") is not None:
        print("  Top-1 精确率  : %.1f%%   （排序第一的根因是否命中 ground truth）" % (m["top1_precision"] * 100))
        print("  MRR           : %.3f     （真根因的平均名次倒数，1.0 = 全排第一）" % (m["gt_mrr"] or 0))
    if m.get("candidate_precision") is not None:
        print("  候选精确率    : %.1f%%   （候选里有没有冤枉别人）" % (m["candidate_precision"] * 100))
        print("  候选召回率    : %.1f%%   （真根因有没有被漏掉）" % (m["candidate_recall"] * 100))
    if False and m.get("root_cause_recall") is not None:
        print("  根因召回率    : %.1f%%  (期望 %d 个根因: %s)"
              % (m["root_cause_recall"] * 100, m["ground_truth_expected"], ", ".join(m["ground_truth_services"] or [])))
        print("  命中簇        : %s    多余簇: %s"
              % (", ".join(m["ground_truth_matched_clusters"]) or "无", m["extraneous_clusters"]))
    print("  ─────────────────────────────────────────────")
    for c in detail:
        # 多候选不等于过度合并：耦合故障下 {payment, redis} 是正确输出（见根因候选集合口径）
        flag = "" if len(c["candidates"]) == 1 else "  ← 多根因候选"
        rc = " > ".join("%s(%.1f)" % (r["service"], r["score"]) for r in c["root_causes"])
        print("  %-9s size=%-2d 排序=%s" % (c["cluster_id"], c["size"], rc))
        print("  %-9s        %s%s" % ("", "  ".join(c["members"][:3]), flag))
    print("  结果已写入: %s" % out)


if __name__ == "__main__":
    main()