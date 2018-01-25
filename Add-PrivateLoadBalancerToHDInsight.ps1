$platform = [Environment]::OSVersion.Platform
if ($platform -ne 'Win32NT') {
    Import-Module AzureRM.Netcore
}
else {
    Import-Module AzureRM
}
function Add-PrivateLoadBalancerToHDInsight {
    <#
        .SYNOPSIS 
            Creates an internal load balancer for an HDInsight cluster
        .DESCRIPTION
            This will create an internal load balancer for an HDInsight cluster in the same resource group as the vNet it is attached to.
            It does this by creating an internal load balancer and adding its address pool to the headnode network interfaces of 
            the specified cluster.
        .EXAMPLE
        .NOTES
            VERSION: 0.1.0
            AUTHOR: Tyler Gregory <tdgregory@protonmail.com>
        .INPUTS
            Parameter 'Cluster' takes 'Microsoft.Azure.Commands.HDInsight.Models.AzureHDInsightCluster'
        .OUTPUTS
            Microsoft.Azure.Commands.Network.Models.PSLoadBalancer
    #>
    Param(
        # HDInsight Cluster
        [Parameter(Mandatory = $true)]
        [Microsoft.Azure.Commands.HDInsight.Models.AzureHDInsightCluster]
        $Cluster
    )

    $publicIp = Get-AzureRmPublicIpAddress | Where-Object { $_.DnsSettings.DomainNameLabel -eq $Cluster.Name }
    $clusterId = $publicIp.Id.split('/')[-1].split('-')[-1]

    $gatewayNics = Get-AzureRmNetworkInterface | Where-Object { $_.Name -like "*gateway*$clusterId" } # Ambari 443
    $headNics = Get-AzureRmNetworkInterface | Where-Object { $_.Name -like "*headnode*$clusterId" } # Ambari 8080
    $subnet = $headNics[0].IpConfigurations[0].Subnet
    $vNet = Get-AzureRmVirtualNetwork -ResourceGroupName $subnet.Id.split('/')[4] -Name $subnet.Id.split('/')[8]

    $frontendIPConfig = New-AzureRmLoadBalancerFrontendIpConfig -Subnet $subnet -Name 'hdi-private-gateway'
    $headPool = New-AzureRmLoadBalancerBackendAddressPoolConfig -Name "hdi-headnode-private-pool"
    $httpProbe = New-AzureRmLoadBalancerProbeConfig -Name "TCP" -Port 8080 -IntervalInSeconds 5 -ProbeCount 2 -Protocol Tcp
    $httpRule = New-AzureRmLoadBalancerRuleConfig -Name "HTTP" -FrontendIpConfiguration $frontendIPConfig `
        -BackendAddressPool $headPool -Probe $httpProbe -Protocol Tcp -FrontendPort 8080 -BackendPort 8080

    $privateLb = New-AzureRmLoadBalancer -ResourceGroupName $vNet.ResourceGroupName -Name "$clusterId-private-lb" `
        -BackendAddressPool $headPool -FrontendIpConfiguration $frontendIPConfig -Probe $httpProbe `
        -Location $headNics[0].Location -LoadBalancingRule $httpRule

    $privateLb | Add-AzureRmLoadBalancerProbeConfig -Port 22 -Name 'SSH' -Protocol Tcp -IntervalInSeconds 5 -ProbeCount 2 | Set-AzureRmLoadBalancer | Out-Null
    $sshProbe = $privateLb.Probes | Where-Object { $_.Name -eq 'SSH' }
    $headPoolObj = $privateLb.BackendAddressPools | Where-Object { $_.Name -eq 'hdi-headnode-private-pool' }
    $privateLb | Add-AzureRmLoadBalancerRuleConfig -BackendAddressPool $headPoolObj -Probe $sshProbe -Name 'SSH' `
        -FrontendIpConfiguration $frontendIPConfig -Protocol Tcp -FrontendPort 22 `
        -BackendPort 22 -LoadDistribution SourceIPProtocol | Set-AzureRmLoadBalancer | Out-Null

    Write-Output $privateLb

    foreach ($nic in $headNics) {
        $nic.IpConfigurations[0].LoadBalancerBackendAddressPools.Add($headPool)
        $nic | Set-AzureRmNetworkInterface | Out-Null
    }
}