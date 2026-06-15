# VM CPU AutoScale for vCenter

Automated CPU scale-up and scale-down for VMware vCenter virtual machines, built with PowerShell, VMware PowerCLI, and SQL Server.

When a configured CPU alarm fires in vCenter, the solution doubles the VM's CPU count automatically. During the weekly maintenance window, all scaled VMs are restored to their original CPU count.

No VM is ever scaled unless it is explicitly added to the allow-list in SQL Server.

---

## How It Works

```
  vCenter CPU Alarm fires
          │
          ▼
  CpuScaleUp-Poller.ps1       ← runs every 10 minutes via Task Scheduler
          │
          │  checks AllowedVMs, cooldown, MaxCPU
          │  doubles CPU  (2 → 4 → 8 → 16)
          │
          ▼
      SQL Server               ← single source of truth for all state
          ▲
          │  reads ScaleGroups with Status = Active
          │  restores CPU to OriginalCPU
          │
  CpuScaleDown-Worker.ps1     ← runs every Sunday at 08:00 via Task Scheduler
```

### Scale-Up Rules

- Only VMs listed and enabled in `AllowedVMs` are eligible.
- CPU is doubled on each scale-up: `NewCPU = Min(CurrentCPU × 2, MaxCPU)`.
- Default maximum is **16 vCPU** (configurable per VM).
- A 30-minute cooldown is enforced between scale-ups for the same VM.
- If the VM supports **CPU Hot Add**, it is scaled without a reboot.
- If Hot Add is not enabled, the VM is gracefully shut down, reconfigured, and powered back on.

### Scale-Down Rules

