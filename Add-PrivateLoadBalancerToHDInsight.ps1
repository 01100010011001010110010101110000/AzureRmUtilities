function Add-PrivateLoadBalancerToHDInsight {
    <#
        .SYNOPSIS 
            Creates an internal load balancer for an HDInsight cluster
        .DESCRIPTION
            This will create an internal load balancer for an HDInsight cluster in the same resource group as the vNet it is attached to.
            It does this by creating an internal load balancer and adding its address pool to the headnode network interfaces of 
            the specified cluster.
        .EXAMPLE
            Add-PrivateLoadBalancerToHDInsight -Cluster (Get-AzureRmHDInsightCluster -ResourceGroupName HDIDev -ClusterName HDICluster1)

            Make sure you are connected to Azure and are in the proper subscription for the
            HDI cluster. Running this command will create an internal load balancer for the
            HDICluster1 cluster in the HDIDev resource group.
        .EXAMPLE
            $cluster = Get-AzureRmHDInsightCluster -ResourceGroupName HDIDev -ClusterName HDICluster1
            Add-PrivateLoadBalancerToHDInsight -Cluster $cluster -Verbose

            Make sure you are connected to Azure and are in the proper subscription for the
            HDI cluster. The first command will get the object for the HDInsight cluster
            and store it in the $cluster variable. The second command will use this
            variable as the Cluster parameter to create an internal load balancer for the
            HDICluster1 cluster in the HDIDev resource group.
        .NOTES
            VERSION: 0.1.1
            AUTHOR: Tyler Gregory <tdgregory@protonmail.com>
            Modified by Steven Judd on 2018/03/12:
                Added CmdletBinding for advanced functions
                Moved Import-Module into the function definition
                Added a check to ensure the AzureRM module is loaded
                Converted the commands with many parameters to use parameter splatting
                Switched commands that were using pipeline to pass objects to commands that use defined parameters
                Added Verbose output to display the steps in the process as they occur
                Added Examples to the help
                Added a Warning notice that setting the load balancer backend address pool for the headnode network interfaces can take a while
                Added the GitHub link to the help text
        .INPUTS
            Parameter 'Cluster' takes 'Microsoft.Azure.Commands.HDInsight.Models.AzureHDInsightCluster'
        .OUTPUTS
            Microsoft.Azure.Commands.Network.Models.PSLoadBalancer
        .LINK
            https://github.com/01100010011001010110010101110000/AzureRmUtilities
    #>
    
    [CmdletBinding()]
    Param(
        # HDInsight Cluster
        [Parameter(Mandatory = $true)]
        [Microsoft.Azure.Commands.HDInsight.Models.AzureHDInsightCluster]
        $Cluster
    )

<#
    #the checks for the AzureRM module may be redundant since the script requires a AzureHDInsightCluster object as a parameter
    if ([Environment]::OSVersion.Platform -eq 'Win32NT') {
        $AzureRmModule = 'AzureRM'
    }
    else {
        $AzureRmModule = 'AzureRM.Netcore'
    }

    Write-Verbose 'Ensure AzureRM module is loaded'
    if (-not(Get-Module -Name $AzureRmModule -ErrorAction SilentlyContinue))
    {
        try
        {
            Import-Module -Name $AzureRmModule
        }
        catch
        {
            throw $_
        }
    }
#>

    Write-Verbose 'Get the Public IP Address object for the cluster'
    $publicIp = Get-AzureRmPublicIpAddress | Where-Object { $_.DnsSettings.DomainNameLabel -eq $Cluster.Name }
    Write-Verbose 'Get the cluster ID for the cluster'
    $clusterId = $publicIp.Id.split('/')[-1].split('-')[-1]

    Write-Verbose 'Get the gateway NICs, headnode NICs, subnet, and Virtual Network for the cluster'
    $networkInterface = Get-AzureRmNetworkInterface
    $gatewayNics = $networkInterface | Where-Object { $_.Name -like "*gateway*$clusterId" } # Ambari 443
    $headNics = $networkInterface | Where-Object { $_.Name -like "*headnode*$clusterId" } # Ambari 8080
    $subnet = $headNics[0].IpConfigurations[0].Subnet
    $vNet = Get-AzureRmVirtualNetwork -ResourceGroupName $subnet.Id.split('/')[4] -Name $subnet.Id.split('/')[8]

    Write-Verbose 'Create the Load Balancer Frontend IP Config for "hdi-private-gateway"'
    $frontendIPConfig = New-AzureRmLoadBalancerFrontendIpConfig -Subnet $subnet -Name 'hdi-private-gateway'
    Write-Verbose 'Create the Load Balancer Backend Address Pool Config for "hdi-headnode-private-pool"'
    $headPool = New-AzureRmLoadBalancerBackendAddressPoolConfig -Name "hdi-headnode-private-pool"

    Write-Verbose 'Create Load Balancer Probe Configuration for HTTP'
    $newLBProbeConfigParams = @{'Name' = 'TCP'
                                'Port' = '8080'
                                'IntervalInSeconds' = '5'
                                'ProbeCount' = '2'
                                'Protocol' =  'Tcp'}
    $httpProbe = New-AzureRmLoadBalancerProbeConfig @newLBProbeConfigParams

    Write-Verbose 'Create Load Balancer Rule Configuration for HTTP'
    $lbRuleParams = @{'Name' = 'HTTP'
                      'FrontendIpConfiguration' = $frontendIPConfig
                      'BackendAddressPool' = $headPool
                      'Probe' = $httpProbe
                      'Protocol' = 'Tcp'
                      'FrontendPort' = '8080'
                      'BackendPort' = '8080'}
    $httpRule = New-AzureRmLoadBalancerRuleConfig @lbRuleParams

    Write-Verbose "Create Load Balancer for $clusterId-private-lb"
    $newLBParams = @{'ResourceGroupName' = $vNet.ResourceGroupName
                     'Name' = "$clusterId-private-lb"
                     'BackendAddressPool' = $headPool
                     'FrontendIpConfiguration' = $frontendIPConfig
                     'Probe' = $httpProbe
                     'Location' = $headNics[0].Location
                     'LoadBalancingRule' = $httpRule}
    $privateLb = New-AzureRmLoadBalancer @newLBParams

    Write-Verbose "Add probe configuration to allow SSH for $clusterId-private-lb"
    $addLBProbeConfigParams = @{'LoadBalancer' = $privateLb
                                'Port' = '22'
                                'Name' = 'SSH'
                                'Protocol' = 'Tcp'
                                'IntervalInSeconds' = '5'
                                'ProbeCount' = '2'}
    $lbProbeConfig = Add-AzureRmLoadBalancerProbeConfig @addLBProbeConfigParams
    Write-Verbose 'Set the Load Balancer to allow SSH probe'
    $null = Set-AzureRmLoadBalancer -LoadBalancer $lbProbeConfig

    Write-Verbose 'Get objects for the SSH probe and the hdi-headnode-private-pool Backend Address Pools'
    $sshProbe = $privateLb.Probes | Where-Object { $_.Name -eq 'SSH' }
    $headPoolObj = $privateLb.BackendAddressPools | Where-Object { $_.Name -eq 'hdi-headnode-private-pool' }

    Write-Verbose 'Add Load Balancer Rule to allow SSH to the hdi-private-gateway'
    $addLBRuleConfigParams = @{'LoadBalancer' = $privateLb
                               'BackendAddressPool' = $headPoolObj
                               'Probe' = $sshProbe
                               'Name' = 'SSH'
                               'FrontendIpConfiguration' = $frontendIPConfig
                               'Protocol' = 'Tcp'
                               'FrontendPort' = '22'
                               'BackendPort' = '22'
                               'LoadDistribution' = 'SourceIPProtocol'}
    $lbRuleConfig = Add-AzureRmLoadBalancerRuleConfig @addLBRuleConfigParams
    Write-Verbose 'Set the Load Balancer to allow SSH to the hdi-private-gateway'
    $null = Set-AzureRmLoadBalancer -LoadBalancer $lbRuleConfig

    Write-Verbose 'Loop through the headnode nics and add the backend address pool for hdi-headnode-private-pool'
    foreach ($nic in $headNics) {
        $nic.IpConfigurations[0].LoadBalancerBackendAddressPools.Add($headPool)
        Write-Verbose "Setting load balancer backend address pool for network interface $($nic.Name)"
        Write-Warning "Setting load balancer backend address pool for network interface $($nic.Name) can take a while. Please wait..."
        $null = Set-AzureRmNetworkInterface -NetworkInterface $nic
    }

    $privateLb
}
