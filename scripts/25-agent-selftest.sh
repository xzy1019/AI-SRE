#!/usr/bin/env bash
# ============================================================================
# 25-agent-selftest.sh —— aisre-agent 策略引擎的正/反用例验证（含真实执行）
#
# 用法： 在控制面执行  bash 25-agent-selftest.sh [目标Deployment]
#
# 验证 9 项：
#   ① L1 restart 被允许（dry-run）        ② L1 restart 真实执行并触发滚动重启
#   ③ L3（scale 到 0）被拒                 ④ L2（扩缩容）未经 approved 被拒
#   ⑤ 越界命名空间（kube-system）被拒      ⑥ 冷却期内重复执行被拒
#   ⑦ 幂等：同 incident 同动作二次执行被拒 ⑧ 审计链完整性校验
#   ⑨ 目标不存在时被拒
# ============================================================================
set -uo pipefail

APP="${1:-payment}"
NS="demo-app"
C_R=$'\033[0;31m'; C_G=$'\033[0;32m'; C_Y=$'\033[0;33m'; C_B=$'\033[0;36m'; C_0=$'\033[0m'
PASS=0; FAIL=0
ok()   { printf '  %s✔%s %s\n' "$C_G" "$C_0" "$*"; PASS=$((PASS+1)); }
bad()  { printf '  %s✘%s %s\n' "$C_R" "$C_0" "$*"; FAIL=$((FAIL+1)); }
step() { printf '\n%s== %s ==%s\n' "$C_B" "$*" "$C_0"; }

[ "$(id -u)" -eq 0 ] || { echo "必须以 root 执行"; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "未找到 kubectl"; exit 1; }

FE=$(kubectl -n demo-app get pod -l app=frontend -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -n "$FE" ] || { echo "未找到 frontend Pod（自检代理用）"; exit 1; }

agent() {   # agent <path> <json>
  kubectl -n demo-app exec "$FE" -- python3 -c "
import json,urllib.request,sys
path, body = sys.argv[1], sys.argv[2]
url='http://aisre-agent.aiops.svc:8080'+path
req=urllib.request.Request(url, data=body.encode(), headers={'Content-Type':'application/json'}, method='POST')
try:
    r=urllib.request.urlopen(req, timeout=20)
    print(r.status, r.read().decode())
except urllib.error.HTTPError as e:
    print(e.code, e.read().decode())
" "$1" "$2"
}

echo "════════════════════════════════════════════"
printf '  aisre-agent 策略自检（目标: %s/%s）\n' "$NS" "$APP"
echo "════════════════════════════════════════════"

INC="selftest-$(date +%s)"

step "① L1 restart dry-run（应允许，且不执行）"
OUT=$(agent /propose "{\"incident_id\":\"$INC-1\",\"action\":\"restart\",\"level\":\"L1\",\"target\":{\"namespace\":\"$NS\",\"deployment\":\"$APP\"},\"dry_run\":true}")
echo "$OUT" | grep -q '"allow":true' && ok "允许（dry-run 不执行）" || bad "被拒: $OUT"

step "② L1 restart 真实执行（应允许，并触发滚动重启）"
BEFORE=$(kubectl -n "$NS" get deploy "$APP" -o jsonpath='{.spec.template.metadata.annotations.kubectl\.kubernetes\.io/restartedAt}' 2>/dev/null)
OUT=$(agent /execute "{\"incident_id\":\"$INC-2\",\"action\":\"restart\",\"level\":\"L1\",\"target\":{\"namespace\":\"$NS\",\"deployment\":\"$APP\"},\"dry_run\":false}")
if echo "$OUT" | grep -q '"executed":true'; then
  sleep 4
  AFTER=$(kubectl -n "$NS" get deploy "$APP" -o jsonpath='{.spec.template.metadata.annotations.kubectl\.kubernetes\.io/restartedAt}' 2>/dev/null)
  [ -n "$AFTER" ] && [ "$AFTER" != "$BEFORE" ] && ok "已执行，restartedAt=$AFTER" || bad "已执行但注解未变化（before=$BEFORE after=$AFTER）"
