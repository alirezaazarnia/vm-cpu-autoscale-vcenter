[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Name,

    [Parameter(Mandatory)]
    [string]$Server,

    [bool]$Enabled = $true,

    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\autoscale.config.psd1')
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'AutoScale.Common.psm1') -Force

$config = Import-AutoScaleConfig -Path $ConfigPath
$connectionString = New-AutoScaleSqlConnectionString -Config $config

Invoke-AutoScaleSqlNonQuery -ConnectionString $connectionString -Query @'
MERGE dbo.vCenters AS target
USING
(
    SELECT
        @Name AS Name,
        @Server AS Server,
        @Enabled AS Enabled
) AS source
ON target.Name = source.Name
WHEN MATCHED THEN
    UPDATE SET
        Server = source.Server,
        Enabled = source.Enabled,
        UpdatedAt = sysdatetime()
WHEN NOT MATCHED THEN
    INSERT (Name, Server, Enabled)
    VALUES (source.Name, source.Server, source.Enabled);
'@ -Parameters @{
    Name    = $Name
    Server  = $Server
    Enabled = [int]$Enabled
}

Write-Host "vCenter saved: $Name -> $Server"
