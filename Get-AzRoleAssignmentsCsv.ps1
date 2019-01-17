Import-Module Az

function Get-AzRoleAssignmentsCsv {
    Begin {
        $initialContext = Get-AzContext
        $assignments = @()
        $subscriptions = Get-AzSubscription
    }   
    Process {
        foreach ($subscription in $subscriptions) {
            Set-AzContext -SubscriptionObject $subscription | Out-Null
            foreach ($assignment in $(Get-AzRoleAssignment)) {
                $split = $assignment.Scope.split('/')
                $assignments += [PSCustomObject]@{
                    Scope = $assignment.Scope
                    RoleAssignmentId = $assignment.RoleAssignmentId
                    DisplayName = $assignment.DisplayName
                    SignInName = $assignment.SignInName
                    RoleDefinitionName = $assignment.RoleDefinitionName
                    RoleDefinitionId = $assignment.RoleDefinitionId
                    ObjectType = $assignment.ObjectType
                    CanDelegate = $assignment.CanDelegate
                    SubscriptionId = $split[2]
                    SubscriptionName = ($subscriptions | Where-Object { $_.Id -eq $split[2] }).Name
                    ResourceGroup = $split[4]
                    EntityType = $split[6] + '/' + $split[7]
                    Entity = $split[8]
                }
            }
        }
    }
    End {
        Write-Output $assignments | ConvertTo-Csv
        Set-AzContext -Context $initialContext | Out-Null
    }
}