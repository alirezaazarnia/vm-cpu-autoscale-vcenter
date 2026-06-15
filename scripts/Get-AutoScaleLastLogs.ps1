[CmdletBinding()]
param(
    [int]$Top = 50,

    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\autoscale.config.psd1')
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'AutoScale.Common.psm1') -Force

$config = Import-AutoScaleConfig -Path $ConfigPath
$connectionString = New-AutoScaleSqlConnectionString -Config $config

Invoke-AutoScaleSqlQuery -ConnectionString $connectionString -Query @'
SELECT TOP (@Top)
    Id,
    RunId,
    vCenterName,
    VMName,
    Level,
    Step,
    Message,
    Details,
    CreatedAt
FROM dbo.OperationLogs
ORDER BY Id DESC;
'@ -Parameters @{
    Top = $Top
} | Format-Table -Wrap -AutoSize
