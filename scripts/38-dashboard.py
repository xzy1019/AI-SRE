#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
38-dashboard.py —— AI SRE 图形化控制台（可本地跑，也可在集群里跑）

标签页：
  总览     集群健康 + 实时告警 + SLI + 服务入口（Grafana/Prometheus/Alertmanager）
  大模型   RCA 调用记录（耗时 / tokens/s / Top-1 / 幻觉 / RAG 命中）
  Agent    审计哈希链（独立复算）+ 运行时指标 + 判责策略
  实验     故障矩阵 / 重复实验进度 + 降噪/RCA 评测结果

两种运行形态：
  · 本地（开发机）: python3 scripts/38-dashboard.py            → 读本地 datasets/ 与 _logs/
  · 集群内（Pod） : python3 scripts/38-dashboard.py --cluster  → 实时查 Prometheus/Alertmanager/Agent
                                                              + 读挂载的数据快照 /data

只用 Python 标准库（容器里不装任何依赖）。
"""
import argparse
import io
import json
import os
import ssl
import sys
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

CFG = {
    "cluster": False,
    "prom": os.environ.get("PROM_URL", "http://prometheus.observability.svc:9090"),
    "am": os.environ.get("AM_URL", "http://alertmanager.observability.svc:9093"),
    "agent": os.environ.get("AGENT_URL", "http://aisre-agent.aiops.svc:8080"),
    "ingest": os.environ.get("INGEST_URL", "http://aisre-ingest.aiops.svc:8080"),
    "grafana": os.environ.get("GRAFANA_URL", ""),
    "data": os.environ.get("DATA_DIR", os.path.join(ROOT, "dataset_dashboard")),
}


# --------------------------------------------------------------------------
# 取数工具
# --------------------------------------------------------------------------
def http_get(url, timeout=6, headers=None):
    req = urllib.request.Request(url, headers=headers or {})
    ctx = ssl._create_unverified_context() if url.startswith("https") else None
    with urllib.request.urlopen(req, timeout=timeout, context=ctx) as r:
        return r.read().decode("utf-8", "replace")


def http_json(url, timeout=6, headers=None):
    return json.loads(http_get(url, timeout=timeout, headers=headers))


def prom(query):
    """PromQL 即时查询，返回结果列表"""
    try:
        u = CFG["prom"].rstrip("/") + "/api/v1/query?" + urllib.parse.urlencode({"query": query})
        return http_json(u).get("data", {}).get("result", [])
    except Exception:
        return []


def prom_val(query, default=0):
    r = prom(query)
    try:
        return r[0]["value"][1]
    except Exception:
        return default


def read_json(path, default=None):
    # utf-8-sig：PowerShell 写出的文件可能带 BOM（P48）
    try:
        return json.load(io.open(path, encoding="utf-8-sig"))
    except Exception:
        return default


def read_jsonl(path, limit=None):
    rows = []
    try:
        for line in io.open(path, encoding="utf-8-sig"):
            line = line.strip()
            if line:
                try:
                    rows.append(json.loads(line))
                except ValueError:
                    pass
    except Exception:
        pass
    return rows[-limit:] if limit else rows


def k8s_get(path):
    """访问 K8s API（Pod 内用 ServiceAccount）"""
    try:
        tok = io.open("/var/run/secrets/kubernetes.io/serviceaccount/token", encoding="utf-8").read().strip()
        host = os.environ.get("KUBERNETES_SERVICE_HOST", "kubernetes.default.svc")
        port = os.environ.get("KUBERNETES_SERVICE_PORT", "443")
        return http_json("https://%s:%s%s" % (host, port, path), headers={"Authorization": "Bearer " + tok})
    except Exception:
        return None


# --------------------------------------------------------------------------
# 各标签页取数
# --------------------------------------------------------------------------
def _rules_count():
    """从 Prometheus rules API 取真实规则条数（比 count(ALERTS) 准确）"""
    try:
        d = http_json(CFG["prom"].rstrip("/") + "/api/v1/rules")
        return sum(len(g.get("rules", [])) for g in d.get("data", {}).get("groups", []))
    except Exception:
        return None


def api_overview():
    out = {"ts": None, "health": {}, "alerts": [], "sli": [], "links": {}, "chaos": None}
    import time
    out["ts"] = time.strftime("%Y-%m-%d %H:%M:%S")

    out["health"] = {
        "nodes_ready": prom_val('count(kube_node_status_condition{condition="Ready",status="true"}==1)'),
        # 按节点去重：直接 count(...) 会把每个节点上的多个 condition 序列都数进去（实测 5 节点数出 15）
        "nodes_total": prom_val('count(count by (node) (kube_node_status_condition{condition="Ready"}))'),
        "pods_ready": prom_val('count(kube_pod_status_ready{namespace="demo-app",condition="true"}==1)'),
        "pods_total": prom_val('count(kube_pod_status_phase{namespace="demo-app",phase="Running"}==1)'),
        # 规则数走 Prometheus 的 rules API（count(ALERTS) 是"有状态的告警序列"，不是规则数）
        "rules_loaded": _rules_count(),
        "targets_up": prom_val('count(up==1)'),
        "targets_total": prom_val("count(up)"),
    }
    # 实时告警（Prometheus ALERTS）
    for r in prom('ALERTS{alertstate=~"pending|firing"}'):
        m = r.get("metric", {})
        out["alerts"].append({
            "name": m.get("alertname"), "state": m.get("alertstate"),
            "severity": m.get("severity"), "service": m.get("service"),
            "downstream": m.get("downstream"), "pod": m.get("pod"),
        })
    # 关键 SLI
    sli_defs = [
        ("QPS", 'sum(rate(http_requests_total{job="demo-app"}[2m]))'),
        ("5xx 速率", 'sum(rate(http_requests_total{job="demo-app",status=~"5.."}[2m]))'),
        ("下游错误速率", 'sum(rate(downstream_requests_total{job="demo-app",result="error"}[2m]))'),
        ("payment P95(s)", 'histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket{job="demo-app",service="payment"}[5m])))'),
    ]
    for name, q in sli_defs:
        v = prom_val(q, None)
        out["sli"].append({"name": name, "value": None if v is None else round(float(v), 4)})
    # 混沌对象（K8s API）
    if CFG["cluster"]:
        cnt = {}
        for kind, plural in (("PodChaos", "podchaos"), ("NetworkChaos", "networkchaos"), ("StressChaos", "stresschaos")):
            d = k8s_get("/apis/chaos-mesh.org/v1alpha1/namespaces/chaos-mesh/%s" % plural)
            cnt[kind] = len(d.get("items", [])) if d else None
        out["chaos"] = cnt
    # 服务入口（用浏览器访问的 NodePort，从环境变量取，缺省给常见值）
    out["links"] = {
        "grafana": CFG["grafana"] or "http://172.29.20.25:30030",
        "prometheus": "http://172.29.20.25:30090",
        "alertmanager": "http://172.29.20.25:30093",
        "chaos": "http://172.29.20.25:31615",
    }
    return out


def api_llm():
    recs = read_json(os.path.join(CFG["data"], "rca_records.json"), None)
    if recs is None:
        # 本地形态：扫 datasets/
        recs = []
        dsroot = os.path.join(ROOT, "datasets")
        if os.path.isdir(dsroot):
            for d in sorted(os.listdir(dsroot)):
                dd = os.path.join(dsroot, d)
                if not os.path.isdir(dd):
                    continue
                for fn in sorted(os.listdir(dd)):
                    if fn.startswith("rca_") and fn.endswith(".json"):
                        r = read_json(os.path.join(dd, fn))
                        if isinstance(r, dict):
                            r["_file"] = "%s/%s" % (d, fn)
                            r["_mtime"] = os.path.getmtime(os.path.join(dd, fn))
                            recs.append(r)
            recs.sort(key=lambda r: -r.get("_mtime", 0))
    return {"records": recs}


def api_agent():
    out = {"audit": [], "verify": None, "metrics": {}, "policies": [], "source": "local"}
    if CFG["cluster"]:
        out["source"] = "cluster"
        try:
            d = http_json(CFG["agent"].rstrip("/") + "/audit")
            out["audit"] = d.get("records", [])
        except Exception as e:
            out["err_audit"] = str(e)
        try:
            out["verify"] = http_json(CFG["agent"].rstrip("/") + "/audit/verify")
        except Exception as e:
            out["err_verify"] = str(e)
        try:
            out["policies"] = http_json(CFG["agent"].rstrip("/") + "/policies")
        except Exception as e:
            out["err_pol"] = str(e)
        for url, tag in ((CFG["agent"], "agent"), (CFG["ingest"], "ingest")):
            try:
                txt = http_get(url.rstrip("/") + "/metrics")
                for line in txt.split("\n"):
                    if line.startswith("aisre_") or line.startswith("ingest_"):
                        p = line.split()
                        if len(p) == 2:
                            out["metrics"]["%s.%s" % (tag, p[0])] = p[1]
            except Exception:
                pass
    else:
        ad = os.path.join(ROOT, "_logs", "agent")
        out["audit"] = read_jsonl(os.path.join(ad, "audit.jsonl"), limit=200)
        out["metrics"] = read_json(os.path.join(ad, "metrics.json"), {}) or {}
        sp = os.path.join(ad, "last-sync.txt")
        out["last_sync"] = io.open(sp, encoding="utf-8-sig").read().strip() if os.path.isfile(sp) else ""
    # 独立复算哈希链（不信 agent 自己的结论）
    prev, bad = "0" * 64, []
    for i, r in enumerate(out["audit"], 1):
        if r.get("prev_hash") != prev:
            bad.append(i)
        prev = r.get("hash")
    out["chain_ok"] = (not bad) if out["audit"] else None
    out["chain_msg"] = ("链式校验 OK（%d 条）" % len(out["audit"])) if out["audit"] and not bad else (
        "断链 @ 行 %s" % bad if bad else "无记录")
    out["audit_total"] = len(out["audit"])
    out["audit"] = out["audit"][-60:]
    return out


def api_experiments():
    d = CFG["data"] if os.path.isdir(CFG["data"]) else os.path.join(ROOT, "datasets")
    rows = read_jsonl(os.path.join(d, "matrix.jsonl"))
    return {
        "total_runs": len(rows),
        "recent": rows[-30:][::-1],
        "eval": read_json(os.path.join(d, "matrix_eval.json"), None),
        "repeats": read_json(os.path.join(d, "repeats_summary.json"), None),
        "rag": read_json(os.path.join(d, "rag_ab_summary.json"), None),
        "extra": read_json(os.path.join(d, "extra_datasets.json"), None),
        "eval_md": (io.open(os.path.join(d, "matrix_eval.md"), encoding="utf-8-sig").read()
                    if os.path.isfile(os.path.join(d, "matrix_eval.md")) else ""),
    }


API = {
    "/api/overview": api_overview,
    "/api/llm": api_llm,
    "/api/agent": api_agent,
    "/api/experiments": api_experiments,
}


INDEX_HTML = r"""<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">
<title>AI SRE 控制台</title><style>
:root{--bg:#0f1420;--panel:#171e2e;--fg:#e6edf3;--dim:#8b98a8;--acc:#4aa3ff;--ok:#3fb950;--bad:#f85149;--warn:#d29922}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.55 -apple-system,"Segoe UI",Roboto,"Microsoft YaHei",sans-serif}
header{padding:12px 20px;background:var(--panel);border-bottom:1px solid #263041;display:flex;align-items:center;gap:14px;flex-wrap:wrap;position:sticky;top:0;z-index:9}
h1{font-size:15px;margin:0}.tabs{display:flex;gap:6px;margin-left:auto;flex-wrap:wrap}
.tab{padding:6px 13px;border-radius:6px;background:#1f2937;cursor:pointer;font-size:13px}
.tab.on{background:var(--acc);color:#06101f;font-weight:600}
main{padding:16px 20px}.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(210px,1fr));gap:10px}
.card{background:var(--panel);border:1px solid #263041;border-radius:10px;padding:13px 15px;margin-bottom:14px}
.card h2{font-size:13px;margin:0 0 9px;color:var(--dim);font-weight:600;letter-spacing:.4px}
table{width:100%;border-collapse:collapse;font-size:12.5px}
th,td{padding:5px 8px;text-align:left;border-bottom:1px solid #232c3b;white-space:nowrap}
th{color:var(--dim)}tr:hover td{background:#1b2434}
.ok{color:var(--ok)}.bad{color:var(--bad)}.dim{color:var(--dim)}.warn{color:var(--warn)}
.kv div{background:#131a28;border:1px solid #232c3b;border-radius:8px;padding:8px 10px}
.kv b{display:block;color:var(--dim);font-size:11px;margin-bottom:2px}
pre{background:#0b101a;border:1px solid #232c3b;border-radius:8px;padding:9px;overflow:auto;max-height:320px;font-size:12px}
.chartbox{overflow-x:auto;overflow-y:hidden;padding-bottom:6px}
a{color:var(--acc);text-decoration:none}a:hover{text-decoration:underline}
.muted{color:var(--dim);font-size:12px}.big{font-size:19px;font-weight:600}
</style></head><body>
<header><h1>AI SRE 控制台</h1><span class="muted" id="stat"></span>
 <span class="muted" id="clock"></span>
 <div class="tabs">
  <div class="tab on" data-t="ov">总览</div><div class="tab" data-t="llm">大模型</div>
  <div class="tab" data-t="ag">Agent</div><div class="tab" data-t="ex">实验</div>
 <div class="tab" data-t="ch">图表</div>
 </div></header>
<main>
 <section id="ov">加载中…</section><section id="llm" style="display:none"></section>
 <section id="ag" style="display:none"></section><section id="ex" style="display:none"></section>
 <section id="ch" style="display:none"></section>
</main>
<script>
const esc=s=>String(s==null?"":s).replace(/[&<>"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));
const dash=v=>v==null?"-":v;
async function j(u){const r=await fetch(u);return r.json()}
function tbl(cols,rows,empty){return `<table><thead><tr>${cols.map(c=>`<th>${c}</th>`).join("")}</tr></thead><tbody>${rows||`<tr><td colspan=${cols.length} class="dim">${empty||"无数据"}</td></tr>`}</tbody></table>`}

async function drawOv(){
 const d=await j("/api/overview"); const h=d.health||{};
 const chip=(k,v,cls)=>`<div><b>${k}</b><span class="big ${cls||""}">${dash(v)}</span></div>`;
 const chaos=d.chaos?Object.entries(d.chaos).map(([k,v])=>`<div><b>${k}</b>${v==null?"?":v}</div>`).join(""):"";
 const alerts=tbl(["告警名","状态","级别","服务","下游","Pod"],(d.alerts||[]).map(a=>
   `<tr><td>${esc(a.name)}</td><td class="${a.state==='firing'?'bad':'warn'}">${esc(a.state)}</td>
    <td>${esc(a.severity)}</td><td>${esc(a.service)}</td><td>${esc(a.downstream)}</td><td class="dim">${esc(a.pod)}</td></tr>`),
   "当前没有 pending/firing 告警");
 const sli=tbl(["SLI","当前值"],(d.sli||[]).map(s=>`<tr><td>${esc(s.name)}</td><td><b>${dash(s.value)}</b></td></tr>`));
 const L=d.links||{};
 document.getElementById("ov").innerHTML=`
  <div class="card"><h2>集群健康 <span class="muted">（${esc(d.ts)} 实时）</span></h2>
   <div class="grid kv">
    ${chip("节点就绪",`${h.nodes_ready}/${h.nodes_total}`,(h.nodes_ready==h.nodes_total)?"ok":"bad")}
    ${chip("业务 Pod 就绪",`${h.pods_ready}/${h.pods_total}`,(h.pods_ready==h.pods_total)?"ok":"bad")}
    ${chip("抓取目标 up",`${h.targets_up}/${h.targets_total}`)}
    ${chip("活动告警",(d.alerts||[]).length,(d.alerts||[]).length?"warn":"ok")}
    ${chip("混沌对象",d.chaos?Object.values(d.chaos).reduce((a,b)=>a+(b||0),0):"-")}
    ${chaos}
   </div></div>
  <div class="card"><h2>实时告警</h2>${alerts}</div>
  <div class="card"><h2>关键 SLI</h2>${sli}</div>
  <div class="card"><h2>外部入口</h2><div class="grid kv">
    <div><b>Grafana</b><a href="${esc(L.grafana)}" target="_blank">${esc(L.grafana)}</a></div>
    <div><b>Prometheus</b><a href="${esc(L.prometheus)}" target="_blank">${esc(L.prometheus)}</a></div>
    <div><b>Alertmanager</b><a href="${esc(L.alertmanager)}" target="_blank">${esc(L.alertmanager)}</a></div>
    <div><b>Chaos Dashboard</b><a href="${esc(L.chaos)}" target="_blank">${esc(L.chaos)}</a></div>
  </div></div>`;
 document.getElementById("stat").textContent=`节点 ${h.nodes_ready}/${h.nodes_total} · 告警 ${(d.alerts||[]).length}`;
}

async function drawLLM(){
 const d=await j("/api/llm"); const rs=d.records||[];
 const rows=rs.map(r=>{
   const u=r.usage||{}, p=r.parsed||{}, rc=p.root_causes||[];
   const tps=u.tokens_per_second, cls=(tps!=null&&tps<5)?"bad":"ok";
   const roots=rc.map(x=>esc(x.service)+(x.confidence!=null?`(${x.confidence})`:"")).join(" &gt; ");
   const rag=(r.rag&&r.rag.retrieved||[]).map(x=>x.id).join(", ");
   const md5=(r._file||r.dataset||"");
   return `<tr><td class="dim">${esc(md5)}</td><td>${esc(r.model)}</td><td>${dash(r.latency_seconds)}s</td>
    <td class="${cls}">${tps==null?"-":tps.toFixed(1)}</td><td>${dash(u.eval_count)}</td><td>${dash(r.alerts_firing)}</td>
    <td><b>${esc(rc[0]?rc[0].service:"-")}</b></td><td>${roots}</td>
    <td>${(r.validation||{}).hallucination?'<span class="bad">有</span>':'<span class="ok">无</span>'}</td>
    <td class="dim">${rag?esc(rag):"-"}</td></tr>`});
 document.getElementById("llm").innerHTML=`
  <div class="card"><h2>大模型 RCA 记录（${rs.length} 条）<span class="muted">tok/s &lt; 5 标红 = 疑似显存溢出到 CPU（P46）</span></h2>
  ${tbl(["来源","模型","耗时","tok/s","生成tokens","告警","Top-1","根因排序","幻觉","RAG命中"],rows,"还没有 RCA 记录")}</div>`;
}

async function drawAg(){
 const d=await j("/api/agent"); const a=(d.audit||[]).slice().reverse();
 const rows=a.map(r=>{const cls=r.decision==="denied"?"bad":(r.decision==="executed"?"ok":"");
  return `<tr><td>${r.seq}</td><td class="dim">${esc((r.ts||"").substring(0,19).replace("T"," "))}</td>
   <td>${esc(r.action)}</td><td>${esc(r.level)}</td><td>${esc(r.target)}</td>
   <td class="${cls}"><b>${esc(r.decision)}</b></td><td>${esc((r.detail||"").substring(0,70))}</td>
   <td class="dim">${esc((r.hash||"").substring(0,10))}…</td></tr>`});
 const m=Object.entries(d.metrics||{}).map(([k,v])=>`<div><b>${esc(k)}</b>${esc(v)}</div>`).join("");
 const pol=(d.policies||[]).map(p=>`<tr><td>${esc(p.id)}</td><td>${esc(p.name)}</td><td class="dim">${esc(p.rule)}</td></tr>`).join("");
 document.getElementById("ag").innerHTML=`
  <div class="card"><h2>审计哈希链
    <span class="${d.chain_ok?'ok':'bad'}">${esc(d.chain_msg)}</span>
    <span class="muted">（来源：${esc(d.source)}；页面独立复算，不采信 Agent 自述）
    ${d.verify?`· Agent 自检 chain_ok=${esc(d.verify.chain_ok)} records=${esc(d.verify.records)}`:""}</span></h2>
   ${tbl(["seq","时间","动作","级别","目标","决策","说明","hash"],rows,"还没有审计记录")}</div>
  <div class="card"><h2>运行时指标</h2><div class="grid kv">${m||'<div class="dim">无</div>'}</div></div>
  <div class="card"><h2>判责策略（${(d.policies||[]).length} 条）</h2>${tbl(["ID","名称","规则"],(d.policies||[]).map(p=>`<tr><td>${esc(p.id)}</td><td>${esc(p.name)}</td><td class="dim">${esc(p.rule)}</td></tr>`),"无（本地形态下不展示，请在集群内查看）")}</div>`;
}

async function drawCharts(){
 const d = await j("/api/experiments");
 const rep = d.repeats || {}, agg = (d.eval || {}).aggregate || null, rag = d.rag || null;
 const exps = Object.keys(rep).sort();
 const C = { acc:"#4aa3ff", bad:"#f85149", warn:"#d29922", fg:"#e6edf3", dim:"#8b98a8", grid:"#263041" };
 const F = "font-size='12'";
 function txt(x,y,v,c,a){ return `<text x="${x}" y="${y}" ${F} fill="${c||C.fg}"${a?` text-anchor="${a}"`:""}>${esc(v)}</text>`; }

 // ---- 图1：各实验降噪率（均值 ± 标准差）
 const L=72, R=470, rowH=30;
 const h1 = 24 + exps.length*rowH + 34;
 let c1 = `<svg viewBox="0 0 720 ${h1}" style="width:100%;min-width:680px;max-width:940px;height:auto">`;
 [0,25,50,75,100].forEach(p=>{ const x=L+(R-L)*p/100;
   c1 += `<line x1="${x}" y1="24" x2="${x}" y2="${24+exps.length*rowH}" stroke="${p===0?C.dim:C.grid}" stroke-width="1"/>`;
   c1 += txt(x, 24+exps.length*rowH+16, p+"%", C.dim, "middle"); });
 exps.forEach((e,i)=>{
   const v = rep[e], m = ((v.mean||{}).reduction_rate)||0, sd = ((v.stdev||{}).reduction_rate)||0;
   const y = 24 + i*rowH + rowH/2;
   c1 += txt(L-10, y+4, e, C.fg, "end");
   c1 += `<rect x="${L}" y="${y-7}" width="${Math.max(0,(R-L)*m)}" height="14" rx="3" fill="${C.acc}"/>`;
   if (sd > 0.0001){
     const x0=L+(R-L)*(m-sd), x1=L+(R-L)*(m+sd);
     c1 += `<line x1="${x0}" y1="${y}" x2="${x1}" y2="${y}" stroke="${C.fg}" stroke-width="1"/>`;
     c1 += `<line x1="${x0}" y1="${y-4}" x2="${x0}" y2="${y+4}" stroke="${C.fg}" stroke-width="1"/>`;
     c1 += `<line x1="${x1}" y1="${y-4}" x2="${x1}" y2="${y+4}" stroke="${C.fg}" stroke-width="1"/>`; }
   c1 += txt(R+10, y+4, (m*100).toFixed(0)+"%　Top-1 "+v.top1_hit+"/"+v.n+(v.no_alert?"　无告警 "+v.no_alert:""), C.dim);
 });
 c1 += `</svg>`;

 // ---- 图2：重复轮次构成（可评测 / 无告警）
 const rowH2=26, maxN=6, bw=(R-L)/maxN;
 const h2 = 24 + exps.length*rowH2 + 52;
 let c2 = `<svg viewBox="0 0 720 ${h2}" style="width:100%;min-width:680px;max-width:940px;height:auto">`;
 [0,3,6].forEach(g=>{ const x=L+bw*g;
   c2 += `<line x1="${x}" y1="24" x2="${x}" y2="${24+exps.length*rowH2}" stroke="${g===0?C.dim:C.grid}" stroke-width="1"/>`;
   c2 += txt(x, 24+exps.length*rowH2+16, g+" 轮", C.dim, "middle"); });
 exps.forEach((e,i)=>{
   const v=rep[e], y=24+i*rowH2+rowH2/2;
   c2 += txt(L-10, y+4, e, C.fg, "end");
   if (v.n>0)  c2 += `<rect x="${L}" y="${y-7}" width="${bw*v.n}" height="14" rx="2" fill="${C.acc}"/>`;
   if (v.no_alert>0) c2 += `<rect x="${L+bw*v.n}" y="${y-7}" width="${bw*v.no_alert}" height="14" rx="2" fill="${C.bad}" opacity="0.8"/>`;
   c2 += txt(R+10, y+4, "可评测 "+v.n+" / 无告警 "+(v.no_alert||0), C.dim);
 });
 const ly = 24 + exps.length*rowH2 + 38;
 c2 += `<rect x="${L}" y="${ly-8}" width="10" height="10" rx="2" fill="${C.acc}"/>` + txt(L+16, ly, "可评测", C.dim);
 c2 += `<rect x="${L+90}" y="${ly-8}" width="10" height="10" rx="2" fill="${C.bad}" opacity="0.8"/>` + txt(L+106, ly, "无告警（不可评测）", C.dim);
 c2 += `</svg>`;

 // ---- 图3：RAG A/B（命中率 + 平均耗时）
 let c3 = "";
 if (rag && rag.n){
   const rowH3=46, h3=26+rowH3*2+22;
   c3 = `<svg viewBox="0 0 720 ${h3}" style="width:100%;min-width:680px;max-width:940px;height:auto">`;
   [0,25,50,75,100].forEach(p=>{ const x=L+(R-L)*p/100;
     c3 += `<line x1="${x}" y1="18" x2="${x}" y2="${18+rowH3*2-18}" stroke="${p===0?C.dim:C.grid}" stroke-width="1"/>`;
     c3 += txt(x, 18+rowH3*2+4, p+"%", C.dim, "middle"); });
   const latNo = (rag.results||[]).map(r=>r.lat_norag).filter(x=>x).reduce((a,b)=>a+b,0) / Math.max(1,(rag.results||[]).filter(r=>r.lat_norag).length);
   const latRg = (rag.results||[]).map(r=>r.lat_rag).filter(x=>x).reduce((a,b)=>a+b,0) / Math.max(1,(rag.results||[]).filter(r=>r.lat_rag).length);
   [["无 RAG", rag.top1_norag/rag.n, latNo],["带 RAG", rag.top1_rag/rag.n, latRg]].forEach((r,i)=>{
     const y = 30 + i*rowH3;
     c3 += txt(L-10, y+5, r[0], C.fg, "end");
     c3 += `<rect x="${L}" y="${y-9}" width="${Math.max(0,(R-L)*r[1])}" height="18" rx="3" fill="${C.acc}"/>`;
     c3 += txt(R+10, y+5, "Top-1 "+(r[1]*100).toFixed(0)+"%　平均 "+r[2].toFixed(2)+"s", C.dim);
   });
   c3 += `</svg>`;
 }

 // ---- 图4：非矩阵实验数据集（单次运行：F13 级联 / F14 多根因 / 自愈闭环等）
 const ex = (d.extra && d.extra.datasets) || [];
 let c4 = "";
 if (ex.length){
   const rowH4 = 30, h4 = 24 + ex.length*rowH4 + 34;
   c4 = `<svg viewBox="0 0 720 ${h4}" style="width:100%;min-width:680px;max-width:940px;height:auto">`;
   [0,25,50,75,100].forEach(p2=>{ const x=L+(R-L)*p2/100;
     c4 += `<line x1="${x}" y1="24" x2="${x}" y2="${24+ex.length*rowH4}" stroke="${p2===0?C.dim:C.grid}" stroke-width="1"/>`;
     c4 += txt(x, 24+ex.length*rowH4+16, p2+"%", C.dim, "middle"); });
   ex.forEach((v,i)=>{
     const m = v.reduction_rate || 0, y = 24 + i*rowH4 + rowH4/2;
     c4 += txt(L-10, y+4, v.id||v.dataset, C.fg, "end");
     c4 += `<rect x="${L}" y="${y-7}" width="${Math.max(0,(R-L)*m)}" height="14" rx="3" fill="${C.acc}" opacity="${v.superseded?0.35:1}"/>`;
     c4 += txt(R+10, y+4, (m*100).toFixed(0)+"%　GT "+((v.gt||[]).join("+")||"?").replace(/-service/g,"")+"　候选P "+v.candidate_precision+"　Top-1 "+(v.top1_hit?"命中":"未命中")+(v.superseded?"　[历史：已被新数据取代]":""), C.dim);
   });
   c4 += `</svg>`;
 }

 const kpi = agg ? `<div class="grid kv" style="margin-bottom:10px">
   <div><b>平均降噪率</b>${(agg.reduction_rate*100).toFixed(1)}%</div>
   <div><b>簇纯度</b>${(agg.cluster_purity*100).toFixed(0)}%</div>
   <div><b>过度合并</b>${(agg.over_merge_rate*100).toFixed(0)}%</div>
   <div><b>候选 P / R</b>${agg.candidate_precision} / ${agg.candidate_recall}</div>
   <div><b>Top-1 命中率</b>${(agg.top1_hit_rate*100).toFixed(0)}%</div>
   <div><b>MRR</b>${agg.gt_mrr}</div></div>` : "";
 document.getElementById("ch").innerHTML = `
  <div class="card"><h2>评测汇总</h2>${kpi||'<div class="dim">暂无评测数据</div>'}</div>
  <div class="card"><h2>各实验降噪率（均值 ± 标准差，仅统计产生告警的轮次）</h2><div class="chartbox">${c1}</div>
   <div class="muted" style="margin-top:8px"><b>怎么看</b>：条形越长 = 值班人要看的条数越少；误差棒 = 多轮波动。<b>右侧 Top-1 必须一起看</b> —— 降噪 90% 但根因判错，等于把故障藏起来。F04 = 0% 不是失败：它只产生 1 条告警，<b>1 条无噪可降</b>（降噪率必须和告警条数一起看）。</div></div>
  <div class="card"><h2>重复轮次构成 —— 可评测 vs 无告警</h2><div class="chartbox">${c2}</div>
   <div class="muted" style="margin-top:8px"><b>怎么看</b>：蓝 = 这一轮产生了告警（可评测）；红 = <b>一条告警都没有</b>（不可评测）。红色<b>不是脚本报错</b>，而是实验设计问题（故障强度/时长不足以触发告警）。</div>
   <div class="muted" style="margin-top:6px">F06 修复前 3 轮全部无告警；把内存压力 200MB 调到 360MB 并新增「内存占 limit 比例」规则后转为 3/3 触发。</div></div>
  ${ex.length?`<div class="card"><h2>非矩阵实验数据集（单次运行，共 ${ex.length} 份）</h2><div class="chartbox">${c4}</div>
   <div class="muted" style="margin-top:8px"><b>怎么看</b>：F13/F14 是<b>多故障并发</b>，重点看 <b>过度合并率必须为 0</b> —— 把两个独立故障揉成一个簇会让值班人漏掉一个（比「降噪不够」危险得多）。</div>
   <div class="muted" style="margin-top:6px">这些走的是早期「单实验流程」（未进故障矩阵），所以此前不在图表里 —— 包括 <b>F13 级联</b>、<b>F14 多根因</b>、<b>自愈闭环演示</b> 等。</div></div>`:""}
  <div class="card"><h2>RAG 对照：Top-1 命中率与单次平均耗时</h2><div class="chartbox">${c3}</div>
   <div class="muted" style="margin-top:6px"><b>怎么看</b>：两根条比命中率。相同 ⇒ 这是一个<b>负结果</b> —— 结构性修复（规则层 + 后处理层）已把链路带到满分，RAG 在当前矩阵上没有额外空间。</div>${c3?"":'<div class="dim">暂无 RAG 对照数据（需把 rag_ab_summary.json 放进数据快照）</div>'}
    <div class="muted" style="margin-top:8px">两者命中率相同 —— 当前矩阵上检索增强没有增益，结构性修复已把这条链路带到满分。</div></div>`;
}

async function drawEx(){
 const d=await j("/api/experiments");
 const rows=(d.recent||[]).map(r=>`<tr><td>${esc(r.experiment_id)}</td><td>${esc(r.ground_truth)}</td>
   <td class="dim">${esc((r.injected_at||"").substring(11,19))}</td>
   <td>${r.firing_at?`<span class="ok">${esc(r.firing_at.substring(11,19))}</span>`:'<span class="warn">未捕获</span>'}</td>
   <td>${dash(r.events)}</td><td>${dash(r.firing_alerts)}</td>
   <td class="dim">${esc((r.dataset||"").split("/").filter(Boolean).pop())}</td></tr>`);
 const ev=d.eval&&d.eval.aggregate?`<div class="grid kv">
   <div><b>平均降噪率</b>${(d.eval.aggregate.reduction_rate*100).toFixed(1)}%</div>
   <div><b>簇纯度</b>${(d.eval.aggregate.cluster_purity*100).toFixed(1)}%</div>
   <div><b>过度合并</b>${(d.eval.aggregate.over_merge_rate*100).toFixed(1)}%</div>
   <div><b>候选精确率</b>${d.eval.aggregate.candidate_precision}</div>
   <div><b>候选召回率</b>${d.eval.aggregate.candidate_recall}</div>
   <div><b>Top-1 命中率</b>${(d.eval.aggregate.top1_hit_rate*100).toFixed(1)}%</div>
   <div><b>MRR</b>${d.eval.aggregate.gt_mrr}</div></div>`:'<div class="dim">还没有评测结果</div>';
 const rp=d.repeats?`<pre>${esc(JSON.stringify(d.repeats,null,1)).substring(0,1200)}</pre>`:'<div class="dim">重复性实验尚未汇总</div>';
 document.getElementById("ex").innerHTML=`
  <div class="card"><h2>评测汇总（matrix_eval）</h2>${ev}</div>
  <div class="card"><h2>重复性实验汇总</h2>${rp}</div>
  <div class="card"><h2>实验轮次（共 ${d.total_runs} 轮，最近 30）</h2>
   ${tbl(["实验","真实根因","注入","T_firing","事件","firing","数据集"],rows,"还没有实验记录")}</div>`;
}

document.querySelectorAll(".tab").forEach(t=>t.onclick=()=>{
 document.querySelectorAll(".tab").forEach(x=>x.classList.remove("on"));t.classList.add("on");
 ["ov","llm","ag","ex","ch"].forEach(id=>document.getElementById(id).style.display="none");
 document.getElementById(t.dataset.t).style.display="";});
async function all(){try{await drawOv();await drawLLM();await drawAg();await drawEx();await drawCharts()}catch(e){console.error(e)}}
function tick(){document.getElementById("clock").textContent=new Date().toLocaleTimeString("zh-CN",{hour12:false})}
tick();setInterval(tick,1000);all();setInterval(all,10000);
</script></body></html>"""


class H(BaseHTTPRequestHandler):
    def _send(self, body, ctype="application/json; charset=utf-8", code=200):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code); self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def do_GET(self):
        p = self.path.split("?")[0]
        try:
            if p in ("/", "/index.html"):
                return self._send(INDEX_HTML, "text/html; charset=utf-8")
            if p == "/healthz":
                return self._send(json.dumps({"ok": True}))
            fn = API.get(p)
            if fn:
                return self._send(json.dumps(fn(), ensure_ascii=False, default=str))
            return self._send(json.dumps({"error": "not found"}), code=404)
        except Exception as exc:  # noqa: BLE001
            return self._send(json.dumps({"error": str(exc)}, ensure_ascii=False), code=500)

    def log_message(self, *a):
        pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8787)
    ap.add_argument("--cluster", action="store_true", help="集群内形态：实时查 Prometheus/Alertmanager/Agent")
    ap.add_argument("--data", default=None, help="数据快照目录（集群里由 ConfigMap 挂载）")
    args = ap.parse_args()
    CFG["cluster"] = args.cluster
    if args.data:
        CFG["data"] = args.data
    print("AI SRE 控制台启动： http://%s:%d  (cluster=%s)" % (args.host, args.port, CFG["cluster"]))
    ThreadingHTTPServer((args.host, args.port), H).serve_forever()


if __name__ == "__main__":
    sys.exit(main())
