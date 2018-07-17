$platform = [Environment]::OSVersion.Platform
if ($platform -ne 'Win32NT') {
    Import-Module AzureRM.Netcore
}
else {
    Import-Module AzureRM
    Import-Module Azure.Storage
}

$scriptBlock = {
    Param(
        $Days,
        $VM
    )
    function Get-DownTime {
        <#
        .SYNOPSIS
            Calculate the number of minutes deallocated over a period of days for a given Azure VM
        #>
        Param(
            # The number of days over which to calculate deallocated time
            [Parameter(Mandatory = $false, Position = 0)]
            [int]
            $Days = 1,
    
            # The VM
            [Parameter(Mandatory = $true, Position = 1)]
            [Microsoft.Azure.Commands.Compute.Models.PSVirtualMachine]
            $VM
        )
    
        $allocated = 'stopped|running|stopping|deallocating'
        $deallocated = 'deallocated'
    
        $now = Get-Date
        $logStart = $now.AddDays( - $Days)
        $minutesDeallocated = 60 * 24 * $Days
        $events = Get-AzureRmLog -ResourceId $vm.Id -StartTime $logStart -WarningAction SilentlyContinue |
            Sort-Object -Property EventTimestamp -Descending |
            Where-Object { $_.OperationName.Value -imatch 'start|deallocate' -and $_.Status.Value -imatch 'succeeded' }
        $events | ForEach-Object { Write-Verbose "$($_.EventTimestamp) - $($_.OperationName.Value) - $($_.Status.Value)" }
        $currentPowerState = $($vm | Get-AzureRmVm -Status).Statuses | Where-Object { $_.Code -imatch 'PowerState'}
    
        if ($events.Count -eq 0) {
            if ($currentPowerState.Code -imatch $allocated) { return 0 }
            else { return $minutesDeallocated }
        }
        if ($currentPowerState.Code -imatch $deallocated) { return -1 }
    
        $downIntervals = @()
        $count = 0
        
        Write-Verbose ($now - $events[0].EventTimestamp).TotalMinutes
        $minutesDeallocated = $minutesDeallocated - ($now - $events[0].EventTimestamp).TotalMinutes
    
        foreach ($event in $events) {
            if ($event.OperationName.Value -imatch 'deallocate') { 
                if ($count + 1 -ge $events.Count) { 
                    $minutesDeallocated = $minutesDeallocated - ($event.EventTimestamp - $logStart).TotalMinutes
                    Write-Verbose ($event.EventTimestamp - $logStart).TotalMinutes
                }
                else { 
                    $minutesDeallocated = $minutesDeallocated - ($event.EventTimestamp - $events[$count + 1].EventTimestamp).TotalMinutes 
                    Write-Verbose ($event.EventTimestamp - $events[$count + 1].EventTimestamp).TotalMinutes
                }
            }
            $count++
        }
    
        return [PSCustomObject]@{ MinutesDeallocated = $minutesDeallocated; VM = $VM; Events = $events }
    }

    $ThreadID = [appdomain]::GetCurrentThreadId()
    Write-Verbose "Thread ID: $ThreadID"
    Write-Verbose $vm.Name
    return Get-DownTime -Days $Days -VM $VM
}

function Get-AzureRmVmIdleStatistics {
    <#
        .SYNOPSIS 
            Calculates statistics on the amount of time all VMs in a subscription have been idle
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
        [Parameter(Mandatory = $false)]
        [string]
        $Subscription = '57b58a4d-3dcc-4953-b123-a66ee909a575',

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
            $subscriptions = @($(Get-AzureRmSubscription -SubscriptionId $Subscription))
        }
        $initialContext = Get-AzureRmContext
        $initialErrorPreference = $ErrorActionPreference
        $ErrorActionPreference = "Stop"
        $Date = Get-Date
        $DaysInMonth = [DateTime]::DaysInMonth($Date.Year, $Date.Month)

        # Setup Runspace pool
        [runspacefactory]::CreateRunspacePool() | Out-Null
        $SessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        $RunspacePool = [runspacefactory]::CreateRunspacePool(1, [System.Environment]::ProcessorCount * 2)
        $RunspacePool.Open() | Out-Null
        $jobs = @()
    }

    Process {
        (Set-AzureRmContext -Subscription $Subscription).Subscription.Name | Write-Verbose
        $vms = Get-AzureRmVM | Select-Object -First 5
        foreach ($vm in $vms) {
            $PowerShell = [powershell]::Create()
            $PowerShell.RunspacePool = $RunspacePool
            $PowerShell.AddScript($scriptBlock) | Out-Null
            $PowerShell.AddArgument(1) | Out-Null
            $PowerShell.AddArgument($vm) | Out-Null

            # Write-Host (Get-DownTime -Days 1 -VM $vm)
            $handle = $PowerShell.BeginInvoke()

            $temp = [PSCustomObject]@{ PowerShell = $PowerShell; Handle = $handle }
            $jobs += $temp
        }
        while ($jobs.Handle.IsCompleted -contains $false) { 
            $jobStatus = $jobs.Handle.IsCompleted | group | ForEach-Object { $h = @{'True'=0;'False'=0} } { $h[$_.Name] = $_.Count } { $h }
            Write-Progress -Activity 'Polling Power Events' -PercentComplete (($jobStatus.True / $jobs.Count) * 100)
        }
        $results = $jobs | ForEach-Object {
            $_.PowerShell.EndInvoke($_.Handle)
            $_.PowerShell.Dispose()
        }
        $jobs.Clear()
        Write-Output $results
    }

    End {
        Set-AzureRmContext -Context $initialContext | Write-Debug
        $ErrorActionPreference = $initialErrorPreference
    }
}