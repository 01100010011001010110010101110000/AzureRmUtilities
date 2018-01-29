$platform = [Environment]::OSVersion.Platform
if ($platform -ne 'Win32NT') {
    Write-Error "Azure .NET Core modules do not yet support some storage operations necessary for these functions"
    exit
    # Import-Module AzureRM.Netcore
}
else {
    Import-Module AzureRM
    Import-Module Azure.Storage
}

function Copy-AzureRmManagedDisk {
    Param(
        [Parameter(Mandatory = $true)]
        [Microsoft.Azure.Commands.Compute.Automation.Models.PSDisk]
        $ManagedDisk,

        [Parameter(Mandatory = $true)]
        [Microsoft.Azure.Commands.Management.Storage.Models.PSStorageAccount]
        $TargetAccount,

        [Parameter(Mandatory = $false)]
        [string]
        $containerName = 'migrationvhds'
    )
    $InitialContext = Get-AzureRmContext
    $diskToken = Grant-AzureRmDiskAccess -ResourceGroupName $managedDisk.ResourceGroupName -DiskName $managedDisk.Name -Access Read -DurationInSecond (60 * 60 * 12)
    Set-AzureRmContext -SubscriptionId $targetAccount.Id.Split('/')[2] | Out-Null
    $storageAccountKey = Get-AzureRmStorageAccountKey -ResourceGroupName $targetAccount.ResourceGroupName -Name $targetAccount.StorageAccountName
    $storageContext = New-AzureStorageContext -StorageAccountName $targetAccount.StorageAccountName -StorageAccountKey $storageAccountKey.Value[0]

    $container = Get-AzureStorageContainer $containerName -Context $storageContext -ErrorAction Ignore
    if ($container -eq $null) {
        $container = New-AzureStorageContainer $containerName -Context $storageContext
    }
    $blob = Start-AzureStorageBlobCopy -AbsoluteUri $diskToken.AccessSAS -DestContainer $containerName -DestBlob "$($disk.Name).vhd" -DestContext $storageContext

    Set-AzureRmContext -Context $InitialContext | Out-Null

    Write-Output $blob
}

function Copy-AzureRmUnmanagedDisk {
    Param(
        # Source Storage Account
        [Parameter(Mandatory = $true)]
        [Microsoft.Azure.Commands.Management.Storage.Models.PSStorageAccount]
        $SourceAccount,

        # Source VHD Uri
        [Parameter(Mandatory = $true)]
        [string]
        $SourceBlobUri,

        # Target Storage Account
        [Parameter(Mandatory = $true)]
        [Microsoft.Azure.Commands.Management.Storage.Models.PSStorageAccount]
        $TargetAccount
    )

    $InitialContext = Get-AzureRmContext

    Set-AzureRmContext -SubscriptionId $targetAccount.Id.Split('/')[2] | Out-Null

    Set-AzureRmContext -Context $InitialContext | Out-Null
    $storageAccountKey = Get-AzureRmStorageAccountKey -ResourceGroupName $targetAccount.ResourceGroupName -Name $targetAccount.StorageAccountName
    $storageContext = New-AzureStorageContext -StorageAccountName $targetAccount.StorageAccountName -StorageAccountKey $storageAccountKey.Value[0]
    $container = Get-AzureStorageContainer $containerName -Context $storageContext -ErrorAction Ignore
    if ($container -eq $null) {
        $container = New-AzureStorageContainer $containerName -Context $storageContext
    }
}

function Get-AzureRmStorageAccountFromUri {
    Param(
        # Blob Uri
        [Parameter(ValueFromPipeline = $true)]
        [string]
        $BlobUri,

        # Whether to search for accounts in all subscriptions
        [Parameter(Mandatory = $false)]
        [switch]
        $SearchAllSubscriptions
    )
    Begin {
        $InitialContext = Get-AzureRmContext
        if ($SearchAllSubscriptions) {
            $subscriptions = Get-AzureRmSubscription
        }
        else {
            $subscriptions = @((Get-AzureRmContext).Subscription)
        }
    }

    Process {
        $accountName = ([System.Uri]$BlobUri).Host.Split('.')[0]
        
        foreach ($subscription in $subscriptions) {
            Set-AzureRmContext -SubscriptionId $subscription.Id | Out-Null
            $account = Get-AzureRmStorageAccount | Where-Object { $_.StorageAccountName.toLower() -eq $accountName.ToLower() }
        }
    }

    end {
        Set-AzureRmContext -Context $InitialContext | Out-Null
        Write-Output $account
    }
}

