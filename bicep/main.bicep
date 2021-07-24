param location string = resourceGroup().location

@minLength(3)
@maxLength(20)
@description('Used to name all resources')
param resourceName string

//------------------------------------------------------------------------------------------------- Network
param custom_vnet bool = false
param byoAKSSubnetId string = ''
param byoAGWSubnetId string = ''

//--- Custom or BYO networking requires BYO AKS User Identity
//--------------------------------------------- User Identity
var aks_byo_identity = custom_vnet || !empty(byoAKSSubnetId)
resource uai 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' = if (aks_byo_identity) {
  name: 'id-${resourceName}'
  location: location
}

//----------------------------------------------------- BYO
var existingAksVnetRG = !empty(byoAKSSubnetId) ? (length(split(byoAKSSubnetId, '/')) > 9 ? split(byoAKSSubnetId, '/')[4] : '') : ''

module aksnetcontrib './aksnetcontrib.bicep' = if (!empty(byoAKSSubnetId)) {
  name: 'addAksNetContributor'
  scope: resourceGroup(existingAksVnetRG)
  params: {
    byoAKSSubnetId: byoAKSSubnetId
    user_identity_principalId: uai.properties.principalId
    user_identity_name: uai.name
    user_identity_rg: resourceGroup().name
  }
}

var existingAGWSubnetName = !empty(byoAGWSubnetId) ? (length(split(byoAGWSubnetId, '/')) > 10 ? split(byoAGWSubnetId, '/')[10] : '') : ''
var existingAGWVnetName = !empty(byoAGWSubnetId) ? (length(split(byoAGWSubnetId, '/')) > 9 ? split(byoAGWSubnetId, '/')[8] : '') : ''
var existingAGWVnetRG = !empty(byoAGWSubnetId) ? (length(split(byoAGWSubnetId, '/')) > 9 ? split(byoAGWSubnetId, '/')[4] : '') : ''

resource existingAgwVnet 'Microsoft.Network/virtualNetworks@2021-02-01' existing = if (!empty(byoAGWSubnetId)) {
  name: existingAGWVnetName
  scope: resourceGroup(existingAGWVnetRG)
}
resource existingAGWSubnet 'Microsoft.Network/virtualNetworks/subnets@2020-08-01' existing = if (!empty(byoAGWSubnetId)) {
  parent: existingAgwVnet
  name: existingAGWSubnetName
}
//------------------------------------------------------ Create
param vnetAddressPrefix string = '10.0.0.0/8'
param serviceEndpoints array = []
param vnetAksSubnetAddressPrefix string = '10.240.0.0/16'
param vnetFirewallSubnetAddressPrefix string = '10.241.130.0/26'
param vnetAppGatewaySubnetAddressPrefix string = '10.2.0.0/16'

module network './network.bicep' = if (custom_vnet) {
  name: 'network'
  params: {
    resourceName: resourceName
    location: location
    serviceEndpoints: serviceEndpoints
    vnetAddressPrefix: vnetAddressPrefix
    aksPrincipleId: uai.properties.principalId
    vnetAksSubnetAddressPrefix: vnetAksSubnetAddressPrefix
    ingressApplicationGateway: ingressApplicationGateway
    vnetAppGatewaySubnetAddressPrefix: vnetAppGatewaySubnetAddressPrefix
    azureFirewalls: azureFirewalls
    vnetFirewallSubnetAddressPrefix: vnetFirewallSubnetAddressPrefix
  }
}

var appGatewaySubnetAddressPrefix = !empty(byoAGWSubnetId) ? existingAGWSubnet.properties.addressPrefix : vnetAppGatewaySubnetAddressPrefix
var aksSubnetId = custom_vnet ? network.outputs.aksSubnetId : (!empty(byoAKSSubnetId) ? byoAKSSubnetId : null)
var appGwSubnetId = ingressApplicationGateway ? (custom_vnet ? network.outputs.appGwSubnetId : (!empty(byoAGWSubnetId) ? byoAGWSubnetId : '')) : ''

// ----------------------------------------------------------------------- If DNS Zone
// will be solved with 'existing' https://github.com/Azure/bicep/issues/258

param dnsZoneId string = ''
var dnsZoneRg = !empty(dnsZoneId) ? split(dnsZoneId, '/')[4] : ''
var dnsZoneName = !empty(dnsZoneId) ? split(dnsZoneId, '/')[8] : ''

module dnsZone './dnsZone.bicep' = if (!empty(dnsZoneId)) {
  name: 'addDnsContributor'
  scope: resourceGroup(dnsZoneRg)
  params: {
    dnsZoneName: dnsZoneName
    principalId: any(aks.properties.identityProfile.kubeletidentity).objectId
  }
}

//---------------------------------------------------------------------------------- AKV

param azureKeyvaultSecretsProvider bool = false //This is a preview feature

