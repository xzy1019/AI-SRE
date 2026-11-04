#Requires -Version 5.1
<#
.SYNOPSIS
  从本机拉取容器镜像并分发到集群节点（Windows 侧执行）。

.DESCRIPTION
  背景：集群节点的网络受限 —— quay.io / ghcr.io 的 manifest 可达但镜像层
  重定向到 AWS S3 / GitHub CDN 后 TLS 握手超时；docker.io 认证端点直接拒绝；
  registry.k8s.io 重定向到 Google 制品库超时。

  本机（开发机）网络较宽松，可访问 GitHub、ghcr.io、quay.io 及国内镜像源。
  因此采用「本机拉取 → 导出 tar → 局域网传输 → ctr 导入」的方式，绕开节点网络限制。

  导入后镜像名若与清单不一致，会用 ctr 改名回原始名，使 k8s 清单保持上游原名。

.EXAMPLE
  .\07-distribute-images.ps1                    # 完整流程
  .\07-distribute-images.ps1 -SkipPull          # 跳过拉取，只用已有 tar
  .\07-distribute-images.ps1 -OnlyNode 172.29.20.22
#>
param(
    [string]$ImagesDir = "$env:TEMP\aisre-images",
    [string]$ToolsDir  = "$env:TEMP\aisre-tools",
    # 密码不写进仓库：从环境变量读取（$env:LAB_ROOT_PASSWORD）
    [string]$Password  = $env:LAB_ROOT_PASSWORD,
    [string]$OnlyNode  = '',
    [switch]$SkipPull,
    [switch]$SkipTransfer
)

$ErrorActionPreference = 'Continue'

if ([string]::IsNullOrWhiteSpace($Password)) {
    Write-Host 'ERROR: 未提供 SSH 密码。请先执行：  $env:LAB_ROOT_PASSWORD = "<你的 root 密码>"' -ForegroundColor Red
    exit 1
}

# ---------- 镜像表 ----------
# File    : tar 文件名（不含扩展名）
# Target  : k8s 清单中使用的原始镜像名（导入后要改成的名字）
# Source  : 本机拉取时使用的源（国内镜像路径优先）
# Groups  : 需要该镜像的分组（node = 所有节点；full = 仅 k8s-obs）
$ImageMap = @(
    @{ File='node-exporter';     Target='quay.io/prometheus/node-exporter:v1.8.2';                        Source='quay.io/prometheus/node-exporter:v1.8.2';                        Groups=@('node','full') },
    @{ File='prometheus';        Target='quay.io/prometheus/prometheus:v2.55.0';                          Source='quay.io/prometheus/prometheus:v2.55.0';                          Groups=@('full') },
    @{ File='alertmanager';      Target='quay.io/prometheus/alertmanager:v0.28.1';                        Source='quay.io/prometheus/alertmanager:v0.28.1';                        Groups=@('full') },
    @{ File='kube-state-metrics';Target='registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.14.0';  Source='k8s.m.daocloud.io/kube-state-metrics/kube-state-metrics:v2.14.0';  Groups=@('full') },
    @{ File='grafana';           Target='docker.io/grafana/grafana:11.4.0';                               Source='docker.m.daocloud.io/grafana/grafana:11.4.0';                    Groups=@('full') },
    @{ File='loki';              Target='docker.io/grafana/loki:3.3.2';                                   Source='docker.m.daocloud.io/grafana/loki:3.3.2';                        Groups=@('full') },
    # 注意：otelcol-contrib 0.116.0 的二进制是动态链接的，而该镜像没有 glibc 加载器，
    # 容器启动会报 exec /otelcol-contrib: no such file or directory（详见 manifests/observability/08-otel-collector.yaml）。
    # 0.113.0 的二进制为静态链接，可用。
    @{ File='otel-collector';    Target='docker.io/otel/opentelemetry-collector-contrib:0.113.0';         Source='docker.m.daocloud.io/otel/opentelemetry-collector-contrib:0.113.0'; Groups=@('full') },
    @{ File='chaos-mesh';        Target='ghcr.io/chaos-mesh/chaos-mesh:v2.8.7';                           Source='ghcr.m.daocloud.io/chaos-mesh/chaos-mesh:v2.8.7';                Groups=@('full') },
    @{ File='chaos-daemon';      Target='ghcr.io/chaos-mesh/chaos-daemon:v2.8.7';                         Source='ghcr.m.daocloud.io/chaos-mesh/chaos-daemon:v2.8.7';              Groups=@('node','full') },
    @{ File='chaos-dashboard';   Target='ghcr.io/chaos-mesh/chaos-dashboard:v2.8.7';                      Source='ghcr.m.daocloud.io/chaos-mesh/chaos-dashboard:v2.8.7';           Groups=@('full') },
    @{ File='chaos-coredns';     Target='ghcr.io/chaos-mesh/chaos-coredns:v0.2.8';                        Source='ghcr.m.daocloud.io/chaos-mesh/chaos-coredns:v0.2.8';             Groups=@('full') }
)