else
  bad "执行失败: $OUT"
fi

step "③ L3 scale 到 0（应被拒：爆炸半径）"
OUT=$(agent /execute "{\"incident_id\":\"$INC-3\",\"action\":\"scale\",\"level\":\"L3\",\"replicas\":0,\"approved\":true,\"target\":{\"namespace\":\"$NS\",\"deployment\":\"$APP\"}}")
echo "$OUT" | grep -q '"allow":false' && ok "被拒（P1/P4）" || bad "未拦截: $OUT"

step "④ L2 扩容未经 approved（应被拒：动作分级）"
OUT=$(agent /execute "{\"incident_id\":\"$INC-4\",\"action\":\"scale\",\"level\":\"L2\",\"replicas\":3,\"target\":{\"namespace\":\"$NS\",\"deployment\":\"$APP\"}}")
echo "$OUT" | grep -q '"allow":false' && ok "被拒（P1）" || bad "未拦截: $OUT"

step "⑤ 越界命名空间 kube-system（应被拒：白名单）"
OUT=$(agent /execute "{\"incident_id\":\"$INC-5\",\"action\":\"restart\",\"level\":\"L1\",\"target\":{\"namespace\":\"kube-system\",\"deployment\":\"coredns\"}}")
echo "$OUT" | grep -q '"allow":false' && ok "被拒（P2）" || bad "未拦截: $OUT"

step "⑥ 冷却期内重复执行（应被拒：冷却期）"
OUT=$(agent /execute "{\"incident_id\":\"$INC-6\",\"action\":\"restart\",\"level\":\"L1\",\"target\":{\"namespace\":\"$NS\",\"deployment\":\"$APP\"}}")
echo "$OUT" | grep -q '"allow":false' && ok "被拒（P3/P6）" || bad "未拦截: $OUT"

step "⑦ 幂等：同 incident 同动作二次执行（应被拒）"
OUT=$(agent /execute "{\"incident_id\":\"$INC-2\",\"action\":\"restart\",\"level\":\"L1\",\"target\":{\"namespace\":\"$NS\",\"deployment\":\"$APP\"}}")
echo "$OUT" | grep -q '"allow":false' && ok "被拒（P6/P3）" || bad "未拦截: $OUT"

step "⑧ 审计链完整性"
OUT=$(kubectl -n aiops exec deploy/aisre-agent -- wget -qO- http://127.0.0.1:8080/audit/verify 2>/dev/null)
echo "$OUT" | grep -q '"chain_ok":true' && ok "哈希链完整：$OUT" || bad "审计链异常: $OUT"

step "⑨ 目标不存在（应被拒：前置条件）"
OUT=$(agent /execute "{\"incident_id\":\"$INC-9\",\"action\":\"restart\",\"level\":\"L1\",\"target\":{\"namespace\":\"$NS\",\"deployment\":\"no-such-deploy\"}}")
echo "$OUT" | grep -q '"allow":false' && ok "被拒（P7）" || bad "未拦截: $OUT"

echo
printf '%s===== 自检汇总 =====%s\n' "$C_B" "$C_0"
printf '  %s通过 %d 项%s，%s失败 %d 项%s\n' "$C_G" "$PASS" "$C_0" "$C_R" "$FAIL" "$C_0"
printf '  审计记录（最近 3 条）：\n'
kubectl -n aiops exec deploy/aisre-agent -- wget -qO- http://127.0.0.1:8080/audit 2>/dev/null \
  | python3 -c "
import json,sys
d=json.load(sys.stdin)
for r in d['records'][-3:]:
    print('    #%d %-9s %-8s %-28s prev=%s… hash=%s…' % (
      r['seq'], r['decision'], r['action'], r['target'], r['prev_hash'][:8], r['hash'][:8]))
print('    总记录数:', d['total'])
"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1