param createKV bool = false
param AKVserviceEndpointFW string = '' // either IP, or 'vnetonly'
var akvName = 'kv-${replace(resourceName, '-', '')}'

resource kv 'Microsoft.KeyVault/vaults@2019-09-01' = if (createKV) {
  name: akvName
  location: location
  properties: union({
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'Standard'
    }
    enabledForTemplateDeployment: true
    accessPolicies: concat(azureKeyvaultSecretsProvider ? array({
      tenantId: subscription().tenantId
      objectId: aks.properties.addonProfiles.azureKeyvaultSecretsProvider.identity.clientId
      permissions: {
        keys: [
          'get'
          'list'
        ]
        secrets: [
          'get'
          'list'
        ]
        certificates: [
          'get'
          'list'
        ]
      }
    }) : [], appgwKVIntegration ? array({
      tenantId: subscription().tenantId
      objectId: appGwIdentity.properties.principalId
      permissions: {
        secrets: [
          'get'
          'set'
          'delete'
          'list'
        ]
      }
    }) : [])
  }, !empty(AKVserviceEndpointFW) ? {
    networkAcls: {
      defaultAction: 'Deny'
      virtualNetworkRules: concat(array({
        action: 'Allow'
        id: aksSubnetId
      }), appgwKVIntegration ? array({
        action: 'Allow'
        id: appGwSubnetId
      }) : [])
      ipRules: AKVserviceEndpointFW != 'vnetonly' ? [
        {
          action: 'Allow'
          value: AKVserviceEndpointFW
        }
      ] : null
    }
  } : {})
}

//---------------------------------------------------------------------------------- ACR
param registries_sku string = ''
param ACRserviceEndpointFW string = '' // either IP, or 'vnetonly'

var acrName = 'cr${replace(resourceName, '-', '')}${uniqueString(resourceGroup().id, resourceName)}'

resource acr 'Microsoft.ContainerRegistry/registries@2020-11-01-preview' = if (!empty(registries_sku)) {
  name: acrName
  location: location
  sku: {
    name: registries_sku
  }
  properties: !empty(ACRserviceEndpointFW) ? {
    networkRuleSet: {
      defaultAction: 'Deny'
      virtualNetworkRules: [
        {
          action: 'Allow'
          id: aksSubnetId
        }
      ]
      ipRules: ACRserviceEndpointFW != 'vnetonly' ? [
        {
          action: 'Allow'
          value: ACRserviceEndpointFW
        }
      ] : null
    }
  } : {}
}

var AcrPullRole = resourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
/*
resource aks_acr_pull 'Microsoft.ContainerRegistry/registries/providers/roleAssignments@2017-05-01' = if (!empty(registries_sku)) {
  name: '${acrName}/Microsoft.Authorization/${guid(resourceGroup().id, acrName)}'
  properties: {
    roleDefinitionId: AcrPullRole
    principalId: aks.properties.identityProfile.kubeletidentity.objectId
    principalType: 'ServicePrincipal'
  }
}
*/
// New way of setting scope https://docs.microsoft.com/en-us/azure/azure-resource-manager/templates/scope-extension-resources
resource aks_acr_pull 'Microsoft.Authorization/roleAssignments@2020-04-01-preview' = if (!empty(registries_sku)) {
  scope: acr // Use when specifying a scope that is different than the deployment scope
  name: guid(resourceGroup().id, acrName)
  properties: {
    roleDefinitionId: AcrPullRole
    principalType: 'ServicePrincipal'
    principalId: any(aks.properties.identityProfile.kubeletidentity).objectId
  }
}

//---------------------------------------------------------------------------------- Firewall
param azureFirewalls bool = false
module firewall './firewall.bicep' = if (azureFirewalls && custom_vnet) {
  name: 'firewall'
  params: {
    resourceName: resourceName
    location: location
    workspaceDiagsId: aks_law.id
    fwSubnetId: network.outputs.fwSubnetId
    vnetAksSubnetAddressPrefix: vnetAksSubnetAddressPrefix
  }
}

//---------------------------------------------------------------------------------- AppGateway
param ingressApplicationGateway bool = false
param appGWcount int = 2
param appGWmaxCount int = 0
param privateIpApplicationGateway string = ''
param appgwKVIntegration bool = false

var deployAppGw = ingressApplicationGateway && (custom_vnet || !empty(byoAGWSubnetId))

// 'identity' is always created until this is fixed: 
// https://github.com/Azure/bicep/issues/387#issuecomment-885671296

// If integrating App Gateway with KeyVault, create a Identity App Gateway will use to access keyvault
resource appGwIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' = if (appgwKVIntegration || true) {
  name: 'id-appgw-${resourceName}'
  location: location
}

