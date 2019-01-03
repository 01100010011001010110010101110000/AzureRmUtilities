Import-Module Az

$subscriptions = Get-AzSubscription

foreach($subscription in $subscriptions) {
    Set-AzContext -SubscriptionObject $subscription | Out-Null
    $accounts = Get-AzStorageAccount
    foreach($account in $accounts) {
        $key = (Get-AzStorageAccountKey -ResourceGroupName $account.ResourceGroupName -AccountName $account.StorageAccountName).Value[0]
        $storageContext = New-AzStorageContext -StorageAccountName $account.StorageAccountName -StorageAccountKey $key
        $containerACLs = Get-AzStorageContainerAcl -Context $storageContext
        Write-Output $containerACLs
    }
}