$platform = [Environment]::OSVersion.Platform
if ($platform -ne 'Win32NT') {
    Import-Module AzureRM.Netcore
}
else {
    Import-Module AzureRM
    Import-Module Azure.Storage
}

$skuDiskLimits = @{
    'standard_d2s_v3' = @{ 'throughput' = 48; 'iops' = 3200; }
    'standard_d4s_v3' = @{ 'throughput' = 96; 'iops' = 6400; }
    'standard_d8s_v3' = @{ 'throughput' = 192; 'iops' = 12800; }
    'standard_d16s_v3' = @{ 'throughput' = 384; 'iops' = 25600; }
    'standard_d32s_v3' = @{ 'throughput' = 768; 'iops' = 51200; }
    'standard_d64s_v3' = @{ 'throughput' = 1200; 'iops' = 80000; }

    'standard_e2s_v3' = @{ 'throughput' = 48; 'iops' = 3200; }
    'standard_e4s_v3' = @{ 'throughput' = 96; 'iops' = 6400; }
    'standard_e8s_v3' = @{ 'throughput' = 192; 'iops' = 12800; }
    'standard_e16s_v3' = @{ 'throughput' = 384; 'iops' = 25600; }
    'standard_e20s_v3' = @{ 'throughput' = 480; 'iops' = 32000; }
    'standard_e32s_v3' = @{ 'throughput' = 768; 'iops' = 51200; }
    'standard_e64s_v3' = @{ 'throughput' = 1200; 'iops' = 80000; }
    'standard_e64is_v3' = @{ 'throughput' = 1200; 'iops' = 80000; }

    'standard_ds1_v2' = @{ 'throughput' = 48; 'iops' = 3200; }
    'standard_ds2_v2' = @{ 'throughput' = 96; 'iops' = 6400; }
    'standard_ds3_v2' = @{ 'throughput' = 192; 'iops' = 12800; }
    'standard_ds4_v2' = @{ 'throughput' = 384; 'iops' = 25600; }
    'standard_ds5_v2' = @{ 'throughput' = 768; 'iops' = 51200; }

    'standard_ds1_v2_promo' = @{ 'throughput' = 48; 'iops' = 3200; }
    'standard_ds2_v2_promo' = @{ 'throughput' = 96; 'iops' = 6400; }
    'standard_ds3_v2_promo' = @{ 'throughput' = 192; 'iops' = 12800; }
    'standard_ds4_v2_promo' = @{ 'throughput' = 384; 'iops' = 25600; }
    'standard_ds5_v2_promo' = @{ 'throughput' = 768; 'iops' = 51200; }

    'standard_ds11_v2' = @{ 'throughput' = 96; 'iops' = 6400; }
    'standard_ds12_v2' = @{ 'throughput' = 192; 'iops' = 12800; }
    'standard_ds13_v2' = @{ 'throughput' = 384; 'iops' = 25600; }
    'standard_ds14_v2' = @{ 'throughput' = 768; 'iops' = 51200; }
    'standard_ds15_v2' = @{ 'throughput' = 960; 'iops' = 64000; }

    'standard_ds11_v2_promo' = @{ 'throughput' = 96; 'iops' = 6400; }
    'standard_ds12_v2_promo' = @{ 'throughput' = 192; 'iops' = 12800; }
    'standard_ds13_v2_promo' = @{ 'throughput' = 384; 'iops' = 25600; }
    'standard_ds14_v2_promo' = @{ 'throughput' = 768; 'iops' = 51200; }
    'standard_ds15_v2_promo' = @{ 'throughput' = 960; 'iops' = 64000; }
}

