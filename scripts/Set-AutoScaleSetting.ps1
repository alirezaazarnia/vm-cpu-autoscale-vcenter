[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Name,

    [Parameter(Mandatory)]
    [string]$Value,

    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\autoscale.config.psd1')
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'AutoScale.Common.psm1') -Force

$config = Import-AutoScaleConfig -Path $ConfigPath
$connectionString = New-AutoScaleSqlConnectionString -Config $config

Invoke-AutoScaleSqlNonQuery -ConnectionString $connectionString -Query @'
UPDATE dbo.Settings
SET SettingValue = @Value,
    UpdatedAt = sysdatetime()
WHERE SettingName = @Name;

IF @@ROWCOUNT = 0
BEGIN
    INSERT INTO dbo.Settings (SettingName, SettingValue, Description)
    VALUES (@Name, @Value, N'Custom setting');
END;
'@ -Parameters @{
    Name  = $Name
    Value = $Value
}

Write-Host "Setting updated: $Name"
