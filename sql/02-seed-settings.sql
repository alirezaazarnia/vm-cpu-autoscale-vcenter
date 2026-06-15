/*
    Inserts default settings for the VM CPU Auto Scale solution.
*/

USE [VMCPUAutoScale];
GO

MERGE dbo.Settings AS target
USING
(
    VALUES
        (N'CpuAlarmName', N'Virtual machine CPU usage', N'vCenter alarm name monitored by the scale-up poller'),
        (N'PollerIntervalMinutes', N'10', N'Scale-up polling interval'),
        (N'ScaleUpCooldownMinutes', N'30', N'Minimum time between scale-up actions for the same VM'),
        (N'DefaultMaxCPU', N'16', N'Default maximum CPU count'),
        (N'ScaleDownDay', N'Sunday', N'Approved scale-down day'),
        (N'ScaleDownTime', N'08:00', N'Approved scale-down time in local server time'),
        (N'SmtpServer', N'TO_BE_PROVIDED', N'SMTP server used for notifications'),
        (N'MailFrom', N'TO_BE_PROVIDED', N'Notification sender address'),
        (N'MailTo', N'TO_BE_PROVIDED', N'Notification recipient address')
) AS source (SettingName, SettingValue, Description)
ON target.SettingName = source.SettingName
WHEN MATCHED THEN
    UPDATE SET
        Description = source.Description,
        UpdatedAt = sysdatetime()
WHEN NOT MATCHED THEN
    INSERT (SettingName, SettingValue, Description)
    VALUES (source.SettingName, source.SettingValue, source.Description);
GO