function Move-AzureRmVm {
    <#
        .SYNOPSIS 
            Moves a VM from one resource group into another in the same subscription or into another in a new subscription
        .DESCRIPTION
        .EXAMPLE
        .SYNTAX
        .NOTES
            VERSION: 0.0.1
            AUTHOR: Tyler Gregory <tdgregory@protonmail.com>

        .PARAMETER
        .INPUTS
        .OUTPUTS
    #>
    Param(
        [Parameter(Mandatory = $true)]
        [string]
        $TargetSubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]
        $TargetResourceGroupName,

        [Parameter(ValueFromPipeline = $true)]
        [Microsoft.Azure.Commands.Compute.Models.PSVirtualMachine[]]
        $Vm
    )

    Begin {
        $InitialPreference = $ErrorActionPreference
        $ErrorActionPreference = "Stop"
        $InitialAzureRmContext = Get-AzureRmContext

        Set-AzureRmContext -SubscriptionId $TargetSubscriptionId
        $targetSubscription = Get-AzureRmSubscription -SubscriptionId $TargetSubscriptionId
        $targetResourceGroup = Get-AzureRmResourceGroup -Name $TargetResourceGroupName

        # Confirm that we want to be doing this
        $title = "Migrate Virtual Machine"
        $message = "Do you want to migrate all virtual machines passed to this function to $($targetResourceGroup.Name) in $($targetSubscription.Name)?`nThis will require downtime"
        $yes = New-Object System.Management.Automation.Host.ChoiceDescription "&Yes", "Migrate all virtual machines"
        $no = New-Object System.Management.Automation.Host.ChoiceDescription "&No", "Leaves virtual machines where they are"
        $options = [System.Management.Automation.Host.ChoiceDescription[]]($yes, $no)
        $result = $host.ui.PromptForChoice($title, $message, $options, 1) 
        switch ($result) {
            0 { Write-Verbose "Migrating VMs" }
            1 {
                Write-Verbose "Leaving VMs where they are"
                exit 0
            }
        }
        Set-AzureRmContext -Context $InitialAzureRmContext
    }

    Process {
        $sourceSubscription = Get-AzureRmSubscription -SubscriptionId $Vm.Id.Split('/')[2]
        Set-AzureRmContext -SubscriptionId $sourceSubscription.Id
        Stop-AzureRmVM -Name $Vm.Name -ResourceGroupName $Vm.ResourceGroupName -Confirm:$false

        Set-AzureRmContext -SubscriptionId $targetSubscription.Id
        $targetAccount = Get-AzureRmStorageAccount | Where-Object { $_.Location -eq $Vm.Location } | Out-GridView -Title 'Select target storage account' -OutputMode Single
        if ($targetAccount -eq $null) {
            Write-Error "Error copying $($Vm.Name): No storage account in $($Vm.Location)"
            return
        }
        Write-Debug $targetAccount.StorageAccountName
        $copyJobs = @()
        
        # Copy OS disk to new subscription
        Set-AzureRmContext -SubscriptionId $sourceSubscription.Id
        if ($Vm.StorageProfile.OsDisk.ManagedDisk) {
            $disk = Get-AzureRmDisk -DiskName $Vm.StorageProfile.OsDisk.Name -ResourceGroupName $Vm.ResourceGroupName
            $osBlob = Copy-AzureRmManagedDisk -ManagedDisk $disk -TargetAccount $targetAccount
            $copyJobs += $osBlob
        }
        else {
            $osDiskUri = $Vm.StorageProfile.OsDisk.Vhd.Uri
            $osDiskAccount = Get-AzureRmStorageAccountFromUri -BlobUri $osDiskUri
            $osBlob = Copy-AzureRmUnmanagedDisk -SourceAccount $osDiskAccount -SourceBlobUri $osDiskUri -TargetAccount $targetAccount
            $copyJobs += $osBlob
        }

        # Copy data disks to new subscription
        foreach ($dataDisk in $Vm.StorageProfile.DataDisks) {
            if ($dataDisk.ManagedDisk) {
                $disk = Get-AzureRmDisk -DiskName $dataDisk.Name -ResourceGroupName $Vm.ResourceGroupName
                $blob = Copy-AzureRmManagedDisk -ManagedDisk $disk -TargetAccount $targetAccount
                $copyJobs += $blob
            }
            else {
                $diskUri = $dataDisk.Vhd.Uri
                $diskAccount = Get-AzureRmStorageAccountFromUri -BlobUri $diskUri
                $diskBlob = Copy-AzureRmUnmanagedDisk -SourceAccount $diskAccount -SourceBlobUri $diskUri -TargetAccount $targetAccount
                $copyJobs += $diskBlob
            }
        }

        foreach ($job in $copyJobs) {
            $status = $job | Get-AzureStorageBlobCopyState
            Write-Debug $status

            while ($status.Status -eq 'Pending') {
                Start-Sleep 30
                $status = $job | Get-AzureStorageBlobCopyState
                Write-Debug $status
            }
            if ($status.Status -eq 'Failed') {
                Write-Error "Copy failed for $($Vm.Name) and blob $($blob), manual intervention required for this VM"
                return
            }
        }

        Set-AzureRmContext -SubscriptionId $targetSubscription.Id
        $diskSku = if ($Vm.HardwareProfile.VmSize -match "standard_[a-z]s\d+|[a-z]\d+s.*") { 'PremiumLRS' } Else { 'StandardLRS' }
        switch ($vm.StorageProfile.OsDisk.OsType) {
            'Linux' { $newVm = New-AzureRmVMConfig -VMName $Vm.Name -VMSize $Vm.HardwareProfile.VmSize -Tags $Vm.Tags }
            'Windows' { $newVm = New-AzureRmVMConfig -VMName $Vm.Name -VMSize $Vm.HardwareProfile.VmSize -LicenseType Windows_Server -Tags $Vm.Tags }
            Default { $newVm = New-AzureRmVMConfig -VMName $Vm.Name -VMSize $Vm.HardwareProfile.VmSize -Tags $Vm.Tags }
        }
    
        $targetNetwork = Get-AzureRmVirtualNetwork | Where-Object { $_.Location -eq $Vm.Location }
        $targetSubnet = $targetNetwork.Subnets | Out-GridView -Title 'Select the desired subnet' -OutputMode Single

        $newNicIpConfig = New-AzureRmNetworkInterfaceIpConfig -Name "$($newVm.Name)-ipConfig" -Subnet $targetSubnet
        $newNic = New-AzureRmNetworkInterface -Name "$($newVm.Name)-nic0" -ResourceGroupName $TargetResourceGroupName -IpConfiguration $newNicIpConfig -Location $Vm.Location

        $osDiskConfig = New-AzureRmDiskConfig -CreateOption Import `
            -SkuName $diskSku `
            -OsType $Vm.StorageProfile.OsDisk.OsType `
            -Location $Vm.Location `
            -DiskSizeGB $vm.StorageProfile.OsDisk.DiskSizeGB `
            -StorageAccountId $targetAccount.Id `
            -SourceUri $osBlob.ICloudBlob.Uri
        $newOsDisk = New-AzureRmDisk -Disk $osDiskConfig -ResourceGroupName $TargetResourceGroupName -DiskName $vm.StorageProfile.OsDisk.Name
        switch ($vm.StorageProfile.OsDisk.OsType) {
            'Linux' { Set-AzureRmVMOSDisk -VM $newVm -ManagedDiskId $newOsDisk.Id -Caching $Vm.StorageProfile.OsDisk.Caching -CreateOption Attach -Linux }
            'Windows' { Set-AzureRmVMOSDisk -VM $newVm -ManagedDiskId $newOsDisk.Id -Caching $Vm.StorageProfile.OsDisk.Caching -CreateOption Attach -Windows }
            Default { Set-AzureRmVMOSDisk -VM $newVm -ManagedDiskId $newOsDisk.Id -Caching $Vm.StorageProfile.OsDisk.Caching -CreateOption Attach -Linux }
        }
        
        
        foreach ($dataDisk in $Vm.StorageProfile.DataDisks) {
            $dataDiskBlob = $copyJobs | Where-Object { $_.ICloudBlob.Name.Split('.')[0].toLower() -eq $dataDisk.Name.toLower() }
            $newDiskConfig = New-AzureRmDiskConfig -CreateOption Import `
                -SkuName $diskSku `
                -Location $Vm.Location `
                -DiskSizeGB $dataDisk.DiskSizeGB `
                -StorageAccountId $targetAccount.Id `
                -SourceUri $dataDiskBlob.ICloudBlob.Uri
            $newDataDisk = New-AzureRmDisk -Disk $newDiskConfig -ResourceGroupName $TargetResourceGroupName -DiskName $dataDisk.Name
            Add-AzureRmVMDataDisk -VM $newVm -Lun $dataDisk.Lun -Caching $dataDisk.Caching -ManagedDiskId $newDataDisk.Id -CreateOption Attach
        }
        Add-AzureRmVMNetworkInterface -VM $newVm -Id $newNic.Id

        Write-Output (New-AzureRmVM -ResourceGroupName $TargetResourceGroupName -Location $Vm.Location -VM $newVm)
    }

    End {
        $ErrorActionPreference = $InitialPreference
        Set-AzureRmContext -Context $InitialAzureRmContext
    }
}
