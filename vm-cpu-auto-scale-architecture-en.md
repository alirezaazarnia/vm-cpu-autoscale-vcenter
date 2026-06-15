# VM CPU Auto Scale Architecture

## Overview

This solution automatically increases CPU resources for approved virtual
machines when CPU usage alarms are triggered in vCenter. It later restores
the VM CPU count during an approved maintenance window.

The solution is designed for environments with multiple vCenters, SQL Server
as the central state store, and PowerCLI as the vCenter integration layer.

No VM is scaled unless it is explicitly allowed in SQL Server.

## Main Goals

- Scale up VM CPU automatically when a configured vCenter CPU alarm is active.
- Scale up gradually by doubling the current CPU count.
- Never exceed the configured maximum CPU count, initially 16 vCPU.
- Track all decisions, actions, errors, and recovery attempts in SQL Server.
- Restore CPU to the value that existed before the first active boost.
- Perform scale-down only during the approved Sunday maintenance window.
- Process scale-down one VM at a time to reduce operational risk.
- Send email notifications for failures and scale-down summaries.

## Architecture

```text
              +----------------------+
              |  vCenter Alarms      |
              +----------+-----------+
                         |
                         v
            +---------------------------+
            | CpuScaleUp-Poller.ps1     |
            | Every 10 minutes          |
            +------------+--------------+
                         |
                         v
                  +-------------+
                  | SQL Server  |
                  +-------------+
                         ^
                         |
            +------------+--------------+
            | CpuScaleDown-Worker.ps1   |
            | Sunday 08:00 local time   |
            +---------------------------+
```

## Technology Choices

| Area | Decision |
| --- | --- |
| Database | SQL Server |
| vCenter access | VMware PowerCLI |
| Authentication | Service account |
| Logging | SQL Server tables |
| Error tracking | SQL Server tables |
| Notification | SMTP email |
| Scale-up schedule | Every 10 minutes |
| Scale-down schedule | Sunday 08:00 local server time |
| Scale-down execution | One VM at a time |

## Source of Truth

SQL Server is the source of truth for whether a VM is allowed to be scaled.

Custom Attributes in vCenter may be used later for discovery or tagging, but
the final decision to scale a VM must come from SQL Server.

If a VM is not present and enabled in the SQL Server allow-list, no scale-up
operation is performed.

## Multi-vCenter Design

The environment contains multiple vCenters, approximately 10.

VM names are expected to be unique across all vCenters. Even so, all operational
records should include the vCenter name to make auditing and troubleshooting
clear.

## SQL Server Tables

### vCenters

Stores vCenter connection targets.

| Column | Description |
| --- | --- |
| Id | Unique vCenter ID |
| Name | Friendly vCenter name |
| Server | vCenter FQDN or IP |
| Enabled | Whether this vCenter is active for monitoring |

### AllowedVMs

Stores the VMs that are allowed to be auto-scaled.

| Column | Description |
| --- | --- |
| Id | Unique row ID |
| vCenterName | vCenter where the VM exists |
| VMName | Name of the VM |
| Enabled | Whether scale-up is allowed |
| MaxCPU | Maximum allowed CPU count, default 16 |
| AllowScaleDownPowerOff | Whether scale-down may power off the VM |
| Notes | Optional operational notes |

### Settings

Stores configurable operational values.

| Setting | Initial Value | Description |
| --- | --- | --- |
| CpuAlarmName | Virtual machine CPU usage | vCenter alarm name to monitor |
| PollerIntervalMinutes | 10 | Scale-up polling interval |
| ScaleUpCooldownMinutes | 30 | Minimum time between scale-up actions for the same VM |
| DefaultMaxCPU | 16 | Default maximum CPU count |
| ScaleDownDay | Sunday | Approved scale-down day |
| ScaleDownTime | 08:00 | Approved scale-down time in local server time |
| SmtpServer | To be provided at runtime | SMTP server |
| MailFrom | To be provided at runtime | Sender address |
| MailTo | To be provided at runtime | Recipient address |

### ScaleGroups

Represents one active boost lifecycle for a VM.

