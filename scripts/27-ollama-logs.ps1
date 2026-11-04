#Requires -Version 5.1
<#
.SYNOPSIS
  查看 / 跟随 / 汇总本地大模型（Ollama）的工作日志，并支持"可观测方式"重启。

.DESCRIPTION
  背景（这是本项目踩过的坑 P30）：用 `Start-Process ollama serve` 直接启动时，
  进程的 stdout/stderr 指向一个隐藏控制台，**日志无处可看**；
  而 Ollama 自己的 `%LOCALAPPDATA%\Ollama\server.log` 在 CLI 启动方式下是 0 字节。
  本脚本把两路输出分别重定向到项目目录，并提供查看/跟随/汇总/自检四种用法。

  Ollama 的日志分两路（必须分别看）：
    · stdout（ollama-server.log）     → HTTP 访问日志（GIN）：每个请求的方法/路径/状态/耗时
    · stderr（ollama-server.err.log） → 服务端日志：模型加载、GPU/显存、runner 启动、警告与错误

.EXAMPLE
  pwsh -File scripts/27-ollama-logs.ps1                 # 显示日志路径 + 最后 30 行（两路合并）
  pwsh -File scripts/27-ollama-logs.ps1 -Follow         # 实时跟随（Ctrl+C 退出）
  pwsh -File scripts/27-ollama-logs.ps1 -Summary        # 汇总：请求数/错误/模型加载/平均耗时
  pwsh -File scripts/27-ollama-logs.ps1 -Test           # 发一次推理并打印它的 token 与耗时
  pwsh -File scripts/27-ollama-logs.ps1 -Restart        # 以可观测方式重启 Ollama
#>
param(
    [switch]$Follow,
    [switch]$Summary,
    [switch]$Test,
    [switch]$Restart,
    [int]$Tail = 30,
    [string]$LogDir = (Join-Path $PSScriptRoot '..\_logs\ollama')
)

$ErrorActionPreference = 'Continue'
$Exe = "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe"
$LogDir = (Resolve-Path -LiteralPath (New-Item -ItemType Directory -Force -Path $LogDir)).Path
$Out = Join-Path $LogDir 'ollama-server.log'
$Err = Join-Path $LogDir 'ollama-server.err.log'
$Api = 'http://127.0.0.1:11434'

function Show-Head {
    Write-Host "Ollama 日志目录: $LogDir" -ForegroundColor Cyan
    Write-Host "  stdout（HTTP 访问日志）: $Out"
    Write-Host "  stderr（服务端运行日志）: $Err"
    foreach ($f in @($Out, $Err)) {
        if (Test-Path $f) { Write-Host ("  {0,-26} {1,8:N0} B  最后写入 {2}" -f (Split-Path $f -Leaf), (Get-Item $f).Length, (Get-Item $f).LastWriteTime) }
        else { Write-Host "  $f （不存在）" -ForegroundColor Yellow }
    }
}

function Restart-Ollama {
    Write-Host "停止现有 ollama 进程…" -ForegroundColor Yellow
    Get-Process -Name 'ollama*' -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.Id -Force }
    Start-Sleep -Seconds 3
    if (-not (Test-Path $Exe)) { Write-Host "找不到 $Exe" -ForegroundColor Red; return }
    $env:OLLAMA_MODELS = 'D:\LLM'
    Start-Process -FilePath $Exe -ArgumentList 'serve' -WindowStyle Hidden -RedirectStandardOutput $Out -RedirectStandardError $Err
    Start-Sleep -Seconds 8
    try {
        $v = Invoke-RestMethod -Uri "$Api/api/version" -TimeoutSec 8
        Write-Host "✔ 已以可观测方式启动（版本 $($v.version)），日志 → $LogDir" -ForegroundColor Green
    } catch { Write-Host "✘ 启动后不可达: $($_.Exception.Message)" -ForegroundColor Red }
}

