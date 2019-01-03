Import-Module Az

function Copy-AzManagedDisk {
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
    $InitialContext = Get-AzContext

    $DebugPreference = 'Continue'
    $result = Grant-AzDiskAccess -ResourceGroupName $ManagedDisk.ResourceGroupName -DiskName $ManagedDisk.Name -Access 'Read' -DurationInSecond 3600 5>&1
    $DebugPreference = 'SilentlyContinue'
    $sasUri = $result.AccessSAS

    Write-Host $sasUri

    Set-AzContext -SubscriptionId $targetAccount.Id.Split('/')[2] | Out-Null
    $storageAccountKey = Get-AzStorageAccountKey -ResourceGroupName $targetAccount.ResourceGroupName -Name $targetAccount.StorageAccountName
    $storageContext = New-AzStorageContext -StorageAccountName $targetAccount.StorageAccountName -StorageAccountKey $storageAccountKey.Value[0]

    $container = Get-AzStorageContainer $containerName -Context $storageContext -ErrorAction Ignore
    if ($null -eq $container) {
        $container = New-AzStorageContainer $containerName -Context $storageContext
    }
    $blob = Start-AzStorageBlobCopy -AbsoluteUri $sasUri -DestContainer $containerName -DestBlob "$($disk.Name).vhd" -DestContext $storageContext

    Set-AzContext -Context $InitialContext | Out-Null

    Write-Output $blob
}

function Copy-AzUnmanagedDisk {
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

    $InitialContext = Get-AzContext

    Set-AzContext -SubscriptionId $targetAccount.Id.Split('/')[2] | Out-Null

    Set-AzContext -Context $InitialContext | Out-Null
    $storageAccountKey = Get-AzStorageAccountKey -ResourceGroupName $targetAccount.ResourceGroupName -Name $targetAccount.StorageAccountName
    $storageContext = New-AzStorageContext -StorageAccountName $targetAccount.StorageAccountName -StorageAccountKey $storageAccountKey.Value[0]
    $container = Get-AzStorageContainer $containerName -Context $storageContext -ErrorAction Ignore
    if ($null -eq $container) {
        $container = New-AzStorageContainer $containerName -Context $storageContext
    }
}

function Get-AzStorageAccountFromUri {
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
        $InitialContext = Get-AzContext
        if ($SearchAllSubscriptions) {
            $subscriptions = Get-AzSubscription
        }
        else {
            $subscriptions = @((Get-AzContext).Subscription)
        }
    }

    Process {
        $accountName = ([System.Uri]$BlobUri).Host.Split('.')[0]

        foreach ($subscription in $subscriptions) {
            Set-AzContext -SubscriptionId $subscription.Id | Out-Null
            $account = Get-AzStorageAccount | Where-Object { $_.StorageAccountName.toLower() -eq $accountName.ToLower() }
        }
    }

    end {
        Set-AzContext -Context $InitialContext | Out-Null
        Write-Output $account
    }
}