A single VM may be scaled up multiple times during one lifecycle, for example
2 -> 4 -> 8 -> 16. The group preserves the original CPU count before the first
boost so scale-down can restore the VM directly to its original value.

| Column | Description |
| --- | --- |
| Id | Unique scale group ID |
| vCenterName | vCenter name |
| VMName | VM name |
| OriginalCPU | CPU count before the first boost |
| CurrentCPU | Latest known boosted CPU count |
| MaxCPU | Maximum CPU allowed for this VM |
| OriginalPowerState | VM power state before the first boost |
| FirstScaleUpTime | First scale-up timestamp |
| LastScaleUpTime | Latest scale-up timestamp |
| ScaleDownTime | Scale-down completion timestamp |
| Status | Active / Reverted / Failed / ManualReviewRequired |

### ScaleEvents

Stores every scale action and decision.

| Column | Description |
| --- | --- |
| Id | Unique event ID |
| ScaleGroupId | Related scale lifecycle |
| vCenterName | vCenter name |
| VMName | VM name |
| EventType | Poller / ScaleUp / ScaleDown / Recovery / Skip / Error |
| OldCPU | CPU before the event |
| NewCPU | CPU after the event |
| AlertTime | vCenter alarm timestamp, if available |
| EventTime | Event timestamp |
| Status | Succeeded / Failed / Skipped / PendingManualReview |
| Message | Human-readable event details |
| ErrorDetails | Full error details when available |

### OperationLogs

Stores detailed step-by-step logs for troubleshooting.

| Column | Description |
| --- | --- |
| Id | Unique log ID |
| RunId | Unique ID for one script execution |
| vCenterName | vCenter name, if applicable |
| VMName | VM name, if applicable |
| Level | Info / Warning / Error |
| Step | Current operation step |
| Message | Log message |
| Details | Additional diagnostic details |
| CreatedAt | Log timestamp |

### EmailNotifications

Stores email notifications that were sent or attempted.

| Column | Description |
| --- | --- |
| Id | Unique notification ID |
| RunId | Related script run ID |
| vCenterName | vCenter name, if applicable |
| VMName | VM name, if applicable |
| Subject | Email subject |
| Body | Email body |
| Status | Sent / Failed |
| ErrorDetails | SMTP error details, if any |
| CreatedAt | Notification timestamp |

## Scale-Up Process

The scale-up poller runs every 10 minutes.

High-level flow:

1. Start a new run and create a RunId.
2. Read enabled vCenters from SQL Server.
3. Connect to each vCenter using the service account and PowerCLI.
4. Read active alarms matching the configured CPU alarm name.
5. Confirm the alarm belongs to a virtual machine.
6. Check whether the VM exists and is enabled in AllowedVMs.
7. Check whether the VM is currently within cooldown.
8. Read the VM current CPU count.
9. Calculate the new CPU count using `NewCPU = Min(CurrentCPU * 2, MaxCPU)`.
10. If the VM is already at MaxCPU, log and skip.
11. If CPU Hot Add is available, increase CPU without powering off the VM.
12. If CPU Hot Add is not available, power off the VM, change CPU, and power it on.
13. Record the scale-up in ScaleGroups and ScaleEvents.
14. Log all steps to OperationLogs.

## Scale-Up Rules

- Only VMs enabled in AllowedVMs may be scaled.
- CPU is doubled on each scale-up.
- CPU must never exceed MaxCPU.
- Initial MaxCPU is 16.
- Multiple scale-ups are allowed during the same active boost lifecycle.
- A 30-minute cooldown is required between scale-up operations for the same VM.
- The cooldown value must come from SQL Server Settings.
- If a VM reaches MaxCPU, further scale-up attempts are skipped and logged.
- The first scale-up stores the VM OriginalCPU.
- Later scale-ups update CurrentCPU but preserve OriginalCPU.

## Scale-Up Failure Handling

If scale-up fails, the system must try to return the VM to the last known
working state.

Expected behavior:

