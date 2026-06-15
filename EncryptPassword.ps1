#  Encrypt Password
Clear-Host
$Pwd=Read-Host -AsSecureString -Prompt "Password to Encrypt"
$Pwd | ConvertFrom-SecureString | Set-Content "C:\Scripts\EncryptPassword\UserPassword.txt"

# Decrypt Password

#$Key       = Get-Content "Z:\***.key"
#$SecurePwd = Get-Content "E:\Test-Scripts\Test\NewUserPassword.txt" | ConvertTo-SecureString -Key $Key
#$UserName  = "your-service-account@your-domain.com"
#$Credentials = New-Object System.Management.Automation.PSCredential $UserName, $SecurePwd
