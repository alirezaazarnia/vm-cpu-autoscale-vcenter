/*
    Creates the SQL Server database, login, and database user for the
    VM CPU Auto Scale solution.

    This is a normal T-SQL script and can be executed directly in SSMS.

    Replace @LoginPassword before execution.
*/

USE [master];
GO

DECLARE @DatabaseName sysname = N'VMCPUAutoScale';
DECLARE @LoginName sysname = N'svc_vm_cpu_autoscale';
DECLARE @LoginPassword nvarchar(256) = N'YOUR_DB_PASSWORD_HERE';

IF DB_ID(@DatabaseName) IS NULL
BEGIN
    DECLARE @createDatabaseSql nvarchar(max) =
        N'CREATE DATABASE [' + REPLACE(@DatabaseName, N']', N']]') + N'];';

    EXEC sys.sp_executesql @createDatabaseSql;
END;

IF SUSER_ID(@LoginName) IS NULL
BEGIN
    DECLARE @createLoginSql nvarchar(max) =
        N'CREATE LOGIN [' + REPLACE(@LoginName, N']', N']]') + N'] ' +
        N'WITH PASSWORD = N''' + REPLACE(@LoginPassword, N'''', N'''''') + N''', ' +
        N'CHECK_POLICY = ON, CHECK_EXPIRATION = OFF;';

    EXEC sys.sp_executesql @createLoginSql;
END;
GO

USE [VMCPUAutoScale];
GO

DECLARE @LoginName sysname = N'svc_vm_cpu_autoscale';

IF USER_ID(@LoginName) IS NULL
BEGIN
    DECLARE @createUserSql nvarchar(max) =
        N'CREATE USER [' + REPLACE(@LoginName, N']', N']]') + N'] ' +
        N'FOR LOGIN [' + REPLACE(@LoginName, N']', N']]') + N'];';

    EXEC sys.sp_executesql @createUserSql;
END;

IF IS_ROLEMEMBER(N'db_datareader', @LoginName) = 0
BEGIN
    DECLARE @addReaderSql nvarchar(max) =
        N'ALTER ROLE [db_datareader] ADD MEMBER [' + REPLACE(@LoginName, N']', N']]') + N'];';

    EXEC sys.sp_executesql @addReaderSql;
END;

IF IS_ROLEMEMBER(N'db_datawriter', @LoginName) = 0
BEGIN
    DECLARE @addWriterSql nvarchar(max) =
        N'ALTER ROLE [db_datawriter] ADD MEMBER [' + REPLACE(@LoginName, N']', N']]') + N'];';

    EXEC sys.sp_executesql @addWriterSql;
END;

DECLARE @grantExecuteSql nvarchar(max) =
    N'GRANT EXECUTE TO [' + REPLACE(@LoginName, N']', N']]') + N'];';

EXEC sys.sp_executesql @grantExecuteSql;
GO
