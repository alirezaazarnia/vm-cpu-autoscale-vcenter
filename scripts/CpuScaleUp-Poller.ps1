[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\autoscale.config.psd1'),

    [switch]$Execute
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
        $AlertTime,

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
    AlertTime,
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
    @AlertTime,
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
        AlertTime    = $AlertTime
        Status       = $Status
        Message      = $Message
        ErrorDetails = $ErrorDetails
    }
}

function Get-ActiveScaleGroup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConnectionString,

        [Parameter(Mandatory)]
        [string]$vCenterName,

        [Parameter(Mandatory)]
        [string]$VMName
    )

    $table = Invoke-AutoScaleSqlQuery -ConnectionString $ConnectionString -Query @'
SELECT TOP (1)
    Id,
    OriginalCPU,
    CurrentCPU,
    MaxCPU,
    OriginalPowerState,
    FirstScaleUpTime,
    LastScaleUpTime,
    Status
FROM dbo.ScaleGroups
WHERE vCenterName = @vCenterName
AND VMName = @VMName
AND Status = N'Active'
ORDER BY Id DESC;
'@ -Parameters @{
        vCenterName = $vCenterName
        VMName      = $VMName
    }

    if ($table.Rows.Count -eq 0) {
        return $null
    }

    $table.Rows[0]
}

function Get-EnabledAllowedVMs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConnectionString,

        [Parameter(Mandatory)]
        [string]$vCenterName
    )

    Invoke-AutoScaleSqlQuery -ConnectionString $ConnectionString -Query @'
SELECT
    Id,
    vCenterName,
    VMName,
    Enabled,
    MaxCPU,
    AllowScaleDownPowerOff
FROM dbo.AllowedVMs
WHERE vCenterName = @vCenterName
AND Enabled = 1
ORDER BY VMName;
'@ -Parameters @{
        vCenterName = $vCenterName
    }
}

function Save-ScaleUpSuccess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConnectionString,

        [long]$ScaleGroupId,

        [Parameter(Mandatory)]
        [string]$vCenterName,

        [Parameter(Mandatory)]
        [string]$VMName,

        [Parameter(Mandatory)]
        [int]$OriginalCPU,

        [Parameter(Mandatory)]
        [int]$OldCPU,

        [Parameter(Mandatory)]
        [int]$NewCPU,

        [Parameter(Mandatory)]
        [int]$MaxCPU,

        [string]$OriginalPowerState,
        [Nullable[datetime]]$AlertTime,
        [string]$Message
    )

    if ($ScaleGroupId -gt 0) {
        Invoke-AutoScaleSqlNonQuery -ConnectionString $ConnectionString -Query @'
UPDATE dbo.ScaleGroups
SET CurrentCPU = @NewCPU,
    LastScaleUpTime = sysdatetime(),
    UpdatedAt = sysdatetime()
WHERE Id = @ScaleGroupId;
'@ -Parameters @{
            ScaleGroupId = $ScaleGroupId
            NewCPU       = $NewCPU
        }
    }
    else {
        Invoke-AutoScaleSqlNonQuery -ConnectionString $ConnectionString -Query @'
INSERT INTO dbo.ScaleGroups
(
    vCenterName,
    VMName,
    OriginalCPU,
    CurrentCPU,
    MaxCPU,
    OriginalPowerState,
    FirstScaleUpTime,
    LastScaleUpTime,
    Status
)
VALUES
(
    @vCenterName,
    @VMName,
    @OriginalCPU,
    @NewCPU,
    @MaxCPU,
    @OriginalPowerState,
    sysdatetime(),
    sysdatetime(),
    N'Active'
);
'@ -Parameters @{
            vCenterName        = $vCenterName
            VMName             = $VMName
            OriginalCPU        = $OriginalCPU
            NewCPU             = $NewCPU
            MaxCPU             = $MaxCPU
            OriginalPowerState = $OriginalPowerState
        }

        $created = Get-ActiveScaleGroup -ConnectionString $ConnectionString -vCenterName $vCenterName -VMName $VMName
        $ScaleGroupId = [long]$created.Id
    }

    Add-ScaleEvent `
        -ConnectionString $ConnectionString `
        -ScaleGroupId $ScaleGroupId `
        -vCenterName $vCenterName `
        -VMName $VMName `
        -EventType 'ScaleUp' `
        -OldCPU $OldCPU `
        -NewCPU $NewCPU `
        -AlertTime $AlertTime `
        -Status 'Succeeded' `
        -Message $Message
}

