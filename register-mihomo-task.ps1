<#
.SYNOPSIS
注册 Windows 计划任务：每周在 WSL 中运行 auto-update-mihomo.sh。

.DESCRIPTION
把「每周自动检测 mihomo 新版本 → 编译 → 校验 → 部署到路由器」交给 Windows 计划任务，
不依赖 WSL 是否开机常驻。任务以当前用户身份注册，默认「错过后尽快补跑」、超时 6 小时。

.PARAMETER ScriptPath
auto-update-mihomo.sh 的位置。Windows 路径（F:\mihomo\auto-update-mihomo.sh）或
WSL 路径（/mnt/f/mihomo/auto-update-mihomo.sh）都可以，脚本会自动转换。

.PARAMETER Distro
WSL 发行版名，用 `wsl -l -q` 查看。

.EXAMPLE
.\register-mihomo-task.ps1 -ScriptPath F:\mihomo\auto-update-mihomo.sh -Distro Debian

.EXAMPLE
.\register-mihomo-task.ps1 -ScriptPath /mnt/f/mihomo/auto-update-mihomo.sh -At 4:30AM
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ScriptPath,

    [string]$Distro = 'Debian',

    [string]$TaskName = 'Mihomo Weekly Auto Update',

    [ValidateSet('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday')]
    [string]$DayOfWeek = 'Sunday',

    [string]$At = '3:00AM'
)

$ErrorActionPreference = 'Stop'

$Wsl = Join-Path $env:WINDIR 'System32\wsl.exe'
if (-not (Test-Path $Wsl)) { throw "找不到 wsl.exe：$Wsl（本脚本需要在 Windows 下运行）" }

# 统一转成 WSL 内的绝对路径
if ($ScriptPath -match '^/') {
    $WslScriptPath = $ScriptPath
} else {
    if (-not (Test-Path -LiteralPath $ScriptPath)) { throw "找不到脚本文件：$ScriptPath" }
    $WslScriptPath = (& $Wsl -d $Distro -- wslpath -a $ScriptPath).Trim()
    if (-not $WslScriptPath) { throw "wslpath 转换失败：$ScriptPath" }
}
Write-Output "WSL 内脚本路径：$WslScriptPath"

# 注册前先做一次存在性检查，避免注册一个注定失败的任务
& $Wsl -d $Distro -- test -f $WslScriptPath
if ($LASTEXITCODE -ne 0) { throw "在 WSL($Distro) 中找不到该文件：$WslScriptPath" }

# ⚠️ 必须是 bash -lc：sh -c 不会读登录环境，PATH 里可能没有 go/git
$Argument = '-d ' + $Distro + ' -- bash -lc "' + $WslScriptPath + '"'
$Action    = New-ScheduledTaskAction -Execute $Wsl -Argument $Argument
$Trigger   = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $DayOfWeek -At $At
$Settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 6)

Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger `
    -Settings $Settings -Force `
    -Description 'Weekly mihomo kernel update: check upstream tag, build with traditional GC, verify artifact, deploy to router.' | Out-Null

Write-Output "Registered: $TaskName (weekly $DayOfWeek $At, WSL distro: $Distro)"