function Get-AzureRmVmMaxDiskStats {
    param (
        [Parameter(Mandatory = $true)]
        [Microsoft.Azure.Commands.Compute.Models.PSVirtualMachine]
        $Vm
    )
    # Throughput is in MB/s
    $azureDiskTier = @{
        t4  = @{ 'throughput' = '25'; 'iops' = '120' }
        t6  = @{ 'throughput' = '50'; 'iops' = '240' }
        t10 = @{ 'throughput' = '100'; 'iops' = '500' }
        t15 = @{ 'throughput' = '125'; 'iops' = '1100' }
        t20 = @{ 'throughput' = '150'; 'iops' = '2300' }
        t30 = @{ 'throughput' = '200'; 'iops' = '5000' }
        t40 = @{ 'throughput' = '250'; 'iops' = '7500' }
        t50 = @{ 'throughput' = '250'; 'iops' = '7500' }
    }
    $maxDiskStats = @{'throughput' = 0; 'iops' = 0}
    foreach ($disk in $Vm.StorageProfile.DataDisks) {
        if($null -eq $disk.ManagedDisk) { continue; }
        if($disk.ManagedDisk.StorageAccountType -ieq 'premium_lrs') {
            if($disk.DiskSizeGB -gt 0 -and $disk.DiskSizeGB -le 32) { $maxDiskStats.throughput += $azureDiskTier.t4.throughput; $maxDiskStats.iops += $azureDiskTier.t4.iops}
            elseif($disk.DiskSizeGB -gt 32 -and $disk.DiskSizeGB -le 64) { $maxDiskStats.throughput += $azureDiskTier.t6.throughput; $maxDiskStats.iops += $azureDiskTier.t6.iops}
            elseif($disk.DiskSizeGB -gt 64 -and $disk.DiskSizeGB -le 128) { $maxDiskStats.throughput += $azureDiskTier.t10.throughput; $maxDiskStats.iops += $azureDiskTier.t10.iops}
            elseif($disk.DiskSizeGB -gt 128 -and $disk.DiskSizeGB -le 256) { $maxDiskStats.throughput += $azureDiskTier.t15.throughput; $maxDiskStats.iops += $azureDiskTier.t15.iops}
            elseif($disk.DiskSizeGB -gt 256 -and $disk.DiskSizeGB -le 512) { $maxDiskStats.throughput += $azureDiskTier.t20.throughput; $maxDiskStats.iops += $azureDiskTier.t20.iops}
            elseif($disk.DiskSizeGB -gt 512 -and $disk.DiskSizeGB -le 1024) { $maxDiskStats.throughput += $azureDiskTier.t30.throughput; $maxDiskStats.iops += $azureDiskTier.t30.iops}
            elseif($disk.DiskSizeGB -gt 1024 -and $disk.DiskSizeGB -le 2048) { $maxDiskStats.throughput += $azureDiskTier.t40.throughput; $maxDiskStats.iops += $azureDiskTier.t40.iops}
            elseif($disk.DiskSizeGB -gt 2048 -and $disk.DiskSizeGB -le 4096) { $maxDiskStats.throughput += $azureDiskTier.t50.throughput; $maxDiskStats.iops += $azureDiskTier.t50.iops}
        }
        else { $maxDiskStats.throughput += 60; $maxDiskStats.iops += 500 }
    }
    return $maxDiskStats
}

$context = Get-AzureRmContext
try {
    $vms = @()
    $subscriptions = Get-AzureRmSubscription
    foreach ($subscription in $subscriptions) {
        Set-AzureRmContext -SubscriptionObject $subscription | Out-Null
        $vms += Get-AzureRmVm
    }

    $oldVms = $vms | Where-Object { $_.HardwareProfile.VmSize -match 'standard_ds?\d+_v2|standard_fs?\d+$|standard_ds?\d+$' }

    $skuMap = Get-Content /Users/tgregory/Downloads/sku-mapping.json | ConvertFrom-Json
    $prices = (Get-Content /Users/tgregory/Downloads/tableExport.json | ConvertFrom-Json).data

    $enrichedVms = @()
    foreach ($vm in $oldVms) {
        $oldSku = $vm.HardwareProfile.VmSize.tolower()
        $newsku = $skuMap.$oldSku
        $price = 0
        $newprice = 0
        foreach ($listing in $prices) {
            if ($oldSku -match $listing.'VM Name'.tolower()) { 
                $price = $listing.'Linux price'
                $oldcores = $listing.'# Cores'
                $oldmem = $listing.'Memory (GiB)'
            }
            if ($listing.'VM Name'.tolower() -match $newsku) { 
                $newprice = $listing.'Linux price'
                $newcores = $listing.'# Cores'
                $newmem = $listing.'Memory (GiB)'
            }
        }
        $writeOperations = (Get-AzureRmMetric -ResourceId $vm.Id -MetricName 'Disk Write Operations/Sec' -AggregationType Maximum -StartTime (Get-Date).AddDays(-30) -TimeGrain '00:05:00').Data
        $readOperations = (Get-AzureRmMetric -ResourceId $vm.Id -MetricName 'Disk Read Operations/Sec' -AggregationType Maximum -StartTime (Get-Date).AddDays(-30) -TimeGrain '00:05:00').Data
        $totalOperations = @()
        $index = 0
        foreach($op in $writeOperations) {
            $total = $op.Maximum + $readOperations[$index].Maximum
            $index++
            $totalOperations += $total
        }
        $maximumIOPS = ($totalOperations | Measure-Object -Maximum).Maximum

        $diskCapacity = Get-AzureRmVmMaxDiskStats -Vm $vm
        $enrichedVms += [pscustomobject]@{
            Subscription      = ($subscriptions | Where-Object { $_.Id -eq $vm.Id.split('/')[2] }).Name
            ResourceGroupName = $vm.ResourceGroupName
            Name              = $vm.Name
            OperatingSystem   = $vm.StorageProfile.OsDisk.OsType
            CurrentSKU        = $vm.HardwareProfile.VmSize.tolower()
            NewSKU            = $newsku.tolower()
            CurrentPrice      = $price
            NewPrice          = $newprice
            CurrentCores      = $oldcores
            NewCores          = $newcores
            OldRam            = $oldmem
            NewRam            = $newmem
            MaxDiskThroughput = $diskCapacity.throughput
            MaxDiskIOPS       = $diskCapacity.iops
            OldMaxDiskThroughput = $skuDiskLimits.$oldSku.throughput
            NewMaxDiskThroughput = $skuDiskLimits.$newsku.throughput
            OldMaxDiskIOPS = $skuDiskLimits.$oldSku.iops
            NewMaxDiskIOPS = $skuDiskLimits.$newsku.iops
            Maximum30DaysIOPS = $maximumIOPS
        }
    }
    Write-Output $enrichedVms
}
finally { Set-AzureRmContext -Context $context | Out-Null }