function Get-TriggeredCpuAlarm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $VMView,

        [Parameter(Mandatory)]
        [string]$AlarmName
    )

    if ($null -eq $VMView.TriggeredAlarmState -or $VMView.TriggeredAlarmState.Count -eq 0) {
        return $null
    }

    foreach ($alarmState in $VMView.TriggeredAlarmState) {
        if ($null -eq $alarmState -or $null -eq $alarmState.OverallStatus -or $null -eq $alarmState.Alarm) {
            continue
        }

        $overallStatus = [string]$alarmState.OverallStatus
        if ($overallStatus -notin @('yellow', 'red')) {
            continue
        }

        $alarmView = Get-View -Id $alarmState.Alarm -ErrorAction Stop
        if ($null -eq $alarmView -or $null -eq $alarmView.Info -or [string]::IsNullOrWhiteSpace($alarmView.Info.Name)) {
            continue
        }

        if ($alarmView.Info.Name -eq $AlarmName) {
            return [pscustomobject]@{
                Name   = $alarmView.Info.Name
                Status = $overallStatus
                Time   = $alarmState.Time
            }
        }
    }

    $null
}

function Invoke-ScaleUp {
    [CmdletBinding()]
    param(
        $VM,

        [Parameter(Mandatory)]
        $VMView,

        [Parameter(Mandatory)]
        [int]$NewCPU,

        [Parameter(Mandatory)]
        [switch]$Execute
    )

    if (-not $Execute) {
        return
    }

    $powerState = [string]$VM.PowerState
    $wasPoweredOn = $powerState -eq 'PoweredOn'
    $hotAddEnabled = [bool]$VMView.Config.CpuHotAddEnabled

    if ($wasPoweredOn -and -not $hotAddEnabled) {
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

    Set-VM -VM $VM -NumCpu $NewCPU -Confirm:$false | Out-Null

    $VM = Get-VM -Id $VM.Id
    if ($wasPoweredOn -and $VM.PowerState -ne 'PoweredOn') {
        Start-VM -VM $VM -Confirm:$false | Out-Null
    }
}

$config = Import-AutoScaleConfig -Path $ConfigPath
$connectionString = New-AutoScaleSqlConnectionString -Config $config
$settings = Get-AutoScaleSettings -ConnectionString $connectionString
$vCenters = Get-AutoScaleEnabledVCenters -ConnectionString $connectionString
$runId = [guid]::NewGuid()
$mode = if ($Execute) { 'Execute' } else { 'DryRun' }
$alarmName = [string]$settings['CpuAlarmName']
$cooldownMinutes = [int]$settings['ScaleUpCooldownMinutes']
$defaultMaxCpu = [int]$settings['DefaultMaxCPU']
$vCenterCredential = ConvertTo-AutoScaleCredential -Username $config.vCenter.Username -Password $config.vCenter.Password

Write-AutoScaleLog -ConnectionString $connectionString -RunId $runId -Level Info -Step 'PollerStart' -Message "Scale-up poller started. Mode=$mode"

foreach ($vCenter in $vCenters.Rows) {
    $serverConnection = $null
    $vCenterName = [string]$vCenter.Name
    $vCenterServer = [string]$vCenter.Server

    try {
        Write-AutoScaleLog -ConnectionString $connectionString -RunId $runId -Level Info -Step 'ConnectVCenter' -vCenterName $vCenterName -Message "Connecting to vCenter $vCenterServer."
        $serverConnection = Connect-VIServer -Server $vCenterServer -Credential $vCenterCredential -ErrorAction Stop

        $allowedVMs = Get-EnabledAllowedVMs -ConnectionString $connectionString -vCenterName $vCenterName
        Write-AutoScaleLog -ConnectionString $connectionString -RunId $runId -Level Info -Step 'AllowedVMsLoaded' -vCenterName $vCenterName -Message "Loaded enabled allowed VMs. Count=$($allowedVMs.Rows.Count)"

        foreach ($allowedVm in $allowedVMs.Rows) {
            $vmName = [string]$allowedVm.VMName
            $vmMatches = @(Get-View -ViewType VirtualMachine -Property Name,Config.Hardware.NumCPU,Config.CpuHotAddEnabled,Runtime.PowerState,TriggeredAlarmState -Filter @{ Name = "^$([regex]::Escape($vmName))$" })

            if ($vmMatches.Count -eq 0) {
                $message = 'Allowed VM was not found in vCenter.'
                Write-AutoScaleLog -ConnectionString $connectionString -RunId $runId -Level Warning -Step 'AllowedVMNotFound' -vCenterName $vCenterName -VMName $vmName -Message $message
                Add-ScaleEvent -ConnectionString $connectionString -vCenterName $vCenterName -VMName $vmName -EventType 'Skip' -Status 'Skipped' -Message $message
                continue
            }

            if ($vmMatches.Count -gt 1) {
                $message = "Allowed VM name matched multiple vCenter VMs. Count=$($vmMatches.Count)"
                Write-AutoScaleLog -ConnectionString $connectionString -RunId $runId -Level Error -Step 'AllowedVMAmbiguous' -vCenterName $vCenterName -VMName $vmName -Message $message
                Add-ScaleEvent -ConnectionString $connectionString -vCenterName $vCenterName -VMName $vmName -EventType 'Error' -Status 'PendingManualReview' -Message $message
                continue
            }

            $vmView = $vmMatches[0]
            $triggeredAlarm = Get-TriggeredCpuAlarm -VMView $vmView -AlarmName $alarmName
            if ($null -eq $triggeredAlarm) {
                Write-AutoScaleLog -ConnectionString $connectionString -RunId $runId -Level Info -Step 'NoCpuAlarm' -vCenterName $vCenterName -VMName $vmName -Message "No matching active CPU alarm found. AlarmName=$alarmName"
                continue
            }

            $alertTime = if ($null -ne $triggeredAlarm.Time) { [datetime]$triggeredAlarm.Time } else { $null }

            if ($null -eq $vmView.Config -or $null -eq $vmView.Config.Hardware -or $null -eq $vmView.Config.Hardware.NumCPU) {
                $message = 'VM skipped because CPU configuration was not available from vCenter.'
                Write-AutoScaleLog -ConnectionString $connectionString -RunId $runId -Level Warning -Step 'SkipMissingCpuConfig' -vCenterName $vCenterName -VMName $vmName -Message $message
                Add-ScaleEvent -ConnectionString $connectionString -vCenterName $vCenterName -VMName $vmName -EventType 'Skip' -AlertTime $alertTime -Status 'Skipped' -Message $message
                continue
            }

            $currentCpu = [int]$vmView.Config.Hardware.NumCPU
            $maxCpu = if ([int]$allowedVm.MaxCPU -gt 0) { [int]$allowedVm.MaxCPU } else { $defaultMaxCpu }
            $newCpu = [Math]::Min(($currentCpu * 2), $maxCpu)

            if ($currentCpu -ge $maxCpu -or $newCpu -eq $currentCpu) {
                $message = "VM skipped because current CPU is already at max. CurrentCPU=$currentCpu; MaxCPU=$maxCpu"
                Write-AutoScaleLog -ConnectionString $connectionString -RunId $runId -Level Info -Step 'SkipMaxCPU' -vCenterName $vCenterName -VMName $vmName -Message $message
                Add-ScaleEvent -ConnectionString $connectionString -vCenterName $vCenterName -VMName $vmName -EventType 'Skip' -OldCPU $currentCpu -NewCPU $currentCpu -AlertTime $alertTime -Status 'Skipped' -Message $message
                continue
            }

            $activeGroup = Get-ActiveScaleGroup -ConnectionString $connectionString -vCenterName $vCenterName -VMName $vmName
            $scaleGroupId = 0
            $originalCpu = $currentCpu

            if ($null -ne $activeGroup) {
                $scaleGroupId = [long]$activeGroup.Id
                $originalCpu = [int]$activeGroup.OriginalCPU
                if ($null -eq $activeGroup.LastScaleUpTime -or $activeGroup.LastScaleUpTime -is [System.DBNull]) {
                    $message = 'VM skipped because active scale group has no LastScaleUpTime.'
                    Write-AutoScaleLog -ConnectionString $connectionString -RunId $runId -Level Error -Step 'SkipInvalidScaleGroup' -vCenterName $vCenterName -VMName $vmName -Message $message
                    Add-ScaleEvent -ConnectionString $connectionString -ScaleGroupId $scaleGroupId -vCenterName $vCenterName -VMName $vmName -EventType 'Error' -OldCPU $currentCpu -NewCPU $newCpu -AlertTime $alertTime -Status 'PendingManualReview' -Message $message
                    continue
                }

                $lastScaleUp = [datetime]$activeGroup.LastScaleUpTime
                $nextAllowedScaleUp = $lastScaleUp.AddMinutes($cooldownMinutes)

                if ((Get-Date) -lt $nextAllowedScaleUp) {
                    $message = "VM skipped because it is inside cooldown. LastScaleUp=$lastScaleUp; NextAllowed=$nextAllowedScaleUp"
                    Write-AutoScaleLog -ConnectionString $connectionString -RunId $runId -Level Info -Step 'SkipCooldown' -vCenterName $vCenterName -VMName $vmName -Message $message
                    Add-ScaleEvent -ConnectionString $connectionString -ScaleGroupId $scaleGroupId -vCenterName $vCenterName -VMName $vmName -EventType 'Skip' -OldCPU $currentCpu -NewCPU $newCpu -AlertTime $alertTime -Status 'Skipped' -Message $message
                    continue
                }
            }

            $vm = $null
            $originalPowerState = if ($null -ne $vmView.Runtime -and $null -ne $vmView.Runtime.PowerState) { [string]$vmView.Runtime.PowerState } else { 'Unknown' }
            $message = "Scale-up selected. Mode=$mode; CurrentCPU=$currentCpu; NewCPU=$newCpu; MaxCPU=$maxCpu; HotAdd=$($vmView.Config.CpuHotAddEnabled)"

            Write-AutoScaleLog -ConnectionString $connectionString -RunId $runId -Level Info -Step 'ScaleUpSelected' -vCenterName $vCenterName -VMName $vmName -Message $message

            try {
                if ($Execute) {
                    $vm = Get-VIObjectByVIView -VIView $vmView -ErrorAction Stop
                    if ($null -eq $vm) {
                        throw "Could not resolve VM object from vCenter view for VM '$vmName'."
                    }
                }

                Invoke-ScaleUp -VM $vm -VMView $vmView -NewCPU $newCpu -Execute:$Execute

                if ($Execute) {
                    Save-ScaleUpSuccess `
                        -ConnectionString $connectionString `
                        -ScaleGroupId $scaleGroupId `
                        -vCenterName $vCenterName `
                        -VMName $vmName `
                        -OriginalCPU $originalCpu `
                        -OldCPU $currentCpu `
                        -NewCPU $newCpu `
                        -MaxCPU $maxCpu `
                        -OriginalPowerState $originalPowerState `
                        -AlertTime $alertTime `
                        -Message $message
                }
                else {
                    Add-ScaleEvent -ConnectionString $connectionString -ScaleGroupId $scaleGroupId -vCenterName $vCenterName -VMName $vmName -EventType 'ScaleUp' -OldCPU $currentCpu -NewCPU $newCpu -AlertTime $alertTime -Status 'Skipped' -Message "DryRun only. $message"
                }
            }
            catch {
                $errorMessage = "Scale-up failed. CurrentCPU=$currentCpu; TargetCPU=$newCpu"
                Write-AutoScaleLog -ConnectionString $connectionString -RunId $runId -Level Error -Step 'ScaleUpFailed' -vCenterName $vCenterName -VMName $vmName -Message $errorMessage -Details ([string]$_)
                Add-ScaleEvent -ConnectionString $connectionString -ScaleGroupId $scaleGroupId -vCenterName $vCenterName -VMName $vmName -EventType 'Error' -OldCPU $currentCpu -NewCPU $newCpu -AlertTime $alertTime -Status 'Failed' -Message $errorMessage -ErrorDetails ([string]$_)

                try {
                    if ($null -ne $vm -and $originalPowerState -eq 'PoweredOn') {
                        $currentVm = Get-VM -Id $vm.Id -ErrorAction Stop
                        if ($currentVm.PowerState -ne 'PoweredOn') {
                            Start-VM -VM $currentVm -Confirm:$false | Out-Null
                            Write-AutoScaleLog -ConnectionString $connectionString -RunId $runId -Level Warning -Step 'ScaleUpRecovery' -vCenterName $vCenterName -VMName $vmName -Message 'VM was powered on after scale-up failure.'
                        }
                    }
                }
                catch {
                    Write-AutoScaleLog -ConnectionString $connectionString -RunId $runId -Level Error -Step 'ScaleUpRecoveryFailed' -vCenterName $vCenterName -VMName $vmName -Message 'Recovery after scale-up failure failed.' -Details ([string]$_)
                }
            }
        }
    }
    catch {
        $details = @"
$($_)
Script: $($_.InvocationInfo.ScriptName)
Line: $($_.InvocationInfo.ScriptLineNumber)
Command: $($_.InvocationInfo.Line)
"@
        Write-AutoScaleLog -ConnectionString $connectionString -RunId $runId -Level Error -Step 'vCenterFailed' -vCenterName $vCenterName -Message "vCenter processing failed: $vCenterServer" -Details $details
        Add-ScaleEvent -ConnectionString $connectionString -vCenterName $vCenterName -EventType 'Error' -Status 'Failed' -Message "vCenter processing failed: $vCenterServer" -ErrorDetails $details
    }
    finally {
        if ($null -ne $serverConnection) {
            Disconnect-VIServer -Server $serverConnection -Confirm:$false | Out-Null
        }
    }
}

Write-AutoScaleLog -ConnectionString $connectionString -RunId $runId -Level Info -Step 'PollerEnd' -Message "Scale-up poller completed. Mode=$mode"

[pscustomobject]@{
    RunId = $runId
    Mode  = $mode
}
