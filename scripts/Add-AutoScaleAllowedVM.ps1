[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$vCenterName,

    [Parameter(Mandatory)]
    [string]$VMName,

    [int]$MaxCPU = 16,

    [bool]$Enabled = $true,

    [bool]$AllowScaleDownPowerOff = $true,

    [string]$Notes,

    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\autoscale.config.psd1')
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'AutoScale.Common.psm1') -Force

$config = Import-AutoScaleConfig -Path $ConfigPath
$connectionString = New-AutoScaleSqlConnectionString -Config $config

Invoke-AutoScaleSqlNonQuery -ConnectionString $connectionString -Query @'
MERGE dbo.AllowedVMs AS target
USING
(
    SELECT
        @vCenterName AS vCenterName,
        @VMName AS VMName,
        @Enabled AS Enabled,
        @MaxCPU AS MaxCPU,
        @AllowScaleDownPowerOff AS AllowScaleDownPowerOff,
        @Notes AS Notes
) AS source
ON target.vCenterName = source.vCenterName
AND target.VMName = source.VMName
WHEN MATCHED THEN
    UPDATE SET
        Enabled = source.Enabled,
        MaxCPU = source.MaxCPU,
        AllowScaleDownPowerOff = source.AllowScaleDownPowerOff,
        Notes = source.Notes,
        UpdatedAt = sysdatetime()
WHEN NOT MATCHED THEN
    INSERT (vCenterName, VMName, Enabled, MaxCPU, AllowScaleDownPowerOff, Notes)
    VALUES (source.vCenterName, source.VMName, source.Enabled, source.MaxCPU, source.AllowScaleDownPowerOff, source.Notes);
'@ -Parameters @{
    vCenterName             = $vCenterName
    VMName                  = $VMName
    Enabled                 = [int]$Enabled
    MaxCPU                  = $MaxCPU
    AllowScaleDownPowerOff  = [int]$AllowScaleDownPowerOff
    Notes                   = $Notes
}

Write-Host "Allowed VM saved: $vCenterName / $VMName"
