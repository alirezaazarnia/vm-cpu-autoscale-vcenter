# Encrypt Password (DPAPI — output is only decryptable on the same machine and user account)
Clear-Host
$Pwd = Read-Host -AsSecureString -Prompt "Password to Encrypt"
$Pwd | ConvertFrom-SecureString | Set-Content "UserPassword.txt"

# Decrypt Password (example — not used by the main scripts)
#$SecurePwd   = Get-Content "UserPassword.txt" | ConvertTo-SecureString
#$UserName    = "your-service-account@your-domain.com"
#$Credentials = New-Object System.Management.Automation.PSCredential $UserName, $SecurePwd