module appGw './appgw.bicep' = if (deployAppGw) {
  name: 'addAppGw'
  params: {
    resourceName: resourceName
    location: location
    appGwSubnetId: appGwSubnetId
    appgw_privateIpAddress: privateIpApplicationGateway
    availabilityZones: availabilityZones
    userAssignedIdentity: (appgwKVIntegration || true) ? appGwIdentity.id : ''
    workspaceId: aks_law.id
    appGWcount: appGWcount
    appGWmaxCount: appGWmaxCount
  }
}

output ApplicationGatewayName string = deployAppGw ? appGw.outputs.ApplicationGatewayName : ''

//---------------------------------------------------------------------------------- AKS
param dnsPrefix string = '${resourceName}-dns'
param kubernetesVersion string = '1.21.1'
param enable_aad bool = false
param aad_tenant_id string = ''
param omsagent bool = false

param enableAzureRBAC bool = false
param upgradeChannel string = ''
param osDiskType string = 'Ephemeral'
param agentVMSize string = 'Standard_DS2_v2'
param osDiskSizeGB int = 0
param agentCount int = 3
param agentCountMax int = 0
param maxPods int = 30
param networkPlugin string = 'azure'
param networkPolicy string = ''
param azurepolicy string = ''
param gitops string = ''
param authorizedIPRanges array = []
param enablePrivateCluster bool = false
param availabilityZones array = []

param podCidr string = '10.244.0.0/16'
param serviceCidr string = '10.0.0.0/16'
param dnsServiceIP string = '10.0.0.10'
param dockerBridgeCidr string = '172.17.0.1/16'

var appgw_name = 'agw-${resourceName}'

var autoScale = agentCountMax > agentCount

var agentPoolProfiles = {
  name: 'nodepool1'
  mode: 'System'
  osDiskType: osDiskType
  osDiskSizeGB: osDiskSizeGB
  count: agentCount
  vmSize: agentVMSize
  osType: 'Linux'
  vnetSubnetID: aksSubnetId
  maxPods: maxPods
  type: 'VirtualMachineScaleSets'
  enableAutoScaling: autoScale
  availabilityZones: !empty(availabilityZones) ? availabilityZones : null
}

var aks_properties_base = {
  kubernetesVersion: kubernetesVersion
  enableRBAC: true
  dnsPrefix: dnsPrefix
  aadProfile: enable_aad ? {
    managed: true
    enableAzureRBAC: enableAzureRBAC
    tenantID: aad_tenant_id
  } : null
  apiServerAccessProfile: !empty(authorizedIPRanges) ? {
    authorizedIPRanges: authorizedIPRanges
  } : {
    enablePrivateCluster: enablePrivateCluster
    privateDNSZone: enablePrivateCluster ? 'none' : ''
    enablePrivateClusterPublicFQDN: enablePrivateCluster
  }
  agentPoolProfiles: autoScale ? array(union(agentPoolProfiles, {
    minCount: agentCount
    maxCount: agentCountMax
  })) : array(agentPoolProfiles)
  networkProfile: {
    loadBalancerSku: 'standard'
    networkPlugin: networkPlugin
    networkPolicy: networkPolicy
    podCidr: podCidr
    serviceCidr: serviceCidr
    dnsServiceIP: dnsServiceIP
    dockerBridgeCidr: dockerBridgeCidr
  }
}

var aks_properties1 = !empty(upgradeChannel) ? union(aks_properties_base, {
  autoUpgradeProfile: {
    upgradeChannel: upgradeChannel
  }
}) : aks_properties_base

var aks_addons = {}
var aks_addons1 = ingressApplicationGateway ? union(aks_addons, custom_vnet || !empty(byoAKSSubnetId) ? {
  /*
  
  COMMENTED OUT UNTIL addon supports creating Appgw in custom vnet.  Workaround is a follow up az cli command
  */
  ingressApplicationGateway: {
    config: {
      //applicationGatewayName: appgw_name
      // 121011521000988: This doesn't work, bug : "code":"InvalidTemplateDeployment", IngressApplicationGateway addon cannot find subnet
      //subnetID: appGwSubnetId
      //subnetCIDR: vnetAppGatewaySubnetAddressPrefix
      applicationGatewayId: appGw.outputs.appgwId
    }
    enabled: true
  }
  /* */
} : {
  ingressApplicationGateway: {
    enabled: true
    config: {
      applicationGatewayName: appgw_name
      subnetCIDR: appGatewaySubnetAddressPrefix
    }
  }
}) : aks_addons

var aks_addons2 = omsagent ? union(aks_addons1, {
  omsagent: {
    enabled: true
    config: {
      logAnalyticsWorkspaceResourceID: aks_law.id
    }
  }
}) : aks_addons1

