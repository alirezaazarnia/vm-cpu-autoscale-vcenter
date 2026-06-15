[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\autoscale.config.psd1'),

    [switch]$Execute,

    [switch]$IgnoreMaintenanceWindow
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'AutoScale.Common.psm1') -Force

if (-not (Get-Module -ListAvailable -Name VMware.VimAutomation.Core)) {
    throw 'VMware.VimAutomation.Core module is not installed or not available in this PowerShell session.'
}

Import-Module VMware.VimAutomation.Core -ErrorAction Stop
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null

function Add-ScaleEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConnectionString,

        [long]$ScaleGroupId,
        [string]$vCenterName,
        [string]$VMName,
        [Parameter(Mandatory)]
        [string]$EventType,
        $OldCPU,
        $NewCPU,
        [Parameter(Mandatory)]
        [string]$Status,
        [string]$Message,
        [string]$ErrorDetails
    )

    Invoke-AutoScaleSqlNonQuery -ConnectionString $ConnectionString -Query @'
INSERT INTO dbo.ScaleEvents
(
    ScaleGroupId,
    vCenterName,
    VMName,
    EventType,
    OldCPU,
    NewCPU,
    Status,
    Message,
    ErrorDetails
)
VALUES
(
    @ScaleGroupId,
    @vCenterName,
    @VMName,
    @EventType,
    @OldCPU,
    @NewCPU,
    @Status,
    @Message,
    @ErrorDetails
);
'@ -Parameters @{
        ScaleGroupId = if ($ScaleGroupId -gt 0) { $ScaleGroupId } else { $null }
        vCenterName  = $vCenterName
        VMName       = $VMName
        EventType    = $EventType
        OldCPU       = $OldCPU
        NewCPU       = $NewCPU
        Status       = $Status
        Message      = $Message
        ErrorDetails = $ErrorDetails
    }
}

function Test-MaintenanceWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Settings
    )

    $scaleDownDay = [string]$Settings['ScaleDownDay']
    $scaleDownTime = [string]$Settings['ScaleDownTime']
    $now = Get-Date

    if ($now.DayOfWeek.ToString() -ne $scaleDownDay) {
        return $false
    }

    $targetTime = [TimeSpan]::Parse($scaleDownTime)
    $windowStart = $now.Date.Add($targetTime)
    $windowEnd = $windowStart.AddHours(4)

    $now -ge $windowStart -and $now -lt $windowEnd
}

function Get-ActiveScaleGroups {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConnectionString
    )

    Invoke-AutoScaleSqlQuery -ConnectionString $ConnectionString -Query @'
SELECT
    Id,
    vCenterName,
    VMName,
    OriginalCPU,
    CurrentCPU,
    MaxCPU,
    OriginalPowerState,
    FirstScaleUpTime,
    LastScaleUpTime,
    Status
FROM dbo.ScaleGroups
WHERE Status = N'Active'
ORDER BY FirstScaleUpTime, Id;
'@
}

function Get-VCenterServerName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConnectionString,

        [Parameter(Mandatory)]
        [string]$vCenterName
    )

    $table = Invoke-AutoScaleSqlQuery -ConnectionString $ConnectionString -Query @'
SELECT TOP (1) Server
FROM dbo.vCenters
WHERE Name = @vCenterName
AND Enabled = 1;
'@ -Parameters @{
        vCenterName = $vCenterName
    }

    if ($table.Rows.Count -eq 0) {
        return $null
    }

    [string]$table.Rows[0].Server
}

function Set-ScaleGroupStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConnectionString,

        [Parameter(Mandatory)]
        [long]$ScaleGroupId,

        [Parameter(Mandatory)]
        [string]$Status
    )

    Invoke-AutoScaleSqlNonQuery -ConnectionString $ConnectionString -Query @'
UPDATE dbo.ScaleGroups
SET Status = @Status,
    ScaleDownTime = CASE WHEN @Status = N'Reverted' THEN sysdatetime() ELSE ScaleDownTime END,
    UpdatedAt = sysdatetime()
WHERE Id = @ScaleGroupId;
'@ -Parameters @{
        ScaleGroupId = $ScaleGroupId
        Status       = $Status
    }
}

function Invoke-ScaleDown {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $VM,

        [Parameter(Mandatory)]
        [int]$TargetCPU,

        [Parameter(Mandatory)]
        [switch]$Execute
    )

    $originalPowerState = [string]$VM.PowerState

    if (-not $Execute) {
        return $originalPowerState
    }

    if ($VM.PowerState -eq 'PoweredOn') {
        Shutdown-VMGuest -VM $VM -Confirm:$false | Out-Null

        $deadline = (Get-Date).AddMinutes(5)
        do {
            Start-Sleep -Seconds 10
            $VM = Get-VM -Id $VM.Id
        } while ($VM.PowerState -ne 'PoweredOff' -and (Get-Date) -lt $deadline)

        if ($VM.PowerState -ne 'PoweredOff') {
            Stop-VM -VM $VM -Confirm:$false | Out-Null
            $VM = Get-VM -Id $VM.Id
        }
    }

    Set-VM -VM $VM -NumCpu $TargetCPU -Confirm:$false | Out-Null

    $VM = Get-VM -Id $VM.Id
    if ($originalPowerState -eq 'PoweredOn' -and $VM.PowerState -ne 'PoweredOn') {
        Start-VM -VM $VM -Confirm:$false | Out-Null
    }

    $originalPowerState
}