- Runs once a week (Sunday 08:00 by default, configurable).
- Restores each VM directly to the CPU count it had **before the first scale-up**.
- Processes one VM at a time to reduce operational risk.
- If scale-down fails, the VM is powered back on and the event is flagged for manual review.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| Windows Server | Server running the scheduled tasks |
| PowerShell 5.1+ | Built into Windows Server |
| [VMware PowerCLI](https://developer.broadcom.com/powercli) | `Install-Module VMware.PowerCLI` |
| SQL Server | Any edition (Express works for small environments) |
| vCenter Service Account | Needs read access to VMs and alarms |
| SQL Service Account | Created by the setup script |

---

## Installation

### Step 1 — Copy the project files

Copy the entire project to the server that will run the scheduled tasks. For example:

```
C:\AutoScale\
```

### Step 2 — Create the database

Open **SSMS** or **sqlcmd**, open `sql\00-create-database-and-login.sql`, replace `YOUR_DB_PASSWORD_HERE` with a strong password, and run it.

This creates:
- Database: `VMCPUAutoScale`
- SQL login: `svc_vm_cpu_autoscale`

### Step 3 — Create the schema

Run `sql\01-create-schema.sql` against the `VMCPUAutoScale` database.

### Step 4 — Seed default settings

Run `sql\02-seed-settings.sql` against the `VMCPUAutoScale` database.

### Step 5 — Configure credentials

Edit `config\autoscale.config.psd1` and fill in your values:

```powershell
@{
    Database = @{
        Server   = 'YOUR_SQL_SERVER_NAME'      # SQL Server hostname or IP
        Name     = 'VMCPUAutoScale'
        Username = 'svc_vm_cpu_autoscale'
        Password = 'YOUR_DB_PASSWORD_HERE'     # same password from Step 2
    }

    vCenter = @{
        Username = 'your-service-account@your-domain.com'
        Password = 'YOUR_VCENTER_PASSWORD_HERE'
    }
}
```

> **Security note:** Keep `config\autoscale.config.psd1` out of source control. The included `.gitignore` already excludes it.

### Step 6 — Install VMware PowerCLI

Run this once on the server:

```powershell
Install-Module -Name VMware.PowerCLI -Scope AllUsers -Force
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false
```

### Step 7 — Add your vCenters

```powershell
.\scripts\Add-AutoScaleVCenter.ps1 -Name "vcenter-prod-01" -Server "vcenter01.yourdomain.com"
.\scripts\Add-AutoScaleVCenter.ps1 -Name "vcenter-prod-02" -Server "vcenter02.yourdomain.com"
```

### Step 8 — Add VMs to the allow-list

```powershell
# Basic — uses defaults (MaxCPU = 16, scale-down power-off allowed)
.\scripts\Add-AutoScaleAllowedVM.ps1 -vCenterName "vcenter-prod-01" -VMName "WebServer01"

# Custom MaxCPU
.\scripts\Add-AutoScaleAllowedVM.ps1 -vCenterName "vcenter-prod-01" -VMName "DBServer01" -MaxCPU 8

# Disable scale-down power-off (VM must support CPU Hot Add)
.\scripts\Add-AutoScaleAllowedVM.ps1 -vCenterName "vcenter-prod-01" -VMName "CriticalApp01" -AllowScaleDownPowerOff $false
```

### Step 9 — Configure email notifications

```powershell
.\scripts\Set-AutoScaleSetting.ps1 -Name SmtpServer -Value "smtp.yourdomain.com"
.\scripts\Set-AutoScaleSetting.ps1 -Name MailFrom    -Value "autoscale@yourdomain.com"
.\scripts\Set-AutoScaleSetting.ps1 -Name MailTo      -Value "ops-team@yourdomain.com"
```

### Step 10 — Register scheduled tasks

```powershell
.\scripts\Register-AutoScaleScheduledTasks.ps1 `
    -TaskUser     "DOMAIN\svc-autoscale" `
    -TaskPassword "service-account-password"
```

This creates two tasks under `\VM CPU AutoScale\`:

| Task | Schedule |
|---|---|
| VM CPU AutoScale - Scale Up Poller | Every 10 minutes |
| VM CPU AutoScale - Scale Down Worker | Every Sunday at 08:00 |

---

## Verifying the Setup

Test that the database connection and configuration are working:

```powershell
.\scripts\Test-AutoScaleDatabase.ps1
```

Expected output:

```
RunId           : xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
DatabaseServer  : your-sql-server
DatabaseName    : VMCPUAutoScale
SettingsCount   : 9
EnabledVCenters : 2
```

---

## Day-to-Day Management

### Run scale-up manually (dry run — no changes made)

```powershell
.\scripts\CpuScaleUp-Poller.ps1
```

### Run scale-up and apply changes

```powershell
.\scripts\CpuScaleUp-Poller.ps1 -Execute
```

### Run scale-down manually (dry run)

```powershell
.\scripts\CpuScaleDown-Worker.ps1 -IgnoreMaintenanceWindow
```

### Run scale-down and apply changes

```powershell
.\scripts\CpuScaleDown-Worker.ps1 -Execute -IgnoreMaintenanceWindow
```

### View recent logs

```powershell
# Last 50 entries (default)
.\scripts\Get-AutoScaleLastLogs.ps1

# Last 200 entries
.\scripts\Get-AutoScaleLastLogs.ps1 -Top 200
```

### Disable a VM temporarily

```powershell
.\scripts\Add-AutoScaleAllowedVM.ps1 -vCenterName "vcenter-prod-01" -VMName "WebServer01" -Enabled $false
```

### Disable a vCenter temporarily

```powershell
.\scripts\Add-AutoScaleVCenter.ps1 -Name "vcenter-prod-01" -Server "vcenter01.yourdomain.com" -Enabled $false
```

### Update a setting

```powershell
# Change cooldown to 60 minutes
.\scripts\Set-AutoScaleSetting.ps1 -Name ScaleUpCooldownMinutes -Value 60

# Change scale-down to run on Saturday at 06:00
.\scripts\Set-AutoScaleSetting.ps1 -Name ScaleDownDay  -Value Saturday
.\scripts\Set-AutoScaleSetting.ps1 -Name ScaleDownTime -Value "06:00"
```

---

## Configurable Settings

All settings are stored in the `dbo.Settings` table and can be changed with `Set-AutoScaleSetting.ps1`.

| Setting | Default | Description |
|---|---|---|
| `CpuAlarmName` | `Virtual machine CPU usage` | vCenter alarm name to monitor |
| `PollerIntervalMinutes` | `10` | Scale-up check interval |
| `ScaleUpCooldownMinutes` | `30` | Minimum minutes between scale-ups for the same VM |
| `DefaultMaxCPU` | `16` | Maximum CPU when no per-VM limit is set |
| `ScaleDownDay` | `Sunday` | Day of week for the maintenance window |
| `ScaleDownTime` | `08:00` | Start time of the maintenance window (server local time) |
| `SmtpServer` | *(required)* | SMTP relay for email notifications |
| `MailFrom` | *(required)* | Sender address for notifications |
| `MailTo` | *(required)* | Recipient address for notifications |

---

## Database Tables

| Table | Purpose |
|---|---|
| `dbo.vCenters` | Registered vCenter servers |
| `dbo.AllowedVMs` | VMs permitted for auto-scaling |
| `dbo.Settings` | Configurable operational values |
| `dbo.ScaleGroups` | One record per active scale lifecycle per VM |
| `dbo.ScaleEvents` | Every scale action, skip, and error |
| `dbo.OperationLogs` | Detailed step-by-step logs per script run |
| `dbo.EmailNotifications` | Sent and failed email notification records |

---

## Project Structure

```
├── config/
│   └── autoscale.config.psd1       # DB and vCenter credentials (not committed)
├── scripts/
│   ├── AutoScale.Common.psm1       # Shared functions (SQL, logging, email)
│   ├── CpuScaleUp-Poller.ps1       # Scale-up logic — run every 10 min
│   ├── CpuScaleDown-Worker.ps1     # Scale-down logic — run weekly
│   ├── Register-AutoScaleScheduledTasks.ps1
│   ├── Add-AutoScaleVCenter.ps1
│   ├── Add-AutoScaleAllowedVM.ps1
│   ├── Set-AutoScaleSetting.ps1
│   ├── Test-AutoScaleDatabase.ps1
│   └── Get-AutoScaleLastLogs.ps1
├── sql/
│   ├── 00-create-database-and-login.sql
│   ├── 01-create-schema.sql
│   └── 02-seed-settings.sql
└── EncryptPassword.ps1             # Utility: encrypt a password using DPAPI
```

---

## License

MIT
