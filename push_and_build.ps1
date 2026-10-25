<#
  push_and_build.ps1 —— 一条命令把 SparkKeeper 推到 GitHub 并跑出 IPA
  ------------------------------------------------------------------
  用法（在本目录下，PowerShell 5.1 即可）：

    .\push_and_build.ps1 -Token ghp_xxxxxxxxxxxxxxxx

  可选：
    -Repo SparkKeeper        仓库名（默认 SparkKeeper）
    -Private                 建成私有仓库（默认公开；公开仓库的 Actions 免费不限量）
    -NoWait                  只推送、不等待构建
    -OutDir .\out            产物下载目录（默认 .\out）

  它会：探测 token 归属 → 仓库不存在就建 → 推送 main → 等 Actions 跑完
        → 失败时打印最后 200 行日志 → 成功时把 IPA 下载到 -OutDir。
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Token,
  [string]$Repo = "SparkKeeper",
  [switch]$Private,
  [switch]$NoWait,
  [string]$OutDir = ".\out"
)

$ErrorActionPreference = "Stop"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$Git = "C:\Users\Administrator\.dsh\tools\mingit\cmd\git.exe"
if (-not (Test-Path $Git)) {
  $c = Get-Command git -ErrorAction SilentlyContinue
  if ($c) { $Git = $c.Source } else { throw "找不到 git：$Git" }
}

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not (Test-Path (Join-Path $Root "SparkKeeper.xcodeproj"))) {
  throw "这个脚本要放在 SparkKeeper 仓库根目录（含 SparkKeeper.xcodeproj 的那一层）"
}
$Api  = "https://api.github.com"
$Hdr  = @{
  Authorization          = "Bearer $Token"
  Accept                 = "application/vnd.github+json"
  "X-GitHub-Api-Version" = "2022-11-28"
  "User-Agent"           = "SparkKeeper-Push"
}

function Say($m) { Write-Host "==> $m" -ForegroundColor Cyan }

# ---------- 1. 探测身份 ----------
Say "校验 token"
try {
  $me = Invoke-RestMethod -Uri "$Api/user" -Headers $Hdr -Method Get
} catch {
  throw "token 无效或没有 user 权限：$($_.Exception.Message)"
}
$Owner = $me.login
Say "身份：$Owner（$($me.name)）"

# ---------- 2. 建仓库 ----------
Say "检查仓库 $Owner/$Repo"
$exists = $true
try {
  Invoke-RestMethod -Uri "$Api/repos/$Owner/$Repo" -Headers $Hdr -Method Get | Out-Null
  Say "仓库已存在，直接推送"
} catch {
  $exists = $false
}

if (-not $exists) {
  Say "创建仓库 $Owner/$Repo（Private=$([bool]$Private)）"
  $body = @{ name = $Repo; private = [bool]$Private; auto_init = $false } | ConvertTo-Json
  try {
    Invoke-RestMethod -Uri "$Api/user/repos" -Headers $Hdr -Method Post -Body $body -ContentType "application/json" | Out-Null
  } catch {
    throw "建仓库失败：$($_.Exception.Message)"
  }
  Start-Sleep -Seconds 2
}

$Full = "$Owner/$Repo"
$CleanUrl = "https://github.com/$Full.git"

# ---------- 3. 推送 ----------
Say "推送 main → $CleanUrl"
$basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("x-access-token:$Token"))

$prevEap = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$existingRemotes = (& $Git -C $Root remote) 2>$null
if ($existingRemotes -contains "origin") {
  & $Git -C $Root remote remove origin 2>&1 | Out-Null
}
& $Git -C $Root remote add origin $CleanUrl 2>&1 | Out-Null
$ErrorActionPreference = $prevEap
if ($LASTEXITCODE -ne 0) { throw "配置 remote 失败（退出码 $LASTEXITCODE）" }

$before = (& $Git -C $Root rev-parse HEAD).Trim()
# github.com:443 经常被中途重置（Recv failure / schannel closed abruptly）或直接超时，
# 而 api.github.com 同一时刻是好的。所以 push 必须带退避重试。
# 注意：git 失败会往 stderr 写字，在 $ErrorActionPreference = "Stop" 下
# 会被 PowerShell 当成终止性异常，循环根本走不到第二次——必须临时切 Continue。
$prevEapPush = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$pushOk = $false
for ($i = 1; $i -le 8; $i++) {
  & $Git -C $Root -c "http.extraheader=AUTHORIZATION: basic $basic" push -u origin main 2>&1 | Out-Host
  if ($LASTEXITCODE -eq 0) { $pushOk = $true; break }
  Say "推送第 $i 次失败（退出码 $LASTEXITCODE），$((3 * $i)) 秒后重试"
  Start-Sleep -Seconds (3 * $i)
}
$ErrorActionPreference = $prevEapPush
if (-not $pushOk) { throw "推送失败：8 次重试都没成功（github.com:443 被重置）" }
Say "推送完成：$before"

