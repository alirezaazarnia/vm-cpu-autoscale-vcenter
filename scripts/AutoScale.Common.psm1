Set-StrictMode -Version Latest

function Add-AutoScaleSqlParameter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Data.SqlClient.SqlCommand]$Command,

        [Parameter(Mandatory)]
        [string]$Name,

        $Value
    )

    if ($null -eq $Value) {
        $sqlType = [System.Data.SqlDbType]::NVarChar
    }
    else {
        $sqlType = switch ($Value.GetType().Name) {
            'Int32' { [System.Data.SqlDbType]::Int; break }
            'Int64' { [System.Data.SqlDbType]::BigInt; break }
            'Boolean' { [System.Data.SqlDbType]::Bit; break }
            'Guid' { [System.Data.SqlDbType]::UniqueIdentifier; break }
            'DateTime' { [System.Data.SqlDbType]::DateTime2; break }
            default { [System.Data.SqlDbType]::NVarChar }
        }
    }

    $parameter = $Command.Parameters.Add("@$Name", $sqlType)
    if ($null -eq $Value) {
        $parameter.Value = [System.DBNull]::Value
    }
    else {
        $parameter.Value = [object]$Value
    }
}

function Import-AutoScaleConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Config file was not found: $Path"
    }

    Import-PowerShellDataFile -LiteralPath $Path
}

function New-AutoScaleSqlConnectionString {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    $builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new()
    $builder['Data Source'] = $Config.Database.Server
    $builder['Initial Catalog'] = $Config.Database.Name
    $builder['User ID'] = $Config.Database.Username
    $builder['Password'] = $Config.Database.Password
    $builder['TrustServerCertificate'] = $true
    $builder['Application Name'] = 'VM CPU Auto Scale'

    $builder.ConnectionString
}

function Invoke-AutoScaleSqlQuery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConnectionString,

        [Parameter(Mandatory)]
        [string]$Query,

        [hashtable]$Parameters = @{}
    )

    $connection = [System.Data.SqlClient.SqlConnection]::new($ConnectionString)
    $command = $connection.CreateCommand()
    $command.CommandText = $Query

    foreach ($name in $Parameters.Keys) {
        Add-AutoScaleSqlParameter -Command $command -Name $name -Value $Parameters[$name]
    }

    $table = [System.Data.DataTable]::new()
    $adapter = [System.Data.SqlClient.SqlDataAdapter]::new($command)

    try {
        [void]$adapter.Fill($table)
        ,$table
    }
    finally {
        $adapter.Dispose()
        $command.Dispose()
        $connection.Dispose()
    }
}

function Invoke-AutoScaleSqlNonQuery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConnectionString,

        [Parameter(Mandatory)]
        [string]$Query,

        [hashtable]$Parameters = @{}
    )

    $connection = [System.Data.SqlClient.SqlConnection]::new($ConnectionString)
    $command = $connection.CreateCommand()
    $command.CommandText = $Query

    foreach ($name in $Parameters.Keys) {
        Add-AutoScaleSqlParameter -Command $command -Name $name -Value $Parameters[$name]
    }

    try {
        $connection.Open()
        [void]$command.ExecuteNonQuery()
    }
    finally {
        $command.Dispose()
        $connection.Dispose()
    }
}

function Write-AutoScaleLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConnectionString,

        [Parameter(Mandatory)]
        [guid]$RunId,

        [ValidateSet('Info', 'Warning', 'Error')]
        [string]$Level = 'Info',

        [Parameter(Mandatory)]
        [string]$Step,

        [Parameter(Mandatory)]
        [string]$Message,

        [string]$vCenterName,
        [string]$VMName,
        [string]$Details
    )

    $query = @'
INSERT INTO dbo.OperationLogs
(
    RunId,
    vCenterName,
    VMName,
    Level,
    Step,
    Message,
    Details
)
VALUES
(
    @RunId,
    @vCenterName,
    @VMName,
    @Level,
    @Step,
    @Message,
    @Details
);
'@

    Invoke-AutoScaleSqlNonQuery -ConnectionString $ConnectionString -Query $query -Parameters @{
        RunId       = $RunId.ToString()
        vCenterName = $vCenterName
        VMName      = $VMName
        Level       = $Level
        Step        = $Step
        Message     = $Message
        Details     = $Details
    }
}

