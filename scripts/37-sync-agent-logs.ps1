#Requires -Version 5.1
<#
.SYNOPSIS
  从集群同步 Agent / 接入层的工作日志与指标到本地（供图形化控制台读取）。

.DESCRIPTION
  图形化控制台（scripts/38-dashboard.py）跑在开发机上读本地文件；
  Agent 的审计日志与指标在集群里，本脚本负责「拉下来」：

    _logs/agent/audit.jsonl      aisre-agent 审计哈希链（每行一条）
    _logs/agent/metrics.json     agent + ingest + 集群关键指标
    _logs/agent/last-sync.txt    本次同步时间

  设计约束（都是踩过的坑）：
    · 远程命令一律「不带管道」—— SSH 里再套引号/管道极易被吞，改成本地解析（P47）
    · 本文件必须存成 UTF-8 **带 BOM**，否则 PowerShell 5.1 按 GBK 读会解析失败（P48）

  用法：
    .\scripts\37-sync-agent-logs.ps1
#>
param(
    [string]$ControlPlane = '172.29.20.21',
    [string]$User = 'root',
    # 密码不写进仓库：从环境变量读取（$env:LAB_ROOT_PASSWORD）
    [string]$Password = $env:LAB_ROOT_PASSWORD,
    [string]$OutDir = (Join-Path $PSScriptRoot '..\_logs\agent')
)

$ErrorActionPreference = 'Continue'

if ([string]::IsNullOrWhiteSpace($Password)) {
    Write-Host 'ERROR: 未提供 SSH 密码。请先执行：  $env:LAB_ROOT_PASSWORD = "<你的 root 密码>"' -ForegroundColor Red
    exit 1
}
$OutDir = [System.IO.Path]::GetFullPath($OutDir)
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

# 免交互 SSH（与 07-distribute-images.ps1 同一套 askpass 机制）
$ToolsDir = Join-Path $env:TEMP 'aisre-tools'
if (-not (Test-Path -LiteralPath $ToolsDir)) { New-Item -ItemType Directory -Force -Path $ToolsDir | Out-Null }
$AskPass = Join-Path $ToolsDir 'askpass.cmd'
Set-Content -LiteralPath $AskPass -Encoding ASCII -Value (@('@echo off', "echo $Password") -join "`r`n")
$env:SSH_ASKPASS = $AskPass; $env:SSH_ASKPASS_REQUIRE = 'force'; $env:DISPLAY = 'localhost:0'
$KnownHosts = Join-Path $ToolsDir 'known_hosts'
$SshOpt = @('-o','ConnectTimeout=10','-o','StrictHostKeyChecking=accept-new',"-o","UserKnownHostsFile=$KnownHosts",
            '-o','PreferredAuthentications=password','-o','PubkeyAuthentication=no','-o','NumberOfPasswordPrompts=1')

function Say($m)  { Write-Host "[$(Get-Date -Format HH:mm:ss)] $m" -ForegroundColor Cyan }
function Good($m) { Write-Host "  OK   $m" -ForegroundColor Green }
function Bad($m)  { Write-Host "  FAIL $m" -ForegroundColor Red }

function Invoke-Remote([string]$Cmd) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try { return (& ssh.exe @SshOpt "$User@$ControlPlane" $Cmd 2>$null) }
    finally { $ErrorActionPreference = $prev }
}

Say "同步集群日志 -> $OutDir"
$metrics = @{}

# 1) Agent 审计链
$audit = Invoke-Remote 'kubectl -n aiops exec deploy/aisre-agent -- cat /data/audit.jsonl'
if ($audit) {
    ($audit -join "`n") | Set-Content -LiteralPath (Join-Path $OutDir 'audit.jsonl') -Encoding UTF8
    Good "audit.jsonl: $($audit.Count) 条"
} else { Bad "审计链拉取为空（agent 未就绪？）" }

# 2) metrics 文本（不带管道，过滤在本地做）
$agentRaw = Invoke-Remote 'kubectl -n aiops exec deploy/aisre-agent -- wget -qO- http://127.0.0.1:8080/metrics'
foreach ($l in ($agentRaw | Where-Object { $_ -match '^aisre_' })) {
    if ($l -match '^([A-Za-z_][A-Za-z0-9_]*)\s+(.+)$') { $metrics["agent.$($Matches[1])"] = $Matches[2].Trim() }
}
$ingestRaw = Invoke-Remote 'kubectl -n aiops exec deploy/aisre-ingest -- wget -qO- http://127.0.0.1:8080/metrics'
foreach ($l in ($ingestRaw | Where-Object { $_ -match '^ingest_' })) {
    if ($l -match '^([A-Za-z_][A-Za-z0-9_]*)\s+(.+)$') { $metrics["ingest.$($Matches[1])"] = $Matches[2].Trim() }
}
Good "agent 指标 $((($metrics.Keys | Where-Object { $_ -like 'agent.*' })).Count) 项 / ingest 指标 $((($metrics.Keys | Where-Object { $_ -like 'ingest.*' })).Count) 项"

# 3) 集群概览：拉 JSON，本地解析
$rulesRaw = Invoke-Remote 'curl -s http://127.0.0.1:30090/api/v1/rules'
try {
    $rj = (($rulesRaw | Where-Object { $_ }) -join "`n") | ConvertFrom-Json
    $n = 0; foreach ($g in $rj.data.groups) { $n += $g.rules.Count }
    $metrics['cluster.rules_loaded'] = "$n"
} catch { Bad "规则数解析失败：$($_.Exception.Message)" }
$alertsRaw = Invoke-Remote 'curl -s http://127.0.0.1:30093/api/v2/alerts'
try {
    $aj = (($alertsRaw | Where-Object { $_ }) -join "`n") | ConvertFrom-Json
    $metrics['cluster.alerts_active'] = "$(@($aj).Count)"
} catch { Bad "活动告警解析失败：$($_.Exception.Message)" }
$pairs = @(
    @{ k = 'nodes_ready';   c = 'kubectl get nodes --no-headers | grep -cw Ready' },
    @{ k = 'pods_ready';    c = 'kubectl -n demo-app get pods --no-headers | grep -c 1/1' },
    @{ k = 'chaos_objects'; c = 'kubectl -n chaos-mesh get podchaos --no-headers | wc -l' }
)
foreach ($p in $pairs) {
    $v = Invoke-Remote $p.c
    if ($v) { $metrics["cluster.$($p.k)"] = ("$v" -replace '\s', '') }
}
$metrics['synced_at'] = (Get-Date).ToString('s')
$metrics | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutDir 'metrics.json') -Encoding UTF8
Good "metrics.json: $($metrics.Count) 项"

# 4) 同步标记
$stamp = @(
  "synced_at = $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
  "control_plane = $ControlPlane",
  "audit_lines = $(if ($audit) { $audit.Count } else { 0 })"
) -join "`n"
$stamp | Set-Content -LiteralPath (Join-Path $OutDir 'last-sync.txt') -Encoding UTF8
Say "完成"