function Move-AzVm {
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
        $Vm,

        [Parameter(Mandatory = $false)]
        [switch]
        $PreserveNetworkInterface,

        [Parameter(Mandatory = $false)]
        [string]
        $TargetAvailabilitySetId = $null,

        # Target Subnet Id
        [Parameter(Mandatory = $true)]
        [string]
        $TargetSubnetId,

        # Target location
        [Parameter(Mandatory = $false)]
        [string]
        $TargetLocation
    )

    Begin {
        $InitialPreference = $ErrorActionPreference
        $ErrorActionPreference = "Stop"
        $InitialAzContext = Get-AzContext

        Set-AzContext -SubscriptionId $TargetSubscriptionId
        $targetSubscription = Get-AzSubscription -SubscriptionId $TargetSubscriptionId
        $targetResourceGroup = Get-AzResourceGroup -Name $TargetResourceGroupName

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
                return $null
            }
        }
        Set-AzContext -Context $InitialAzContext
    }

    Process {
        $sourceSubscription = Get-AzSubscription -SubscriptionId $Vm.Id.Split('/')[2]
        Set-AzContext -SubscriptionId $sourceSubscription.Id

        Stop-AzVM -Name $Vm.Name -ResourceGroupName $Vm.ResourceGroupName -Confirm:$false -ErrorAction Continue
        Remove-AzVM -Name $vm.Name -ResourceGroupName $Vm.ResourceGroupName -Confirm:$false -ErrorAction Continue

        Set-AzContext -SubscriptionId $targetSubscription.Id
        $targetAccount = Get-AzStorageAccount | Where-Object { $_.Location -eq $TargetLocation -and $_.Kind -match 'StorageV2' } | Get-Random
        if ($targetAccount -eq $null) {
            Write-Error "Error copying $($Vm.Name): No storage account in $($Vm.Location)"
            return
        }
        Write-Debug $targetAccount.StorageAccountName
        $copyJobs = @()

        # Copy OS disk to new subscription
        Set-AzContext -SubscriptionId $sourceSubscription.Id
        if ($Vm.StorageProfile.OsDisk.ManagedDisk) {
            $disk = Get-AzDisk -DiskName $Vm.StorageProfile.OsDisk.Name -ResourceGroupName $Vm.ResourceGroupName
            $osBlob = Copy-AzManagedDisk -ManagedDisk $disk -TargetAccount $targetAccount
            $copyJobs += $osBlob
        }
        else {
            $osDiskUri = $Vm.StorageProfile.OsDisk.Vhd.Uri
            $osDiskAccount = Get-AzStorageAccountFromUri -BlobUri $osDiskUri
            $osBlob = Copy-AzUnmanagedDisk -SourceAccount $osDiskAccount -SourceBlobUri $osDiskUri -TargetAccount $targetAccount
            $copyJobs += $osBlob
        }

        # Copy data disks to new subscription
        foreach ($dataDisk in $Vm.StorageProfile.DataDisks) {
            if ($dataDisk.ManagedDisk) {
                $disk = Get-AzDisk -DiskName $dataDisk.Name -ResourceGroupName $Vm.ResourceGroupName
                $blob = Copy-AzManagedDisk -ManagedDisk $disk -TargetAccount $targetAccount
                $copyJobs += $blob
            }
            else {
                $diskUri = $dataDisk.Vhd.Uri
                $diskAccount = Get-AzStorageAccountFromUri -BlobUri $diskUri
                $diskBlob = Copy-AzUnmanagedDisk -SourceAccount $diskAccount -SourceBlobUri $diskUri -TargetAccount $targetAccount
                $copyJobs += $diskBlob
            }
        }
        
        foreach ($job in $copyJobs) {
            $status = $job | Get-AzStorageBlobCopyState
            Write-Debug $status

            while ($status.Status -eq 'Pending') {
                Start-Sleep 30
                $status = $job | Get-AzStorageBlobCopyState
                Write-Debug $status
            }
            if ($status.Status -eq 'Failed') {
                Write-Error "Copy failed for $($Vm.Name) and blob $($blob), manual intervention required for this VM"
                return
            }
        }

        Set-AzContext -SubscriptionId $targetSubscription.Id
        $diskSku = if ($Vm.HardwareProfile.VmSize -match "standard_[a-z]s\d+|[a-z]\d+s.*") { 'Premium_LRS' } Else { 'Standard_LRS' }
        if ($TargetAvailabilitySetId -ne $null -and $TargetAvailabilitySetId -ne '') {
            switch ($vm.StorageProfile.OsDisk.OsType) {
                'Linux' { $newVm = New-AzVMConfig -VMName $Vm.Name -VMSize $Vm.HardwareProfile.VmSize -Tags $Vm.Tags -AvailabilitySetId $TargetAvailabilitySetId }
                'Windows' { $newVm = New-AzVMConfig -VMName $Vm.Name -VMSize $Vm.HardwareProfile.VmSize -LicenseType Windows_Server -Tags $Vm.Tags -AvailabilitySetId $TargetAvailabilitySetId}
                Default { $newVm = New-AzVMConfig -VMName $Vm.Name -VMSize $Vm.HardwareProfile.VmSize -Tags $Vm.Tags -AvailabilitySetId $TargetAvailabilitySetId }
            }
        }
        else {
            switch ($vm.StorageProfile.OsDisk.OsType) {
                'Linux' { $newVm = New-AzVMConfig -VMName $Vm.Name -VMSize $Vm.HardwareProfile.VmSize -Tags $Vm.Tags }
                'Windows' { $newVm = New-AzVMConfig -VMName $Vm.Name -VMSize $Vm.HardwareProfile.VmSize -LicenseType Windows_Server -Tags $Vm.Tags }
                Default { $newVm = New-AzVMConfig -VMName $Vm.Name -VMSize $Vm.HardwareProfile.VmSize -Tags $Vm.Tags }
            }
        }

        if ($PreserveNetworkInterface) {
            Move-AzResource -Confirm:$false -DestinationResourceGroupName $TargetResourceGroupName -DestinationSubscriptionId $targetSubscription.Id -ResourceId ($Vm.NetworkProfile.NetworkInterfaces | ForEach-Object {$_.id})
            $splitNic = $Vm.NetworkProfile.NetworkInterfaces[0].Id.split('/')
            $newNic = Get-AzNetworkInterface -Name $splitNic[8] -ResourceGroupName $TargetResourceGroupName
        }
        else {
            $splitSubnetId = $TargetSubnetId.split('/')
            $subnetResourceGroup = $splitSubnetId[4]
            $subnetVirtualNetworkName = $splitSubnetId[8]
            $targetVirtualNetwork = Get-AzVirtualNetwork -Name $subnetVirtualNetworkName -ResourceGroupName $subnetResourceGroup
            $targetSubnet = $targetVirtualNetwork.Subnets | Where-Object { $_.Id.ToLower() -eq $TargetSubnetId.ToLower() }

            $newNicIpConfig = New-AzNetworkInterfaceIpConfig -Name "$($newVm.Name)-ipConfig" -Subnet $targetSubnet
            $newNic = New-AzNetworkInterface -Name "$($newVm.Name)-nic0" -ResourceGroupName $TargetResourceGroupName -IpConfiguration $newNicIpConfig -Location $TargetLocation
        }

        $osDiskConfig = New-AzDiskConfig -CreateOption Import `
            -SkuName $diskSku `
            -OsType $Vm.StorageProfile.OsDisk.OsType `
            -Location $TargetLocation `
            -DiskSizeGB $vm.StorageProfile.OsDisk.DiskSizeGB `
            -StorageAccountId $targetAccount.Id `
            -SourceUri $osBlob.ICloudBlob.Uri
        $newOsDisk = New-AzDisk -Disk $osDiskConfig -ResourceGroupName $TargetResourceGroupName -DiskName $vm.StorageProfile.OsDisk.Name
        switch ($vm.StorageProfile.OsDisk.OsType) {
            'Linux' { Set-AzVMOSDisk -VM $newVm -ManagedDiskId $newOsDisk.Id -Caching $Vm.StorageProfile.OsDisk.Caching -CreateOption Attach -Linux }
            'Windows' { Set-AzVMOSDisk -VM $newVm -ManagedDiskId $newOsDisk.Id -Caching $Vm.StorageProfile.OsDisk.Caching -CreateOption Attach -Windows }
            Default { Set-AzVMOSDisk -VM $newVm -ManagedDiskId $newOsDisk.Id -Caching $Vm.StorageProfile.OsDisk.Caching -CreateOption Attach -Linux }
        }

        foreach ($dataDisk in $Vm.StorageProfile.DataDisks) {
            $dataDiskBlob = $copyJobs | Where-Object { $_.ICloudBlob.Name.Split('.')[0].toLower() -eq $dataDisk.Name.toLower() }
            $newDiskConfig = New-AzDiskConfig -CreateOption Import `
                -SkuName $diskSku `
                -Location $TargetLocation `
                -DiskSizeGB $dataDisk.DiskSizeGB `
                -StorageAccountId $targetAccount.Id `
                -SourceUri $dataDiskBlob.ICloudBlob.Uri
            $newDataDisk = New-AzDisk -Disk $newDiskConfig -ResourceGroupName $TargetResourceGroupName -DiskName $dataDisk.Name
            Add-AzVMDataDisk -VM $newVm -Lun $dataDisk.Lun -Caching $dataDisk.Caching -ManagedDiskId $newDataDisk.Id -CreateOption Attach
        }
        Add-AzVMNetworkInterface -VM $newVm -Id $newNic.Id

        Write-Output (New-AzVM -ResourceGroupName $TargetResourceGroupName -Location $TargetLocation -VM $newVm)
    }

    End {
        $ErrorActionPreference = $InitialPreference
        Set-AzContext -Context $InitialAzContext
    }
}
