/*
    Creates the SQL Server schema for the VM CPU Auto Scale solution.

    Run this script after 00-create-database-and-login.sql.
*/

USE [VMCPUAutoScale];
GO

CREATE TABLE dbo.vCenters
(
    Id int IDENTITY(1,1) NOT NULL CONSTRAINT PK_vCenters PRIMARY KEY,
    Name nvarchar(128) NOT NULL,
    Server nvarchar(256) NOT NULL,
    Enabled bit NOT NULL CONSTRAINT DF_vCenters_Enabled DEFAULT (1),
    CreatedAt datetime2(0) NOT NULL CONSTRAINT DF_vCenters_CreatedAt DEFAULT (sysdatetime()),
    UpdatedAt datetime2(0) NULL,
    CONSTRAINT UQ_vCenters_Name UNIQUE (Name),
    CONSTRAINT UQ_vCenters_Server UNIQUE (Server)
);
GO

CREATE TABLE dbo.AllowedVMs
(
    Id int IDENTITY(1,1) NOT NULL CONSTRAINT PK_AllowedVMs PRIMARY KEY,
    vCenterName nvarchar(128) NOT NULL,
    VMName nvarchar(256) NOT NULL,
    Enabled bit NOT NULL CONSTRAINT DF_AllowedVMs_Enabled DEFAULT (1),
    MaxCPU int NOT NULL CONSTRAINT DF_AllowedVMs_MaxCPU DEFAULT (16),
    AllowScaleDownPowerOff bit NOT NULL CONSTRAINT DF_AllowedVMs_AllowScaleDownPowerOff DEFAULT (1),
    Notes nvarchar(1000) NULL,
    CreatedAt datetime2(0) NOT NULL CONSTRAINT DF_AllowedVMs_CreatedAt DEFAULT (sysdatetime()),
    UpdatedAt datetime2(0) NULL,
    CONSTRAINT UQ_AllowedVMs_vCenter_VM UNIQUE (vCenterName, VMName),
    CONSTRAINT CK_AllowedVMs_MaxCPU CHECK (MaxCPU >= 1 AND MaxCPU <= 128)
);
GO

CREATE TABLE dbo.Settings
(
    SettingName nvarchar(128) NOT NULL CONSTRAINT PK_Settings PRIMARY KEY,
    SettingValue nvarchar(1000) NOT NULL,
    Description nvarchar(1000) NULL,
    UpdatedAt datetime2(0) NOT NULL CONSTRAINT DF_Settings_UpdatedAt DEFAULT (sysdatetime())
);
GO

CREATE TABLE dbo.ScaleGroups
(
    Id bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_ScaleGroups PRIMARY KEY,
    vCenterName nvarchar(128) NOT NULL,
    VMName nvarchar(256) NOT NULL,
    OriginalCPU int NOT NULL,
    CurrentCPU int NOT NULL,
    MaxCPU int NOT NULL,
    OriginalPowerState nvarchar(64) NULL,
    FirstScaleUpTime datetime2(0) NOT NULL,
    LastScaleUpTime datetime2(0) NOT NULL,
    ScaleDownTime datetime2(0) NULL,
    Status nvarchar(64) NOT NULL,
    CreatedAt datetime2(0) NOT NULL CONSTRAINT DF_ScaleGroups_CreatedAt DEFAULT (sysdatetime()),
    UpdatedAt datetime2(0) NULL,
    CONSTRAINT CK_ScaleGroups_Status CHECK (Status IN (N'Active', N'Reverted', N'Failed', N'ManualReviewRequired')),
    CONSTRAINT CK_ScaleGroups_CPU CHECK (OriginalCPU >= 1 AND CurrentCPU >= 1 AND MaxCPU >= 1)
);
GO

CREATE UNIQUE INDEX UX_ScaleGroups_Active_VM
ON dbo.ScaleGroups(vCenterName, VMName)
WHERE Status = N'Active';
GO

CREATE TABLE dbo.ScaleEvents
(
    Id bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_ScaleEvents PRIMARY KEY,
    ScaleGroupId bigint NULL,
    vCenterName nvarchar(128) NULL,
    VMName nvarchar(256) NULL,
    EventType nvarchar(64) NOT NULL,
    OldCPU int NULL,
    NewCPU int NULL,
    AlertTime datetime2(0) NULL,
    EventTime datetime2(0) NOT NULL CONSTRAINT DF_ScaleEvents_EventTime DEFAULT (sysdatetime()),
    Status nvarchar(64) NOT NULL,
    Message nvarchar(2000) NULL,
    ErrorDetails nvarchar(max) NULL,
    CONSTRAINT FK_ScaleEvents_ScaleGroups FOREIGN KEY (ScaleGroupId) REFERENCES dbo.ScaleGroups(Id),
    CONSTRAINT CK_ScaleEvents_EventType CHECK (EventType IN (N'Poller', N'ScaleUp', N'ScaleDown', N'Recovery', N'Skip', N'Error')),
    CONSTRAINT CK_ScaleEvents_Status CHECK (Status IN (N'Succeeded', N'Failed', N'Skipped', N'PendingManualReview'))
);
GO

CREATE TABLE dbo.OperationLogs
(
    Id bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_OperationLogs PRIMARY KEY,
    RunId uniqueidentifier NOT NULL,
    vCenterName nvarchar(128) NULL,
    VMName nvarchar(256) NULL,
    Level nvarchar(32) NOT NULL,
    Step nvarchar(128) NOT NULL,
    Message nvarchar(2000) NOT NULL,
    Details nvarchar(max) NULL,
    CreatedAt datetime2(0) NOT NULL CONSTRAINT DF_OperationLogs_CreatedAt DEFAULT (sysdatetime()),
    CONSTRAINT CK_OperationLogs_Level CHECK (Level IN (N'Info', N'Warning', N'Error'))
);
GO

CREATE TABLE dbo.EmailNotifications
(
    Id bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_EmailNotifications PRIMARY KEY,
    RunId uniqueidentifier NOT NULL,
    vCenterName nvarchar(128) NULL,
    VMName nvarchar(256) NULL,
    Subject nvarchar(500) NOT NULL,
    Body nvarchar(max) NOT NULL,
    Status nvarchar(32) NOT NULL,
    ErrorDetails nvarchar(max) NULL,
    CreatedAt datetime2(0) NOT NULL CONSTRAINT DF_EmailNotifications_CreatedAt DEFAULT (sysdatetime()),
    CONSTRAINT CK_EmailNotifications_Status CHECK (Status IN (N'Sent', N'Failed'))
);
GO

CREATE INDEX IX_AllowedVMs_VM
ON dbo.AllowedVMs(VMName)
INCLUDE (vCenterName, Enabled, MaxCPU, AllowScaleDownPowerOff);
GO

CREATE INDEX IX_ScaleEvents_VM_Time
ON dbo.ScaleEvents(vCenterName, VMName, EventTime DESC);
GO

CREATE INDEX IX_OperationLogs_RunId
ON dbo.OperationLogs(RunId, CreatedAt);
GO
