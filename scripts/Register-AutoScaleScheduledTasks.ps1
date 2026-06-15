[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$TaskUser,

    [Parameter(Mandatory)]
    [string]$TaskPassword,

    [string]$TaskPath = '\VM CPU AutoScale\',

    [int]$ScaleUpMinutesInterval = 10,

    [int]$ScaleDownWeeksInterval = 1,

    [ValidateSet('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday')]
    [string]$ScaleDownDay = 'Sunday',

    [string]$ScaleDownTime = '08:00',

    [switch]$RegisterScaleUp,

    [switch]$RegisterScaleDown
)

$ErrorActionPreference = 'Stop'

$projectRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$powerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$taskPrincipal = New-ScheduledTaskPrincipal -UserId $TaskUser -LogonType Password -RunLevel Highest
$taskSettings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours 6) `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries

if (-not $RegisterScaleUp -and -not $RegisterScaleDown) {
    $RegisterScaleUp = $true
    $RegisterScaleDown = $true
}

if ($RegisterScaleUp) {
    $scaleUpScript = Join-Path $projectRoot 'scripts\CpuScaleUp-Poller.ps1'
    $scaleUpAction = New-ScheduledTaskAction `
        -Execute $powerShellExe `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scaleUpScript`" -Execute" `
        -WorkingDirectory $projectRoot

    $scaleUpTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddMinutes(1)
    $scaleUpTrigger.Repetition.Interval = "PT$($ScaleUpMinutesInterval)M"
    $scaleUpTrigger.Repetition.Duration = 'P3650D'

    Register-ScheduledTask `
        -TaskName 'VM CPU AutoScale - Scale Up Poller' `
        -TaskPath $TaskPath `
        -Action $scaleUpAction `
        -Trigger $scaleUpTrigger `
        -Principal $taskPrincipal `
        -Settings $taskSettings `
        -User $TaskUser `
        -Password $TaskPassword `
        -Force | Out-Null
}

if ($RegisterScaleDown) {
    $scaleDownScript = Join-Path $projectRoot 'scripts\CpuScaleDown-Worker.ps1'
    $scaleDownAction = New-ScheduledTaskAction `
        -Execute $powerShellExe `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scaleDownScript`" -Execute" `
        -WorkingDirectory $projectRoot

    $scaleDownTrigger = New-ScheduledTaskTrigger `
        -Weekly `
        -WeeksInterval $ScaleDownWeeksInterval `
        -DaysOfWeek $ScaleDownDay `
        -At $ScaleDownTime

    Register-ScheduledTask `
        -TaskName 'VM CPU AutoScale - Scale Down Worker' `
        -TaskPath $TaskPath `
        -Action $scaleDownAction `
        -Trigger $scaleDownTrigger `
        -Principal $taskPrincipal `
        -Settings $taskSettings `
        -User $TaskUser `
        -Password $TaskPassword `
        -Force | Out-Null
}

Get-ScheduledTask -TaskPath $TaskPath |
    Where-Object { $_.TaskName -like 'VM CPU AutoScale*' } |
    Select-Object TaskPath, TaskName, State