function Get-AutoScaleSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConnectionString
    )

    $rows = Invoke-AutoScaleSqlQuery -ConnectionString $ConnectionString -Query @'
SELECT SettingName, SettingValue
FROM dbo.Settings;
'@

    $settings = @{}
    foreach ($row in $rows.Rows) {
        $settings[$row.SettingName] = $row.SettingValue
    }

    $settings
}

function Get-AutoScaleEnabledVCenters {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConnectionString
    )

    Invoke-AutoScaleSqlQuery -ConnectionString $ConnectionString -Query @'
SELECT Name, Server
FROM dbo.vCenters
WHERE Enabled = 1
ORDER BY Name;
'@
}

function ConvertTo-AutoScaleCredential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Username,

        [Parameter(Mandatory)]
        [string]$Password
    )

    $securePassword = ConvertTo-SecureString -String $Password -AsPlainText -Force
    [pscredential]::new($Username, $securePassword)
}

function Send-AutoScaleEmail {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConnectionString,

        [Parameter(Mandatory)]
        [guid]$RunId,

        [Parameter(Mandatory)]
        [hashtable]$Settings,

        [Parameter(Mandatory)]
        [string]$Subject,

        [Parameter(Mandatory)]
        [string]$Body,

        [string]$vCenterName,
        [string]$VMName
    )

    $smtpServer = [string]$Settings['SmtpServer']
    $mailFrom = [string]$Settings['MailFrom']
    $mailTo = [string]$Settings['MailTo']

    if ([string]::IsNullOrWhiteSpace($smtpServer) -or
        [string]::IsNullOrWhiteSpace($mailFrom) -or
        [string]::IsNullOrWhiteSpace($mailTo) -or
        $smtpServer -eq 'TO_BE_PROVIDED' -or
        $mailFrom -eq 'TO_BE_PROVIDED' -or
        $mailTo -eq 'TO_BE_PROVIDED') {

        Invoke-AutoScaleSqlNonQuery -ConnectionString $ConnectionString -Query @'
INSERT INTO dbo.EmailNotifications
(
    RunId,
    vCenterName,
    VMName,
    Subject,
    Body,
    Status,
    ErrorDetails
)
VALUES
(
    @RunId,
    @vCenterName,
    @VMName,
    @Subject,
    @Body,
    N'Failed',
    N'SMTP settings are not configured.'
);
'@ -Parameters @{
            RunId       = $RunId
            vCenterName = $vCenterName
            VMName      = $VMName
            Subject     = $Subject
            Body        = $Body
        }

        return
    }

    try {
        Send-MailMessage -SmtpServer $smtpServer -From $mailFrom -To $mailTo -Subject $Subject -Body $Body -ErrorAction Stop

        Invoke-AutoScaleSqlNonQuery -ConnectionString $ConnectionString -Query @'
INSERT INTO dbo.EmailNotifications
(
    RunId,
    vCenterName,
    VMName,
    Subject,
    Body,
    Status
)
VALUES
(
    @RunId,
    @vCenterName,
    @VMName,
    @Subject,
    @Body,
    N'Sent'
);
'@ -Parameters @{
            RunId       = $RunId
            vCenterName = $vCenterName
            VMName      = $VMName
            Subject     = $Subject
            Body        = $Body
        }
    }
    catch {
        Invoke-AutoScaleSqlNonQuery -ConnectionString $ConnectionString -Query @'
INSERT INTO dbo.EmailNotifications
(
    RunId,
    vCenterName,
    VMName,
    Subject,
    Body,
    Status,
    ErrorDetails
)
VALUES
(
    @RunId,
    @vCenterName,
    @VMName,
    @Subject,
    @Body,
    N'Failed',
    @ErrorDetails
);
'@ -Parameters @{
            RunId        = $RunId
            vCenterName  = $vCenterName
            VMName       = $VMName
            Subject      = $Subject
            Body         = $Body
            ErrorDetails = [string]$_
        }
    }
}

Export-ModuleMember -Function @(
    'Import-AutoScaleConfig',
    'New-AutoScaleSqlConnectionString',
    'Invoke-AutoScaleSqlQuery',
    'Invoke-AutoScaleSqlNonQuery',
    'Write-AutoScaleLog',
    'Get-AutoScaleSettings',
    'Get-AutoScaleEnabledVCenters',
    'ConvertTo-AutoScaleCredential',
    'Send-AutoScaleEmail'
)