# ---------- 节点分组 ----------
# node 组 = 所有节点；full 组 = 仅 k8s-obs
$NodeGroups = @(
    @{ Ip='172.29.20.22'; Group='full'; Role='可观测性（含全部镜像）' },
    @{ Ip='172.29.20.21'; Group='node'; Role='控制面（基础镜像）' },
    @{ Ip='172.29.20.23'; Group='node'; Role='业务节点（基础镜像）' },
    @{ Ip='172.29.20.24'; Group='node'; Role='业务节点（基础镜像）' },
    @{ Ip='172.29.20.25'; Group='node'; Role='AIOps 节点（基础镜像）' }
)

function Say  ($m) { Write-Host "[$(Get-Date -Format HH:mm:ss)] $m" -ForegroundColor Cyan }
function Good ($m) { Write-Host "  ✔ $m" -ForegroundColor Green }
function Warn ($m) { Write-Host "  ! $m" -ForegroundColor Yellow }
function Bad  ($m) { Write-Host "  ✘ $m" -ForegroundColor Red }

# ---------- 免交互 SSH 准备 ----------
if (-not (Test-Path -LiteralPath $ToolsDir)) { New-Item -ItemType Directory -Force -Path $ToolsDir | Out-Null }
$AskPass = Join-Path $ToolsDir 'askpass.cmd'
Set-Content -LiteralPath $AskPass -Encoding ASCII -Value "@echo off`r`necho $Password"
$env:SSH_ASKPASS = $AskPass
$env:SSH_ASKPASS_REQUIRE = 'force'
$env:DISPLAY = 'localhost:0'
$SshOpt = @('-o','ConnectTimeout=10','-o','StrictHostKeyChecking=no','-o',
            'PreferredAuthentications=password','-o','PubkeyAuthentication=no',
            '-o','NumberOfPasswordPrompts=1')

