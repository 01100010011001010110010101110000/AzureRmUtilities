function Invoke-AzureRmMigration {
    <#
        .SYNOPSIS 
            Performs, or lists, the changes to be performed during, a migration of Azure VMs from one set of SKUs to another
        .DESCRIPTION
            This function takes a JSON formatted mapping of Azure SKUs into different Azure SKUs, parses all Azure VMs looking for VMs of the old SKUs, and updates their HardwareProfile to utilize the new SKUs
        .PARAMETER AllSubscriptions
            Switches between using only the current Azure subscription or all subscripitons you have access to
        .PARAMETER Limit
            Limits the number of VMs selected,  per subscription if -AllSubscripitons is set
        .PARAMETER SkuMapping
            Path to the JSON SKU mapping file
        .NOTES
            VERSION: 1.0.0
            AUTHOR: Tyler Gregory <tyler.gregory@dvn.com>
    #>
    [cmdletbinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory = $false)]
        [switch]
        $AllSubscriptions,

        [Parameter(Mandatory = $false)]
        $Limit = 0,

        [Parameter(Mandatory = $false)]
        $SkuMapping = '/Users/tgregory/Downloads/sku-mapping.json',

        [Parameter(Mandatory = $false, ValueFromPipeline)]
        [Microsoft.Azure.Commands.Compute.Models.PSVirtualMachine[]]
        $staticVmList
    )
    Begin {
        $platform = [Environment]::OSVersion.Platform
        if ($platform -ne 'Win32NT') {
            Import-Module AzureRM.Netcore
        }
        else {
            Import-Module AzureRM
        }
        $context = Get-AzureRmContext
        if ($AllSubscriptions) {
            $subscriptions = Get-AzureRmSubscription
        }
        else {
            $subscriptions = @($(Get-AzureRmContext).Subscription)
        }
        $ResourceGroupBlacklist = @('databricks', 'oracle', 'azunac', 'citrix', 'domaincontroller')
        $VMNameBlacklist = @('azunac', 'azumsmgbk', 'azumsdbsq005s', 'azumsmgsm501p', 'srwhp0004', 'azumsdbsq090p', 'aks-agentpool', 'softnas', 'msadrw')

        $skuMap = @{}
        $skuMapCustomObject = Get-Content $SkuMapping | ConvertFrom-Json
        $skuMapCustomObject.psobject.properties | ForEach-Object { $skumap[$_.Name.ToLower()] = $_.Value.ToLower() }
        $oldSkus = $skuMap.Keys | ForEach-Object { $_ }
    }
    
    Process {
        $vms = @()
        if ($null -eq $staticVmList) {
            foreach ($subscription in $subscriptions) {
                Set-AzureRmContext -SubscriptionObject $subscription | Out-Null
                if ($Limit -eq 0) {
                    $vms += Get-AzureRmVm | Where-Object { $oldSkus.Contains($_.HardwareProfile.VmSize.ToLower()) }
                }
                else {
                    $vms += Get-AzureRmVm | Where-Object { $oldSkus.Contains($_.HardwareProfile.VmSize.ToLower()) } | Select-Object -First $Limit
                }
            }
        }
        else { $vms = $staticVmList }

        foreach ($vm in $vms) {
            if (($VMNameBlacklist | Where-Object { $vm.Name -match $_ }).Count -ne 0 -or ($ResourceGroupBlacklist | Where-Object { $vm.ResourceGroupName -match $_ }).Count -ne 0) { continue; }
            elseif ($WhatIfPreference) {
                Write-Output $([pscustomobject]@{
                        Subscription  = $vm.id.split('/')[2]
                        ResourceGroup = $vm.ResourceGroupName
                        Location      = $vm.Location
                        VM            = $vm.Name
                        CurrentSKU    = $vm.HardwareProfile.VmSize
                        NewSKU        = $skuMap[$vm.HardwareProfile.VmSize.tolower()]
                    })
            }
            else {
                $jobs = @()
                Set-AzureRmContext -SubscriptionId $vm.id.split('/')[2] | Out-Null
                $newsku = $skuMap[$vm.HardwareProfile.VmSize.tolower()]
                if ($null -ne $newsku) {
                    $vm.HardwareProfile.VmSize = $newsku
                    $jobs += Start-ThreadJob -ScriptBlock {PARAM($vm)
                        Stop-AzureRmVM -Name $vm.Name -ResourceGroupName $vm.ResourceGroupName -Confirm:$false -Force
                        Update-AzureRmVm -VM $vm -ResourceGroupName $vm.ResourceGroupName -Confirm:$false
                        Start-AzureRmVM -Name $vm.Name -ResourceGroupName $vm.ResourceGroupName -Confirm:$false
                    } -ThrottleLimit 30 -ArgumentList $vm
                }
                Write-Output $jobs
            }
        }   
    }
    
    End {
        Set-AzureRmContext -Context $context | Out-Null
    }   
}