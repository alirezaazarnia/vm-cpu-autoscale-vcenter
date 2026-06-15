[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\autoscale.config.psd1')
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'AutoScale.Common.psm1') -Force

$config = Import-AutoScaleConfig -Path $ConfigPath
$connectionString = New-AutoScaleSqlConnectionString -Config $config
$runId = [guid]::NewGuid()

Write-AutoScaleLog `
    -ConnectionString $connectionString `
    -RunId $runId `
    -Level Info `
    -Step 'DatabaseTest' `
    -Message 'Database connection test started.'

$settings = Get-AutoScaleSettings -ConnectionString $connectionString
$vCenters = Get-AutoScaleEnabledVCenters -ConnectionString $connectionString

Write-AutoScaleLog `
    -ConnectionString $connectionString `
    -RunId $runId `
    -Level Info `
    -Step 'DatabaseTest' `
    -Message 'Database connection test completed.' `
    -Details "Settings=$($settings.Count); EnabledVCenters=$($vCenters.Rows.Count)"

[pscustomobject]@{
    RunId           = $runId
    DatabaseServer  = $config.Database.Server
    DatabaseName    = $config.Database.Name
    SettingsCount   = $settings.Count
    EnabledVCenters = $vCenters.Rows.Count
}
