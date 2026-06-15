@{
    Database = @{
        Server   = 'YOUR_SQL_SERVER_NAME'
        Name     = 'VMCPUAutoScale'
        Username = 'svc_vm_cpu_autoscale'
        Password = 'YOUR_DB_PASSWORD_HERE'
    }

    vCenter = @{
        Username = 'your-service-account@your-domain.com'
        Password = 'YOUR_VCENTER_PASSWORD_HERE'
    }
}
