# TODO replace with Az module
$platform = [Environment]::OSVersion.Platform
if ($platform -ne 'Win32NT') {
    Import-Module AzureRM.Netcore
}
else {
    Import-Module AzureRM
    Import-Module Azure.Storage
}

function Get-AzRiComparison {
    Begin {
        $initialContext = Get-AzureRmContext
    }

    Process {
        $vms = @()
        $vmSzies = Get-AzureRmVMSize -Location westus2
        $subscriptions = Get-AzureRmSubscription
        foreach ($subscription in $subscriptions) {
            Set-AzureRmContext -SubscriptionObject $subscription
            $vms += Get-AzureRmVM
        }
        
    }

    End {
        Set-AzureRmContext -Context $initialContext
    }
    
}