function Show-Summary {
    if (-not (Test-Path $Out)) { Write-Host "还没有访问日志（$Out）" -ForegroundColor Yellow; return }
    $gin = Get-Content -LiteralPath $Out
    $req = $gin | Where-Object { $_ -match '\[GIN\]' }
    $chat = $req | Where-Object { $_ -match '/api/chat' }
    $codes = @{}
    foreach ($l in $req) { if ($l -match '\|\s*(\d{3})\s*\|') { $c = $Matches[1]; $codes[$c] = 1 + ($codes[$c] ?? 0) } }
    $durs = @()
    foreach ($l in $req) { if ($l -match '\|\s*([\d\.]+)(µs|ms|s)\s*\|') { $v = [double]$Matches[1]; $u = $Matches[2]
            switch ($u) { 'µs' { $durs += $v / 1e6 } 'ms' { $durs += $v / 1000 } 's' { $durs += $v } } } }
    Write-Host "`n── 请求汇总（来自 stdout 的 GIN 访问日志）──" -ForegroundColor Cyan
    Write-Host ("  请求总数      : {0}" -f $req.Count)
    Write-Host ("  其中 /api/chat: {0}" -f $chat.Count)
    Write-Host ("  状态码分布    : {0}" -f (($codes.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '))
    if ($durs.Count) {
        Write-Host ("  平均耗时      : {0:N2} s   最慢: {1:N2} s" -f (($durs | Measure-Object -Average).Average, ($durs | Measure-Object -Maximum).Maximum))
    }
    if (Test-Path $Err) {
        $errl = Get-Content -LiteralPath $Err
        $loads = $errl | Where-Object { $_ -match 'loading model|starting llama-server' }
        $warns = $errl | Where-Object { $_ -match 'level=WARN' }
        $errs = $errl | Where-Object { $_ -match 'level=ERROR' }
        $gpu = $errl | Where-Object { $_ -match 'gpu memory|CUDA devices' } | Select-Object -Last 1
        Write-Host "`n── 服务端汇总（来自 stderr）──" -ForegroundColor Cyan
        Write-Host ("  模型加载事件  : {0}" -f $loads.Count)
        Write-Host ("  WARN / ERROR  : {0} / {1}" -f $warns.Count, $errs.Count)
        if ($gpu) { Write-Host ("  最近 GPU 行   : {0}" -f $gpu.Trim().Substring(0, [Math]::Min(110, $gpu.Trim().Length))) }
        $warns | Select-Object -Last 3 | ForEach-Object { Write-Host ("    ! " + $_.Trim().Substring(0, [Math]::Min(120, $_.Trim().Length))) -ForegroundColor Yellow }
    }
}

function Invoke-Test {
    $sizeOut = if (Test-Path $Out) { (Get-Item $Out).Length } else { 0 }
    $sizeErr = if (Test-Path $Err) { (Get-Item $Err).Length } else { 0 }
    Write-Host "发一次推理（qwen2.5:7b）…" -ForegroundColor Cyan
    $body = @{ model = 'qwen2.5:7b'; stream = $false; options = @{ temperature = 0 }
               messages = @(@{ role = 'user'; content = '用一句话说明什么是 Pod（20 字内）' }) } | ConvertTo-Json -Depth 6
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try { $r = Invoke-RestMethod -Uri "$Api/api/chat" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 300 }
    catch { Write-Host "✘ 调用失败: $($_.Exception.Message)" -ForegroundColor Red; return }
    $sw.Stop()
    Write-Host "`n回复: $($r.message.content)"
    Write-Host "`n── 本次调用的工作记录（API 返回，比日志更结构化）──" -ForegroundColor Cyan
    Write-Host ("  模型          : {0}" -f $r.model)
    Write-Host ("  加载耗时      : {0:N2} s" -f ($r.load_duration / 1e9))
    Write-Host ("  提示词 token  : {0}（{1:N0} ms）" -f $r.prompt_eval_count, ($r.prompt_eval_duration / 1e6))
    Write-Host ("  生成 token    : {0}（{1:N0} ms → {2:N1} token/s）" -f $r.eval_count, ($r.eval_duration / 1e6), ($r.eval_count / ($r.eval_duration / 1e9)))
    Write-Host ("  端到端耗时    : {0:N2} s" -f ($r.total_duration / 1e9))
    Start-Sleep -Seconds 2
    Write-Host "`n── 本次调用在日志里留下的痕迹 ──" -ForegroundColor Cyan
    foreach ($pair in @(@{ f = $Out; n = $sizeOut; tag = 'stdout' }, @{ f = $Err; n = $sizeErr; tag = 'stderr' })) {
        if (-not (Test-Path $pair.f)) { continue }
        $txt = Get-Content -LiteralPath $pair.f -Raw
        if ($txt.Length -gt $pair.n) {
            $new = $txt.Substring($pair.n) -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 8
            foreach ($l in $new) { Write-Host ("  [{0}] {1}" -f $pair.tag, $l.Trim().Substring(0, [Math]::Min(140, $l.Trim().Length))) }
        }
    }
}

Show-Head
if ($Restart) { Restart-Ollama }
if ($Summary) { Show-Summary; return }
if ($Test) { Invoke-Test; return }
if ($Follow) {
    Write-Host "`n实时跟随中（Ctrl+C 退出）…" -ForegroundColor Green
    $j1 = Start-Job -ScriptBlock { param($p) Get-Content -LiteralPath $p -Wait -Tail 5 | ForEach-Object { "[stdout] $_" } } -ArgumentList $Out
    $j2 = Start-Job -ScriptBlock { param($p) Get-Content -LiteralPath $p -Wait -Tail 5 | ForEach-Object { "[stderr] $_" } } -ArgumentList $Err
    try { while ($true) { Receive-Job $j1; Receive-Job $j2; Start-Sleep -Milliseconds 400 } }
    finally { Stop-Job $j1, $j2 -ErrorAction SilentlyContinue; Remove-Job $j1, $j2 -Force -ErrorAction SilentlyContinue }
}
foreach ($f in @($Out, $Err)) {
    Write-Host ("`n──── {0}（最后 {1} 行）────" -f (Split-Path $f -Leaf), $Tail) -ForegroundColor Cyan
    if (Test-Path $f) { Get-Content -LiteralPath $f -Tail $Tail | ForEach-Object { "  $_" } } else { Write-Host "  （文件还不存在，先跑 -Restart 或调用一次模型）" -ForegroundColor Yellow }
}