var aks_addons3 = !empty(gitops) ? union(aks_addons2, {
  gitops: {
    //    config": null,
    enabled: true
    //    identity: {
    //      clientId: 'xxx',
    //      objectId: 'xxx',
    //      resourceId: '/subscriptions/95efa97a-9b5d-4f74-9f75-a3396e23344d/resourcegroups/xxx/providers/Microsoft.ManagedIdentity/userAssignedIdentities/xxx'
    //    }
  }
}) : aks_addons2

var aks_addons4 = !empty(azurepolicy) ? union(aks_addons3, {
  azurepolicy: {
    config: {
      version: 'v2'
    }
    enabled: true
  }
}) : aks_addons3

var aks_addons5 = azureKeyvaultSecretsProvider ? union(aks_addons4, {
  azureKeyvaultSecretsProvider: {
    config: {
      enableSecretRotation: 'false'
    }
    enabled: true
  }
}) : aks_addons4

var aks_properties2 = !empty(aks_addons5) ? union(aks_properties1, {
  addonProfiles: aks_addons5
}) : aks_properties1

var aks_identity = {
  type: 'UserAssigned'
  userAssignedIdentities: {
    '${uai.id}': {}
  }
}

resource aks 'Microsoft.ContainerService/managedClusters@2021-03-01' = {
  name: 'aks-${resourceName}'
  location: location
  properties: aks_properties2
  identity: aks_byo_identity ? aks_identity : {
    type: 'SystemAssigned'
  }
}
output aksClusterName string = aks.name

// https://github.com/Azure/azure-policy/blob/master/built-in-policies/policySetDefinitions/Kubernetes/Kubernetes_PSPBaselineStandard.json
var policySetPodSecBaseline = resourceId('Microsoft.Authorization/policySetDefinitions', 'a8640138-9b0a-4a28-b8cb-1666c838647d')
resource aks_policies 'Microsoft.Authorization/policyAssignments@2019-09-01' = if (!empty(azurepolicy)) {
  name: '${resourceName}-baseline'
  location: location
  properties: {
    scope: resourceGroup().id
    policyDefinitionId: policySetPodSecBaseline
    parameters: {
      // Gives error: "The request content was invalid and could not be deserialized"
      //excludedNamespaces: '[  "kube-system",  "gatekeeper-system",  "azure-arc"]'
      effect: {
        value: azurepolicy
      }
    }
  }
}

param adminprincipleid string = ''
// for AAD Integrated Cluster wusing 'enableAzureRBAC', add Cluster admin to the current user!
var buildInAKSRBACClusterAdmin = resourceId('Microsoft.Authorization/roleDefinitions', 'b1ff04bb-8a4e-4dc4-8eb5-8693973ce19b')
resource aks_admin_role_assignment 'Microsoft.Authorization/roleAssignments@2020-04-01-preview' = if (enableAzureRBAC && !empty(adminprincipleid)) {
  scope: aks // Use when specifying a scope that is different than the deployment scope
  name: guid(resourceGroup().id, 'aks_admin_role_assignment')
  properties: {
    roleDefinitionId: buildInAKSRBACClusterAdmin
    principalType: 'User'
    principalId: adminprincipleid
  }
}

//---------------------------------------------------------------------------------- gitops (to apply the post-helm packages to the cluster)
// WAITING FOR PUBLIC PREVIEW
// https://docs.microsoft.com/en-gb/azure/azure-arc/kubernetes/use-gitops-connected-cluster#using-azure-cli
/*
resource gitops 'Microsoft.KubernetesConfiguration/sourceControlConfigurations@2019-11-01-preview' = if (false) {
  name: 'bla'
  location: 'bla'
}
*/

//---------------------------------------------------------------------------------- Container Insights

param retentionInDays int = 30
var aks_law_name = 'log-${resourceName}'
resource aks_law 'Microsoft.OperationalInsights/workspaces@2020-08-01' = if (omsagent || deployAppGw || azureFirewalls) {
  name: aks_law_name
  location: location
  properties: {
    retentionInDays: retentionInDays
  }
}

/* ------ NOTES 
output of AKS - runtime -- properties of created resources (aks.properties.<>) (instead of ARM function reference(...) )
  provisioningState, 
  powerState, 
  kubernetesVersion, 
  dnsPrefix, 
  fqdn, 
  agentPoolProfiles, 
  windowsProfile, 
  servicePrincipalProfile.clientId 
  addonProfiles, 
  nodeResourceGroup, 
  enableRBAC, 
  networkProfile, 
  aadProfile, 
  maxAgentPools, 
  apiServerAccessProfile, 
  identityProfile.
  autoScalerProfile

 
compipetime --- Instead of using the resourceId(), .ids will compile to [resourceId('Microsoft.Storage/storageAccounts', parameters('name'))]
  output blobid string = aks.id
  output blobid string = aks.name
  output blobid string = aks.apiVersion
  output blobid string = aks.type
*/
