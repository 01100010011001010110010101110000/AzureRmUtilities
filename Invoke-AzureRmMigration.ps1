function Invoke-AzureRmMigration {
    <#
        .SYNOPSIS 
            Performs, or lists, the changes to be performed during, a migration of Azure VMs from one set of SKUs to another
        .DESCRIPTION
            This function takes a JSON formatted mapping of Azure SKUs into different Azure SKUs, parses all Azure VMs looking for VMs of the old SKUs, and updates their HardwareProfile to utilize the new SKUs
        .PARAMETER Vms
            Virtual machines to resize
        .PARAMETER SkuMapping
            Path to the JSON SKU mapping file
        .NOTES
            VERSION: 1.0.0
            AUTHOR: Tyler Gregory <tyler.gregory@dvn.com>
    #>
    [cmdletbinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory = $false, ValueFromPipeline)]
        [Microsoft.Azure.Commands.Compute.Models.PSVirtualMachine[]]
        $Vms,

        [Parameter(Mandatory = $false)]
        $SkuMapping = '/Users/tgregory/Downloads/sku-mapping.json'
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

        $ResourceGroupBlacklist = @('databricks', 'oracle', 'azunac', 'citrix', 'domaincontroller')
        $VMNameBlacklist = @('azunac', 'azumsmgbk', 'azumsdbsq005s', 'azumsmgsm501p', 'srwhp0004', 'azumsdbsq090p', 'aks-agentpool', 'softnas', 'msadrw')

        $skuMap = @{}
        $skuMapCustomObject = Get-Content $SkuMapping | ConvertFrom-Json
        $skuMapCustomObject.psobject.properties | ForEach-Object { $skumap[$_.Name.ToLower()] = $_.Value.ToLower() }
        $collectedVms = @()
    }
    
    Process {
        $collectedVms += $vms
    }
    
    End {
        $subscriptionGroups = $collectedVms | Group-Object { $_.Id.Split('/')[2] }
        $count = 1
        foreach ($group in $subscriptionGroups) {
            $jobs = @()
            Write-Progress -Activity 'Resizing VMs' -Status $group.Name -PercentComplete $($count / $subscriptionGroups.Count * 100)
            Set-AzureRmContext -SubscriptionId $group.Name | Out-Null
            foreach ($vm in $group.Group) {
                if (($VMNameBlacklist | Where-Object { $vm.Name -match $_ }).Count -ne 0 -or ($ResourceGroupBlacklist | Where-Object { $vm.ResourceGroupName -match $_ }).Count -ne 0) { continue; }
                elseif ($WhatIfPreference) {
                    $newsku = $skuMap[$vm.HardwareProfile.VmSize.tolower()]
                    if($null -ne $newsku){
                        Write-Output $([pscustomobject]@{
                            Subscription  = $vm.id.split('/')[2]
                            ResourceGroup = $vm.ResourceGroupName
                            Location      = $vm.Location
                            VM            = $vm.Name
                            CurrentSKU    = $vm.HardwareProfile.VmSize
                            NewSKU        = $newsku
                        })
                    }
                }
                else {
                    $newsku = $skuMap[$vm.HardwareProfile.VmSize.tolower()]
                    if ($null -ne $newsku) {
                        $vm.HardwareProfile.VmSize = $newsku
                        $job = Start-ThreadJob -ScriptBlock {PARAM($vm)
                            Stop-AzureRmVM -Name $vm.Name -ResourceGroupName $vm.ResourceGroupName -Confirm:$false -Force
                            Update-AzureRmVm -VM $vm -ResourceGroupName $vm.ResourceGroupName -Confirm:$false
                            Start-AzureRmVM -Name $vm.Name -ResourceGroupName $vm.ResourceGroupName -Confirm:$false
                        } -ThrottleLimit 30 -ArgumentList $vm
                        $jobs += $job
                    }
                }
            }
            $jobs | Wait-Job
            write-output $jobs
            $count = $count + 1
        }
        Set-AzureRmContext -Context $context | Out-Null
    }   
}
