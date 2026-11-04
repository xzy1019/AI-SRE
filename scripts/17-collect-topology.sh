#!/usr/bin/env bash
# ============================================================================
# 17-collect-topology.sh —— 从集群真实对象采集服务拓扑（降噪第 2 段的输入）
#
# 为什么需要它：
#   第一版拓扑是"从告警标签反推"的（哪条告警带 downstream 就认为有一条边），
#   这只是**故障发生后**的推断，不是系统事实，而且会被误用：
#   实测中 payment→redis 的"依赖"边被当成调用边，把整条 frontend→order→payment 的
#   级联链错误地拽到 redis，根因算错。
#
# 本脚本从**真实声明**里取拓扑，边分两类（这个区分是修正上述问题的关键）：
#   · call       调用边：order 调 payment —— 症状会沿它向下游传播（下钻时用）
#   · dependency 依赖边：payment 依赖 redis —— 只有"依赖不可用"类告警才归因到它
#
# 来源（都可核查）：
#   · Deployment env: DOWNSTREAM_NAME / DOWNSTREAM_URL  → call 边
#   · Deployment env: DB_HOST / REDIS_HOST              → dependency 边
#   · Service / Endpoints: 服务是否存在、有多少就绪端点  → 节点属性
#
# 用法（在控制面执行）：
#     bash 17-collect-topology.sh [命名空间] [输出文件]
#   默认: 命名空间 demo-app，输出 /opt/aisre/topology/topology.json
# ============================================================================
set -uo pipefail

NS="${1:-demo-app}"
OUT="${2:-/opt/aisre/topology/topology.json}"
mkdir -p "$(dirname "$OUT")"

C_B=$'\033[0;36m'; C_G=$'\033[0;32m'; C_0=$'\033[0m'
printf '%s== 采集拓扑: ns=%s%s\n' "$C_B" "$NS" "$C_0"

python3 - "$NS" "$OUT" <<'PY'
import json, subprocess, sys, datetime

ns, out = sys.argv[1], sys.argv[2]

def kget(args):
    try:
        return json.loads(subprocess.check_output(args, stderr=subprocess.DEVNULL).decode())
    except Exception:
        return None

deps = kget(["kubectl", "-n", ns, "get", "deploy", "-o", "json"]) or {"items": []}
svcs = kget(["kubectl", "-n", ns, "get", "svc", "-o", "json"]) or {"items": []}
eps  = kget(["kubectl", "-n", ns, "get", "endpoints", "-o", "json"]) or {"items": []}

nodes, edges = {}, []

for d in deps.get("items", []):
    name = d["metadata"]["name"]
    labels = d["metadata"].get("labels", {}) or {}
    node = {"kind": "deployment", "replicas": d.get("status", {}).get("readyReplicas", 0),
            "tier": labels.get("tier"), "labels": {k: v for k, v in labels.items() if k.startswith("app")}}
    for c in d["spec"]["template"]["spec"].get("containers", []):
        for e in (c.get("env") or []):
            k, v = e.get("name"), e.get("value")
            if k == "DOWNSTREAM_NAME" and v:
                edges.append({"from": name, "to": v, "type": "call", "source": "deploy-env:DOWNSTREAM_NAME"})
            elif k in ("DB_HOST", "REDIS_HOST") and v:
                dep = v.split(".")[0]                      # postgres.demo-app.svc -> postgres
                edges.append({"from": name, "to": dep, "type": "dependency",
                              "source": "deploy-env:" + k})
    nodes[name] = node

for s in svcs.get("items", []):
    name = s["metadata"]["name"]
    nodes.setdefault(name, {})["kind"] = "service"
    nodes[name]["ports"] = [p.get("port") for p in s["spec"].get("ports", [])]
    nodes[name]["selector"] = s["spec"].get("selector")

for e in eps.get("items", []):
    name = e["metadata"]["name"]
    addrs = []
    for sub in e.get("subsets", []) or []:
        for a in sub.get("addresses", []) or []:
            addrs.append(a.get("ip"))
    if name in nodes:
        nodes[name]["ready_endpoints"] = len(addrs)

# 去重（同一 from→to→type 只保留一条）
seen, uniq = set(), []
for e in edges:
    k = (e["from"], e["to"], e["type"])
    if k in seen:
        continue
    seen.add(k); uniq.append(e)

topo = {
    "collected_at": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
    "namespace": ns,
    "sources": ["deployment-env:DOWNSTREAM_NAME", "deployment-env:DB_HOST/REDIS_HOST",
                "kubectl:svc", "kubectl:endpoints"],
    "nodes": nodes,
    "edges": uniq,
}
json.dump(topo, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
print("  节点 %d 个，边 %d 条 → %s" % (len(nodes), len(uniq), out))
for e in uniq:
    print("    %-10s -%s-> %-10s (%s)" % (e["from"], "call" if e["type"] == "call" else "dep", e["to"], e["source"]))
PY