if ($NoWait) {
  Say "已跳过等待。构建页面：https://github.com/$Full/actions"
  return
}

# ---------- 4. 等 Actions ----------
Say "等待 GitHub Actions 接单（最多 3 分钟）"
$run = $null
$deadline = (Get-Date).AddMinutes(3)
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Seconds 6
  try {
    $runs = Invoke-RestMethod -Uri "$Api/repos/$Full/actions/runs?per_page=10" -Headers $Hdr -Method Get
  } catch { continue }
  $run = $runs.workflow_runs | Where-Object { $_.head_sha -eq $before } | Select-Object -First 1
  if ($run) { break }
}
if (-not $run) { throw "3 分钟内没看到对应 run。请打开 https://github.com/$Full/actions 手动查看" }

Say "run #$($run.run_number) 已开始：$($run.html_url)"
$runId = $run.id

Say "构建中（macOS 15 上首次通常 3–8 分钟，最多等 40 分钟）"
$deadline = (Get-Date).AddMinutes(40)
$state = ""
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Seconds 15
  $cur = Invoke-RestMethod -Uri "$Api/repos/$Full/actions/runs/$runId" -Headers $Hdr -Method Get
  $state = "$($cur.status)/$($cur.conclusion)"
  Write-Host ("    " + (Get-Date -Format "HH:mm:ss") + "  " + $state) -ForegroundColor DarkGray
  if ($cur.status -eq "completed") { break }
}

if ($state -notlike "completed/success") {
  Say "构建未成功：$state"
  Say "拉取日志尾部："
  try {
    $jobs = Invoke-RestMethod -Uri "$Api/repos/$Full/actions/runs/$runId/jobs" -Headers $Hdr -Method Get
    foreach ($j in $jobs.jobs) {
      Write-Host "--- job: $($j.name) [$($j.conclusion)] ---" -ForegroundColor Yellow
      foreach ($s in $j.steps) { Write-Host ("    " + $s.number + ". " + $s.name + " -> " + $s.conclusion) }
    }
    $logs = Invoke-RestMethod -Uri "$Api/repos/$Full/actions/runs/$runId/logs" -Headers $Hdr -Method Get -MaximumRedirection 5
  } catch { Write-Host "（日志拉取失败：$($_.Exception.Message)）" }
  Write-Host "详细日志：$($cur.html_url)"
  throw "构建失败，见上方日志与链接"
}

# ---------- 5. 下载产物 ----------
Say "构建成功，下载 artifact"
$arts = Invoke-RestMethod -Uri "$Api/repos/$Full/actions/runs/$runId/artifacts" -Headers $Hdr -Method Get
$ipa  = $arts.artifacts | Where-Object { $_.name -like "*ipa*" } | Select-Object -First 1
if (-not $ipa) { throw "没有找到 ipa artifact" }

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }
$zipPath = Join-Path $OutDir "SparkKeeper-unsigned-ipa.zip"

# artifact 下载：GitHub 会 302 到对象存储的签名 URL。
# Invoke-WebRequest 跟随重定向时会丢掉 Authorization 头 → 401 Requires authentication。
# Net.WebClient 会自动跟随重定向并保留请求头，这是实测唯一稳的路子。
$wc = New-Object System.Net.WebClient
$wc.Headers.Add("Authorization", "token $Token")
$wc.Headers.Add("User-Agent", "SparkKeeper-Push")
$wc.Headers.Add("Accept", "application/vnd.github+json")
try {
  $wc.DownloadFile($ipa.archive_download_url, $zipPath)
} finally {
  $wc.Dispose()
}
Say "已下载：$zipPath（$([math]::Round((Get-Item $zipPath).Length/1MB,2)) MB）"

Expand-Archive -Path $zipPath -DestinationPath $OutDir -Force
$real = Get-ChildItem $OutDir -Recurse -Filter *.ipa | Select-Object -First 1
if ($real) {
  Say "IPA 就位：$($real.FullName)（$([math]::Round($real.Length/1MB,2)) MB）"
  Write-Host ""
  Write-Host "下一步签名安装：用 Sideloadly / AltStore / TrollStore 装机，详见 README.md" -ForegroundColor Green
} else {
  Say "解压后没看到 .ipa，请手动检查 $OutDir"
}
