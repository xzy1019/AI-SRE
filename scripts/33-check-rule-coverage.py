#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
33-check-rule-coverage.py —— 告警规则 ↔ 降噪/RCA 的**覆盖回归测试**

为什么需要它（P43 的教训）：
    新增一条告警规则时，很容易只改规则、忘了改下游：
      · 16-correlation-baseline.py 的 candidate()/candidates() —— 候选推断
      · evidence_type()                                        —— 证据分类
    两处都没改时，新告警会**静默降级**：证据权重掉到 other(0.5)、候选变成 unknown，
    表现为"指标还能算、但数字是 0"，而不是报错。本项目已经踩过一次（P43）。

本脚本做两层检查：
    A. 静态检查（不需要数据）：解析 rules 文件，取出所有告警名，
       凡是业务类（DemoApp* / Container*）都必须能映射到**非 other** 的证据类型。
    B. 数据检查（需要数据集）：对每个数据集里的 firing 事件，
       检查候选是否非空且不是 unknown。

用法:
    python3 33-check-rule-coverage.py                 # 用仓库默认路径
    python3 33-check-rule-coverage.py --datasets datasets --topology topology/topology.json

退出码：0 = 全部通过；1 = 有未覆盖项（可直接用于 CI / 提交前）
"""
import argparse
import importlib.util
import io
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CORR_PATH = os.path.join(HERE, "16-correlation-baseline.py")

# 业务类告警前缀：这些**必须**被降噪/RCA 认识
BUSINESS_PREFIXES = ("DemoApp", "Container")

# 允许落到 other 的（基础设施/自监控类，降噪层不参与候选推断）
INFRA_EXEMPT = ("KubeletDown", "NodeMemoryHigh", "NodeFilesystemHigh", "NodeCPUHigh",
                "DeploymentReplicasMismatch", "PodCrashLooping", "PodNotReady",
                "PodRestartingFrequently", "AlertmanagerNotifyFailing",
                "IngestNotReceiving", "IngestScrapeDown")


def load_corr():
    """把 16-correlation-baseline.py 当模块加载（文件名带连字符，不能直接 import）"""
    spec = importlib.util.spec_from_file_location("corr16", CORR_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def alert_names_in_rules(path):
    names = []
    for line in io.open(path, encoding="utf-8"):
        m = re.match(r"\s*-\s*alert:\s*(\S+)\s*$", line)
        if m:
            names.append(m.group(1))
    return names


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rules", default=os.path.join(ROOT, "manifests", "observability", "_prometheus-rules.yml"))
    ap.add_argument("--datasets", default=os.path.join(ROOT, "datasets"))
    ap.add_argument("--topology", default=os.path.join(ROOT, "topology", "topology.json"))
    args = ap.parse_args()

    mod = load_corr()
    fails = []

    # ---------- A. 静态检查 ----------
    print("=" * 74)
    print("A. 静态检查：规则名 → 证据分类")
    print("=" * 74)
    if not os.path.isfile(args.rules):
        print("  ✘ 找不到规则文件：%s" % args.rules)
        return 1
    names = alert_names_in_rules(args.rules)
    print("  规则文件里共 %d 条告警\n" % len(names))
    for n in names:
        et = mod.evidence_type({"alertname": n}, set())
        is_biz = n.startswith(BUSINESS_PREFIXES)
        if et != "other":
            print("  ✔ %-34s → %-11s %s" % (n, et, "(业务类)" if is_biz else ""))
        elif n in INFRA_EXEMPT or not is_biz:
            print("  - %-34s → %-11s （基础设施/自监控，降噪层不参与候选）" % (n, et))
        else:
            print("  ✘ %-34s → %-11s ← **业务类却没登记**（P43：规则加了等于白加）" % (n, et))
            fails.append("规则未登记证据类型: %s" % n)

    # ---------- B. 数据检查 ----------
    print()
    print("=" * 74)
    print("B. 数据检查：历史数据集里的 firing 事件是否都能产出候选")
    print("=" * 74)
    if not os.path.isdir(args.datasets):
        print("  （跳过：找不到数据集目录 %s）" % args.datasets)
    else:
        topo = args.topology if os.path.isfile(args.topology) else None
        if topo:
            edges, dep_edges, topo_nodes = mod.load_topology_file(topo)
            print("  拓扑：call 边 %d 条 / dependency 边 %d 条 / 节点 %d 个\n"
                  % (len(edges), len(dep_edges), len(topo_nodes)))
        else:
            edges, dep_edges, topo_nodes = {}, set(), None
            print("  ! 未找到拓扑文件，退化为空拓扑\n")
        checked = 0
        for d in sorted(os.listdir(args.datasets)):
            p = os.path.join(args.datasets, d, "events.jsonl")
            if not os.path.isfile(p):
                continue
            evs = [json.loads(l) for l in io.open(p, encoding="utf-8") if l.strip()]
            fire = [e for e in evs if e.get("status") == "firing"]
            if not fire:
                continue
            checked += 1
            bad, infra = [], []
            for e in fire:
                name = e.get("alertname") or ""
                cs = mod.candidates(e, edges, dep_edges, topo_nodes)
                empty = (not cs) or cs == ["unknown"]
                if not empty:
                    continue
                # 基础设施/自监控告警本来就不该映射到业务服务（降噪层把它们计为 out_of_scope），
                # 只有**业务类**告警出现空候选才是真问题（P43）。
                if name.startswith(BUSINESS_PREFIXES):
                    bad.append(name)
                else:
                    infra.append(name)
            note = ""
            if infra:
                note = "   （已排除非业务告警：%s）" % ", ".join(sorted(set(infra)))
            if bad:
                print("  ✘ %-22s firing=%-3d **业务告警**有空候选：%s" % (d, len(fire), ", ".join(sorted(set(bad)))))
                fails.append("数据集 %s 业务告警出现空候选: %s" % (d, sorted(set(bad))))
            else:
                print("  ✔ %-22s firing=%-3d 业务告警全部有非空候选%s" % (d, len(fire), note))
        if checked == 0:
            print("  （没有含 firing 事件的数据集）")

    print()
    print("=" * 74)
    if fails:
        print("✘ 未通过 %d 项：" % len(fails))
        for f in fails:
            print("   -", f)
        print("\n修复提示：在 scripts/16-correlation-baseline.py 里补 evidence_type() 与 candidates() 的分支。")
        return 1
    print("✔ 全部通过：所有业务类告警都有证据分类，历史数据集无空候选。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