$config = Import-AutoScaleConfig -Path $ConfigPath
$connectionString = New-AutoScaleSqlConnectionString -Config $config
$settings = Get-AutoScaleSettings -ConnectionString $connectionString
$runId = [guid]::NewGuid()
$mode = if ($Execute) { 'Execute' } else { 'DryRun' }
$vCenterCredential = ConvertTo-AutoScaleCredential -Username $config.vCenter.Username -Password $config.vCenter.Password
$successCount = 0
$failureCount = 0
$skipCount = 0

Write-AutoScaleLog -ConnectionString $connectionString -RunId $runId -Level Info -Step 'ScaleDownStart' -Message "Scale-down worker started. Mode=$mode"

if (-not $IgnoreMaintenanceWindow -and -not (Test-MaintenanceWindow -Settings $settings)) {
    $message = 'Scale-down skipped because the current time is outside the configured maintenance window.'
    Write-AutoScaleLog -ConnectionString $connectionString -RunId $runId -Level Warning -Step 'OutsideMaintenanceWindow' -Message $message
    [pscustomobject]@{
        RunId = $runId
        Mode  = $mode
        Status = 'SkippedOutsideMaintenanceWindow'
    }
    return
}

$groups = Get-ActiveScaleGroups -ConnectionString $connectionString

foreach ($group in $groups.Rows) {
    $scaleGroupId = [long]$group.Id
    $vCenterName = [string]$group.vCenterName
    $vmName = [string]$group.VMName
    $originalCpu = [int]$group.OriginalCPU
    $currentCpu = [int]$group.CurrentCPU
    $serverConnection = $null

    try {
        $vCenterServer = Get-VCenterServerName -ConnectionString $connectionString -vCenterName $vCenterName
        if ([string]::IsNullOrWhiteSpace($vCenterServer)) {
            throw "Enabled vCenter was not found in SQL Server. vCenterName=$vCenterName"
        }

        Write-AutoScaleLog -ConnectionString $connectionString -RunId $runId -Level Info -Step 'ConnectVCenter' -vCenterName $vCenterName -VMName $vmName -Message "Connecting to vCenter $vCenterServer."
        $serverConnection = Connect-VIServer -Server $vCenterServer -Credential $vCenterCredential -ErrorAction Stop

        $vm = Get-VM -Name $vmName -ErrorAction Stop
        $actualCpu = [int]$vm.NumCpu
        $message = "Scale-down selected. Mode=$mode; CurrentCPU=$actualCpu; TargetCPU=$originalCpu"
        Write-AutoScaleLog -ConnectionString $connectionString -RunId $runId -Level Info -Step 'ScaleDownSelected' -vCenterName $vCenterName -VMName $vmName -Message $message

        [void](Invoke-ScaleDown -VM $vm -TargetCPU $originalCpu -Execute:$Execute)

        if ($Execute) {
            Set-ScaleGroupStatus -ConnectionString $connectionString -ScaleGroupId $scaleGroupId -Status 'Reverted'
            Add-ScaleEvent -ConnectionString $connectionString -ScaleGroupId $scaleGroupId -vCenterName $vCenterName -VMName $vmName -EventType 'ScaleDown' -OldCPU $actualCpu -NewCPU $originalCpu -Status 'Succeeded' -Message $message
        }
        else {
            Add-ScaleEvent -ConnectionString $connectionString -ScaleGroupId $scaleGroupId -vCenterName $vCenterName -VMName $vmName -EventType 'ScaleDown' -OldCPU $actualCpu -NewCPU $originalCpu -Status 'Skipped' -Message "DryRun only. $message"
        }

        $successCount++
    }
    catch {
        $failureCount++
        $details = @"
$($_)
Script: $($_.InvocationInfo.ScriptName)
Line: $($_.InvocationInfo.ScriptLineNumber)
Command: $($_.InvocationInfo.Line)
"@
        $message = "Scale-down failed. PreviousKnownCPU=$currentCpu; TargetCPU=$originalCpu"
        Write-AutoScaleLog -ConnectionString $connectionString -RunId $runId -Level Error -Step 'ScaleDownFailed' -vCenterName $vCenterName -VMName $vmName -Message $message -Details $details
        Add-ScaleEvent -ConnectionString $connectionString -ScaleGroupId $scaleGroupId -vCenterName $vCenterName -VMName $vmName -EventType 'Error' -OldCPU $currentCpu -NewCPU $originalCpu -Status 'Failed' -Message $message -ErrorDetails $details

        if ($Execute) {
            Set-ScaleGroupStatus -ConnectionString $connectionString -ScaleGroupId $scaleGroupId -Status 'ManualReviewRequired'
        }

        Send-AutoScaleEmail `
            -ConnectionString $connectionString `
            -RunId $runId `
            -Settings $settings `
            -vCenterName $vCenterName `
            -VMName $vmName `
            -Subject "VM CPU AutoScale scale-down failed: $vmName" `
            -Body "$message`r`n`r`n$details"
    }
    finally {
        if ($null -ne $serverConnection) {
            Disconnect-VIServer -Server $serverConnection -Confirm:$false | Out-Null
        }
    }
}

$summary = "Scale-down worker completed. Mode=$mode; Success=$successCount; Failed=$failureCount; Skipped=$skipCount"
Write-AutoScaleLog -ConnectionString $connectionString -RunId $runId -Level Info -Step 'ScaleDownEnd' -Message $summary

Send-AutoScaleEmail `
    -ConnectionString $connectionString `
    -RunId $runId `
    -Settings $settings `
    -Subject 'VM CPU AutoScale scale-down summary' `
    -Body $summary

[pscustomobject]@{
    RunId   = $runId
    Mode    = $mode
    Success = $successCount
    Failed  = $failureCount
    Skipped = $skipCount
}