1. Record the failure in SQL Server.
2. Attempt to restore the previous CPU value if it was changed.
3. Ensure the VM is powered on if it was running before the operation.
4. Send an email notification with enough detail for manual investigation.
5. Mark the event as Failed or PendingManualReview.

The priority is to avoid leaving the VM powered off.

## Scale-Down Process

The scale-down worker runs during the approved maintenance window:

- Day: Sunday
- Time: 08:00
- Timezone: local time of the server running the job

High-level flow:

1. Start a new run and create a RunId.
2. Read active ScaleGroups where Status is Active.
3. Process one VM at a time.
4. Connect to the relevant vCenter.
5. Confirm the VM still exists.
6. Read the current VM power state and CPU count.
7. Power off the VM if required.
8. Restore CPU directly to OriginalCPU.
9. Power on the VM.
10. Update ScaleGroups status to Reverted.
11. Record detailed ScaleEvents and OperationLogs.
12. Send a final summary email for the scale-down run.

## Scale-Down Rules

- Only VMs with active boosted ScaleGroups are processed.
- Scale-down restores the VM directly to the CPU value before the first boost.
- Scale-down is processed one VM at a time.
- Scale-down should continue to run even if the VM was later disabled in
  AllowedVMs, because the goal is to return the VM to its normal state.
- If the VM is not found, record the issue and send an email notification.

## Scale-Down Failure Handling

If scale-down fails, the system must avoid leaving the VM powered off.

Expected behavior:

1. Record the failed step in SQL Server.
2. If the VM was powered off by the worker, attempt to restore the CPU value
   that was working before the scale-down attempt.
3. Power on the VM so the service is not left offline.
4. Send an email notification for manual investigation.
5. Mark the scale group as ManualReviewRequired or Failed.

The operational priority is service availability first, then manual correction.

## Skip Conditions

A VM is skipped when:

- The VM is not listed in AllowedVMs.
- The VM is listed but Enabled is false.
- The VM is already at MaxCPU.
- The VM is still inside the scale-up cooldown window.
- The alarm does not belong to a virtual machine.
- The alarm does not match the configured CPU alarm name.
- The vCenter is disabled in SQL Server.

Every skip decision must be logged in SQL Server with the reason.

## Alarm Selection

The initial alarm name is:

```text
Virtual machine CPU usage
```

The alarm name should be configurable in SQL Server.

The poller should also verify that the alarm is active on a VM object. This
avoids scaling based only on a matching alarm name.

## Email Notifications

Email is required for:

- Scale-up failure.
- Scale-down failure.
- VM not found during scale-down.
- Recovery action failure.
- Final scale-down summary.

Failure emails should include:

- vCenter name.
- VM name.
- Operation type.
- Step that failed.
- Previous CPU.
- Target CPU.
- Previous power state.
- Current power state, if available.
- Error message and details.
- RunId for troubleshooting.

## Logging Requirements

Logging must be detailed and stored in SQL Server.

The system should log:

- Script start and end.
- vCenter connection attempts.
- Alarm discovery.
- VM allow-list decisions.
- Cooldown decisions.
- CPU calculation.
- Power operations.
- CPU reconfiguration attempts.
- Successes.
- Skips.
- Failures.
- Recovery attempts.
- Email notification attempts.

## Status Model

Recommended ScaleGroups statuses:

| Status | Meaning |
| --- | --- |
| Active | VM has one or more active boosts |
| Reverted | VM was restored to OriginalCPU |
| Failed | Operation failed and could not be fully recovered |
| ManualReviewRequired | VM needs manual investigation |

Recommended ScaleEvents statuses:

| Status | Meaning |
| --- | --- |
| Succeeded | Event completed successfully |
| Failed | Event failed |
| Skipped | Event was intentionally skipped |
| PendingManualReview | Event needs human review |

## Key Principles

- SQL Server is the source of truth.
- vCenter Custom Attributes are optional and not authoritative.
- All actions must be auditable.
- Every skip and failure must be explainable from the database.
- CPU increases are gradual and capped.
- Scale-down restores the CPU value from before the first boost.
- Scale-down runs one VM at a time.
- Availability is the priority during failure handling.
- Failed operations must trigger email notifications.
