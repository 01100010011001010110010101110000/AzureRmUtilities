<#
.NOTES
	PowerShell controller script written to pass the proper information to Add-PrivateLoadBalancerToHDInsight function
	Version 20180312.1
	Written by Steven Judd on 2018/03/08
	Updated by Steven Judd on 2018/01/12:
        Added parameters for the HDI cluster information
        Added help text
    
    Feature Requests:
        tbd

.SYNOPSIS
    Script to create private load balancer for an HDI cluster
.DESCRIPTION
    Checks to ensure the Add-PrivateLoadBalancerToHDInsight function is loaded
    and if not, tries to load it. The function must be in the same path as this
    script. Then it checks for a connection to AzureRM and tries to connect if
    it is not connected. Then it switches to the subscription specified in the
    parameters. Finally it gets an object for the HDI cluster and passes that
    object to the Add-PrivateLoadBalancerToHDInsight function.
.LINK
	https://github.com/01100010011001010110010101110000/AzureRmUtilities
.PARAMETER ResourceGroupName
    This parameter is the Resource Group of the HDI cluster
    This parameter is required.
.PARAMETER ClusterName
    This parameter is the name of the HDI cluster
    This parameter is required.
.PARAMETER Subscription
    This parameter is the subscription of the HDI cluster
    This parameter is required.
.EXAMPLE
    NewLoadBalancerForInternalHdiCluster.ps1 -ResourceGroupName 'HDIRG' -ClusterName 'HDI01' -Subscription 'TestSub'
    This command will create a private load balancer configuration for the HDI
    cluster "HDI01" in the resource group "HDIRG" for the subscription "TestSub"
#>


param(
    [Parameter(Position=0,Mandatory=$true)]
        [string]$ResourceGroupName,
    [Parameter(Position=1,Mandatory=$true)]
        [string]$ClusterName,
    [Parameter(Position=2,Mandatory=$true)]
        [string]$Subscription
)

Write-Host "Checking the load of the Add-PrivateLoadBalancerToHDInsight function" -ForegroundColor Yellow
if(-not(Get-Command Add-PrivateLoadBalancerToHDInsight -ErrorAction SilentlyContinue))
{
    try
    {
        . "$(Join-Path -Path $(Split-Path -Parent $PSCommandPath) -ChildPath 'Add-PrivateLoadBalancerToHDInsight.ps1')"
        Write-Host "Confirming the load of the Add-PrivateLoadBalancerToHDInsight function" -ForegroundColor Yellow
        Get-Command Add-PrivateLoadBalancerToHDInsight -ErrorAction Stop
    }
    catch
    {
        throw $_
    }
}

#region check to see if connected to Azure and if not initiate a connection
try
{
    Write-Host "Checking connection to AzureRM" -ForegroundColor Yellow
    $AzureContext = Get-AzureRmContext -ErrorAction Stop
    if ($AzureContext.Account.Id -notmatch $env:USERNAME)
    {
        throw "Run Add-AzureRmAccount to login to Azure" #this will move to the Catch block instead of throwing the error message
    }
}
catch
{
    try
    {
        Write-Host "CONNECTING connection to AzureRM" -ForegroundColor Green
        Add-AzureRmAccount -ErrorAction Stop
        $AzureContext = Get-AzureRmContext -ErrorAction Stop
    }
    catch
    {
        throw $_
    }
}
Write-Host "Azure Context: $($AzureContext.Tenant.Id)"
#endregion

Set-AzureRmContext -Subscription $Subscription
try
{
    $cluster = Get-AzureRmHDInsightCluster -ResourceGroupName $ResourceGroupName -ClusterName $ClusterName
    $results = Add-PrivateLoadBalancerToHDInsight -Cluster $cluster -Verbose
    $results #| Select-Object Name,ResourceGroupName,Location,Id,Etag,ResourceGuid,ProvisioningState,Tags
}
catch
{
    throw $_
}