function Invoke-Remote {
    param([string]$Ip, [string]$Command)
    # 原生命令写 stderr 时 PowerShell 会包装成 ErrorRecord，这里统一收敛为字符串
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        $out = & ssh.exe @SshOpt "root@$Ip" $Command 2>&1
        return ($out | Where-Object { "$_" -notmatch 'Authorized users only' })
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Invoke-Copy {
    param([string]$Ip, [string]$LocalPath, [string]$RemotePath)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        & scp.exe @SshOpt $LocalPath "root@$Ip`:$RemotePath" 2>&1 | Out-Null
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
}

# ---------- crane 准备 ----------
$Crane = Join-Path $ToolsDir 'crane.exe'
if (-not (Test-Path -LiteralPath $Crane)) {
    Say "crane 未找到，正在下载..."
    $tgz = Join-Path $ToolsDir 'crane.tar.gz'
    Invoke-WebRequest -Uri 'https://github.com/google/go-containerregistry/releases/download/v0.22.1/go-containerregistry_Windows_x86_64.tar.gz' -OutFile $tgz -TimeoutSec 300 -UseBasicParsing
    & tar.exe -xzf $tgz -C $ToolsDir
}
if (-not (Test-Path -LiteralPath $Crane)) { throw "crane.exe 不可用" }
if (-not (Test-Path -LiteralPath $ImagesDir)) { New-Item -ItemType Directory -Force -Path $ImagesDir | Out-Null }

# ---------- 1. 本机拉取 ----------
if (-not $SkipPull) {
    Say "1/3 本机拉取镜像"
    foreach ($img in $ImageMap) {
        $tar = Join-Path $ImagesDir "$($img.File).tar"
        if ((Test-Path -LiteralPath $tar) -and (Get-Item -LiteralPath $tar).Length -gt 500KB) {
            Good "$($img.File) 已存在（$([math]::Round((Get-Item -LiteralPath $tar).Length/1MB,1)) MB）"
            continue
        }
        $t0 = Get-Date
        & $Crane pull --platform linux/amd64 $img.Source $tar 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $tar)) {
            Good "$($img.File)  $([math]::Round((Get-Item -LiteralPath $tar).Length/1MB,1)) MB  $([int]((Get-Date)-$t0).TotalSeconds)s"
        } else {
            Bad "$($img.File) 拉取失败（源: $($img.Source)）"
        }
    }
}

# ---------- 2. 分发 ----------
if (-not $SkipTransfer) {
    $targets = if ($OnlyNode) { $NodeGroups | Where-Object { $_.Ip -eq $OnlyNode } } else { $NodeGroups }
    Say "2/3 分发到节点（$($targets.Count) 台）"
    foreach ($node in $targets) {
        Say "  → $($node.Ip)  [$($node.Role)]"
        $need = $ImageMap | Where-Object { $_.Groups -contains $node.Group }
        $local = @()
        foreach ($img in $need) {
            $tar = Join-Path $ImagesDir "$($img.File).tar"
            if (Test-Path -LiteralPath $tar) {
                Invoke-Remote -Ip $node.Ip -Command "mkdir -p /var/lib/aisre-images" | Out-Null
                if ((Invoke-Copy -Ip $node.Ip -LocalPath $tar -RemotePath "/var/lib/aisre-images/$($img.File).tar") -eq 0) { $local += $img }
            }
        }
        Good "已传输 $($local.Count)/$($need.Count) 个 tar 包"
    }
}

# ---------- 3. 导入 + 改名 ----------
Say "3/3 导入并改名"
$targets = if ($OnlyNode) { $NodeGroups | Where-Object { $_.Ip -eq $OnlyNode } } else { $NodeGroups }
foreach ($node in $targets) {
    Say "  → $($node.Ip)"
    $need = $ImageMap | Where-Object { $_.Groups -contains $node.Group }
    $cmds = @()
    foreach ($img in $need) {
        $cmds += "if ctr -n k8s.io images ls -q 2>/dev/null | grep -qxF '$($img.Target)'; then echo '  [skip] $($img.File)'; else ctr -n k8s.io images import /var/lib/aisre-images/$($img.File).tar >/dev/null 2>&1 && echo '  [import] $($img.File)'; fi"
        if ($img.Target -ne $img.Source) {
            $cmds += "ctr -n k8s.io images tag '$($img.Source)' '$($img.Target)' >/dev/null 2>&1 && echo '  [tag]     $($img.File)' || true"
        }
    }
    $script = ($cmds -join "`n")
    $enc = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script))
    $out = Invoke-Remote -Ip $node.Ip -Command "echo '$enc' | base64 -d | bash"
    $out | Where-Object { $_ -match '^\s*\[' } | ForEach-Object { Write-Host "    $($_.Trim())" }
}

Say "完成"
Write-Host ""
Write-Host "验证：" -ForegroundColor Cyan
Write-Host "  验证：ssh root@172.29.20.22 后执行 crictl images 查看预置镜像"
Write-Host "  完整检查：bash scripts/08-verify-images.sh"