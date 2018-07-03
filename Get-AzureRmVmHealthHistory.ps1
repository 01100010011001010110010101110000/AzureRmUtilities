$platform = [Environment]::OSVersion.Platform
if ($platform -ne 'Win32NT') {
    Import-Module AzureRM.Netcore
}
else {
    Import-Module AzureRM
    Import-Module Azure.Storage
}

function Get-AzureRmVmHealthHistory {
    Param(
        [Parameter(Mandatory = $false)]
        [string]
        $SubscriptionId = (Get-AzureRmContext).Id,

        [Parameter(Mandatory = $false)]
        [switch]
        $AllSubscriptions
    )

    Begin {
        $subscriptions = @()
        if ($AllSubscriptions) {
            $subscriptions = Get-AzureRmSubscription
        }
        else {
            $subscriptions = @($(Get-AzureRmSubscription -SubscriptionId $SubscriptionId))
        }
        $initialContext = Get-AzureRmContext
        $initialErrorPreference = $ErrorActionPreference
        $ErrorActionPreference = "Stop"
        $apiVersion = '2015-01-01'
    }

    Process {
        foreach ($subscription in $subscriptions) {
            $context = Set-AzureRmContext -SubscriptionObject $Subscription
            $vms = Get-AzureRmVM
            $token = $context.TokenCache.ReadItems()[0].AccessToken
            $authHeader = @{
                'Content-Type'  = 'application/json'
                'Accept'        = 'application/json'
                'Authorization' = 'Bearer ' + $token
            }
            Write-Verbose "OAuth2 Access Token: $token"

            $processed = 0
            foreach ($vm in $vms) {
                Write-Progress -Activity 'Fetching health history' -PercentComplete (($processed / $vms.Count) * 100) -CurrentOperation $vm.Name
                try {
                    $history = Invoke-RestMethod -Uri "https://management.azure.com/$($vm.Id)/Providers/Microsoft.ResourceHealth/availabilityStatuses?api-version=$apiVersion" -Headers $authHeader
                }
                catch {
                    if ($_.Exception.Response.Code -eq 429) {
                        # We have exceeded the maximum number of requests allowed
                        Write-Verbose "VERBOSE: Encountered request limit, sleeping for $($_.Exception.Response.Headers.RetryAfter)"
                        sleep $_.Exception.Response.Headers.RetryAfter
                        $history = Invoke-RestMethod -Uri "https://management.azure.com/$($vm.Id)/Providers/Microsoft.ResourceHealth/availabilityStatuses?api-version=$apiVersion" -Headers $authHeader
                    }
                }
                Write-Output $history.Value
                $processed += 1
            }
        }
    }

    End {
        Set-AzureRmContext -Context $initialContext | Write-Verbose
        $ErrorActionPreference = $initialErrorPreference
    }
}
