targetScope = 'resourceGroup'

param location string = resourceGroup().location

var hostname = 'my.hostname.com'

resource vnet 'Microsoft.Network/virtualNetworks@2022-01-01' = {
  name: 'vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }
  }
}

var cidrs = {
  gateway: '10.0.0.0/24'
  firewall: '10.0.1.0/24'
  ase: '10.0.2.0/24'
  services: '10.0.3.0/24'
}

resource gateway 'Microsoft.Network/virtualNetworks/subnets@2022-01-01' = {
  name: 'Gateway'
  parent: vnet
  properties: {
    routeTable: {
      id: gwroutes.id
    }
    addressPrefix: cidrs.gateway
  }
  dependsOn: [
    ase
  ]
}

resource fwSubnet 'Microsoft.Network/virtualNetworks/subnets@2022-01-01' = {
  name: 'AzureFirewallSubnet'
  parent: vnet
  properties: {
    addressPrefix: cidrs.firewall
  }
}

resource ase 'Microsoft.Network/virtualNetworks/subnets@2022-01-01' = {
  name: 'ase'
  parent: vnet
  properties: {
    networkSecurityGroup: {
      id: asensg.id
    }
    routeTable: {
      id: aseroutes.id
    }
    addressPrefix: cidrs.ase
    serviceEndpoints: [
      {
        service: 'Microsoft.Sql'
        locations: [
          location
        ]
      }
      {
        service: 'Microsoft.Storage'
        locations: [
          location
        ]
      }
      {
        service: 'Microsoft.EventHub'
        locations: [
          location
        ]
      }
    ]
  }
}

resource services 'Microsoft.Network/virtualNetworks/subnets@2022-01-01' = {
  name: 'services'
  parent: vnet
  properties: {
    addressPrefix: cidrs.services
    privateEndpointNetworkPolicies: 'Enabled'
  }
  dependsOn: [
    gateway
  ]
}

resource pip 'Microsoft.Network/publicIPAddresses@2022-01-01' = {
  name: 'pip'
  location: location

  sku: {
    name: 'Standard'
    tier:'Regional'
  }

  properties: {
    publicIPAddressVersion: 'IPv4'
    publicIPAllocationMethod: 'Static'
  }
}

resource appgateway 'Microsoft.Network/applicationGateways@2022-01-01' = {
  name: 'gw'
  location: location

  properties: {
    sku: {
      name: 'Standard_v2'
      tier: 'Standard_v2'
      capacity: 1
    }
    gatewayIPConfigurations: [
      {
        name: 'ipconfig'
        properties: {
          subnet: {
            id: gateway.id
          }
        }
      }
    ]
    frontendIPConfigurations: [
      {
        name: 'gwfrontend'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: pip.id
          }
        }
      }
    ]
    frontendPorts: [
      {
        name: '443'
        properties: {
          port: 443
        }
      }
    ]
    backendAddressPools: [
      {
        name: 'ase'
        properties: {
          backendAddresses: [
            {
              fqdn: hostname
            }
          ]
        }
      }
    ]
    backendHttpSettingsCollection: [
      {
        name: 'https'
        properties: {
          port: 443
          protocol: 'Https'
          pickHostNameFromBackendAddress: true
          probe: {
            id: resourceId('Microsoft.Network/applicationGateways/probes', 'gw', 'httpsprobe')
          }
        }
      }
    ]
    sslCertificates: [
      {
        name: 'cert'
        properties: {
          password: 'password'
          data: loadFileAsBase64('./placeholder.pfx')
        }
      }
    ]
    httpListeners: [
      {
        name: 'listener'
        properties: {
          protocol: 'Https'
          frontendPort: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendPorts', 'gw', '443')
          }
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendIPConfigurations', 'gw', 'gwfrontend')
          }
          sslCertificate: {
            id: resourceId('Microsoft.Network/applicationGateways/sslCertificates', 'gw', 'cert')
          }
          hostNames: [
            hostname
          ]
          requireServerNameIndication: true
        }
      }
    ]
    requestRoutingRules: [
      {
        name: 'https'
        properties: {
          ruleType: 'Basic'
          priority: 100
          httpListener: {
            id: resourceId('Microsoft.Network/applicationGateways/httpListeners', 'gw', 'listener')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/applicationGateways/backendAddressPools', 'gw', 'ase')
          }
          backendHttpSettings: {
            id: resourceId('Microsoft.Network/applicationGateways/backendHttpSettingsCollection', 'gw', 'https')
          }
        }
      }
    ]
    probes: [
      {
        name: 'httpsprobe'
        properties: {
          protocol: 'Https'
          path: '/'
          interval: 30
          timeout: 30
          unhealthyThreshold: 3
          pickHostNameFromBackendHttpSettings: true
          match: {
            statusCodes: [
              '200'
            ]
          }
        }
      }
    ]
    enableHttp2: true
  }
}

resource fwpip 'Microsoft.Network/publicIPAddresses@2022-01-01' = {
  name: 'fwpip'
  location: location

  sku: {
    name: 'Standard'
    tier:'Regional'
  }

  properties: {
    publicIPAddressVersion: 'IPv4'
    publicIPAllocationMethod: 'Static'
  }
}

resource firewall 'Microsoft.Network/azureFirewalls@2022-01-01' = {
  name: 'fw'
  location: location
  properties: {
    sku: {
      name: 'AZFW_VNet'
      tier: 'Standard'
    }
    threatIntelMode: 'Alert'
    ipConfigurations: [
      {
        name: 'ip'
        properties: {
          subnet: {
            id: fwSubnet.id
          }
          publicIPAddress: {
            id: fwpip.id
          }
        }
      }
    ]
    networkRuleCollections: [
      {
        name: 'AllowGatewayToASE_HTTPS'
        properties: {
          priority: 100
          action: {
            type: 'Allow'
          }
          rules: [
            {
              name: 'AllowHTTPS'
              protocols: [
                'TCP'
              ]
              sourceAddresses: [
                cidrs.gateway
              ]
              destinationAddresses: [
                cidrs.ase
              ]
              destinationPorts: [
                '443'
              ]
            }
          ]
        }
      }
      {
        name: 'AllowASEToAny'
        properties: {
          priority: 110
          action: {
            type: 'Allow'
          }
          rules: [
            {
              name: 'AllowASEToAny'
              protocols: [
                'Any'
              ]
              sourceAddresses: [
                cidrs.ase
              ]
              destinationAddresses: [
                '*'
              ]
              destinationPorts: [
                '*'
              ]
            }
          ]
        }
      }
      {
        name: 'AllowForASEv2'
        properties: {
          priority: 130
          action: {
            type: 'Allow'
          }
          rules: [
            {
              name: 'NTP'
              protocols: [
                'Any'
              ]
              sourceAddresses: [
                '*'
              ]
              destinationAddresses: [
                '*'
              ]
              destinationPorts: [
                '123'
              ]
            }
            {
              name: '12000'
              protocols: [
                'Any'
              ]
              sourceAddresses: [
                '*'
              ]
              destinationAddresses: [
                '*'
              ]
              destinationPorts: [
                '12000'
              ]
            }
            {
              name: 'Monitor'
              protocols: [
                'Any'
              ]
              sourceAddresses: [
                '*'
              ]
              destinationAddresses: [
                'AzureMonitor'
              ]
              destinationPorts: [
                '80'
                '443'
                '12000'
              ]
            }
          ]
        }
      }
    ]
    applicationRuleCollections: [
      {
        name: 'ASE'
        properties: {
          priority: 500
          action: {
            type: 'Allow'
          }
          rules: [
            {
              name: 'ASE'
              protocols: [
                {
                  port: 443
                  protocolType: 'Https'
                }
                {
                  port: 80
                  protocolType: 'Http'
                }
              ]
              fqdnTags: [
                'AppServiceEnvironment'
                'WindowsUpdate'
              ]
              sourceAddresses: [
                '*'
              ]
            }
          ]
        }
      }
    ]
  }
}

var static_routes = [
  {
    name: 'force-tunnel-ase-fw-gw'
    properties: {
      nextHopType: 'VirtualAppliance'
      nextHopIpAddress: firewall.properties.ipConfigurations[0].properties.privateIPAddress
      addressPrefix: cidrs.gateway
    }
  }
  {
    name: 'force-tunnel-everything-else'
    properties: {
      nextHopType: 'VirtualAppliance'
      nextHopIpAddress: firewall.properties.ipConfigurations[0].properties.privateIPAddress
      addressPrefix: '0.0.0.0/0'
    }
  }
]

var app_service_management_ips = [
  '13.66.140.0'
  '13.67.8.128'
  '13.69.64.128'
  '13.69.227.128'
  '13.70.73.128'
  '13.71.170.64'
  '13.71.194.129'
  '13.75.34.192'
  '13.75.127.117'
  '13.77.50.128'
  '13.78.109.0'
  '13.89.171.0'
  '13.94.141.115'
  '13.94.143.126'
  '13.94.149.179'
  '20.36.106.128'
  '20.36.114.64'
  '20.37.74.128'
  '23.96.195.3'
  '23.102.188.65'
  '40.69.106.128'
  '40.70.146.128'
  '40.71.13.64'
  '40.74.100.64'
  '40.78.194.128'
  '40.79.130.64'
  '40.79.178.128'
  '40.83.120.64'
  '40.83.121.56'
  '40.83.125.161'
  '40.112.242.192'
  '51.107.58.192'
  '51.107.154.192'
  '51.116.58.192'
  '51.116.155.0'
  '51.120.99.0'
  '51.120.219.0'
  '51.140.146.64'
  '51.140.210.128'
  '52.151.25.45'
  '52.162.106.192'
  '52.165.152.214'
  '52.165.153.122'
  '52.165.154.193'
  '52.165.158.140'
  '52.174.22.21'
  '52.178.177.147'
  '52.178.184.149'
  '52.178.190.65'
  '52.178.195.197'
  '52.187.56.50'
  '52.187.59.251'
  '52.187.63.19'
  '52.187.63.37'
  '52.224.105.172'
  '52.225.177.153'
  '52.231.18.64'
  '52.231.146.128'
  '65.52.172.237'
  '65.52.250.128'
  '70.37.57.58'
  '104.44.129.141'
  '104.44.129.243'
  '104.44.129.255'
  '104.44.134.255'
  '104.208.54.11'
  '104.211.81.64'
  '104.211.146.128'
  '157.55.208.185'
  '191.233.50.128'
  '191.233.203.64'
  '191.236.154.88'
]

var built_rules = [for (item, index) in app_service_management_ips: {
  name: 'appsvcmgt${index}'
  properties: {
    nextHopType: 'Internet'
    addressPrefix: '${item}/32'
  }
}]

resource gwroutes 'Microsoft.Network/routeTables@2022-01-01' = {
  name: 'gwroutes'
  location: location

  properties: {
    routes: [
      {
        name: 'force-tunnel-gw-fw-ase'
        properties: {
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: firewall.properties.ipConfigurations[0].properties.privateIPAddress
          addressPrefix: cidrs.ase
        }
      }
    ]
  }
}

resource aseroutes 'Microsoft.Network/routeTables@2022-01-01' = {
  name: 'aseroutes'
  location: location

  properties: {
    routes: concat(built_rules, static_routes)
  }
}

resource asensg 'Microsoft.Network/networkSecurityGroups@2022-01-01' = {
  name: 'asensg'
  location: location

  properties: {
    securityRules: [
      {
        name: 'Inbound-management'
        properties: {
          description: 'Used to manage ASE from public VIP'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '454-455'
          sourceAddressPrefix: 'AppServiceManagement'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 100
          direction: 'Inbound'
        }
      }
      {
        name: 'Inbound-load-balancer-keep-alive'
        properties: {
          description: 'Allow communication to ASE from Load Balancer'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '16001'
          sourceAddressPrefix: 'AzureLoadBalancer'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 105
          direction: 'Inbound'
        }
      }
      {
        name: 'ASE-internal-inbound'
        properties: {
          description: 'ASE-internal-inbound'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: cidrs.ase
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 110
          direction: 'Inbound'
        }
      }
      {
        name: 'Inbound-HTTPS'
        properties: {
          description: 'Inbound-HTTPS'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 130
          direction: 'Inbound'
        }
      }
      {
        name: 'Outbound-HTTPS'
        properties: {
          description: 'Outbound-HTTPS'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 100
          direction: 'Outbound'
        }
      }
      {
        name: 'Outbound-DB'
        properties: {
          description: 'Outbound-DB'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '1433'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 110
          direction: 'Outbound'
        }
      }
      {
        name: 'Outbound-DNS'
        properties: {
          description: 'Outbound-DNS'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '53'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 120
          direction: 'Outbound'
        }
      }
      {
        name: 'ASE-internal-outbound'
        properties: {
          description: 'Azure Storage queue'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: cidrs.ase
          access: 'Allow'
          priority: 130
          direction: 'Outbound'
        }
      }
      {
        name: 'Outbound-80'
        properties: {
          description: 'Outbound-80'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '80'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 140
          direction: 'Outbound'
        }
      }
      {
        name: 'ASE-to-VNET'
        properties: {
          description: 'ASE-to-VNET'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: cidrs.ase
          access: 'Allow'
          priority: 150
          direction: 'Outbound'
        }
      }
      {
        name: 'Outbound-NTP'
        properties: {
          description: 'Outbound-NTP'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '123'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 160
          direction: 'Outbound'
        }
      }
    ]
  }
}

var suffix = uniqueString(subscription().id, resourceGroup().id)

resource environment 'Microsoft.Web/hostingEnvironments@2022-03-01' = {
  name: 'ase${suffix}'
  location: location
  kind: 'ASEV2'

  properties: {
    virtualNetwork: {
      id: ase.id
    }
    internalLoadBalancingMode: 'Web, Publishing'
    multiSize: 'Standard_D1_V2'
    frontEndScaleFactor: 15
  }
}

resource plan 'Microsoft.Web/serverfarms@2022-03-01' = {
  name: 'plan'
  location: location

  properties: {
    hostingEnvironmentProfile: {
      id: environment.id
    }
  }

  sku: {
    name: 'I1'
    size: 'I1'
    tier: 'Isolated'
    family: 'I'
    capacity: 1
  }
}

resource app 'Microsoft.Web/sites@2022-03-01' = {
  name: 'app${suffix}'
  location: location

  properties: {
    serverFarmId: plan.id
    hostingEnvironmentProfile: {
      id: environment.id
    }
    httpsOnly: true
  }
}

resource cert 'Microsoft.Web/certificates@2022-03-01' = {
  name: 'cert'
  location: location

  properties: {
    hostNames: [
      hostname
    ]
    pfxBlob: any(loadFileAsBase64('./placeholder.pfx'))
    password: 'password'
    serverFarmId: plan.id
  }
}

resource binding 'Microsoft.Web/sites/hostNameBindings@2022-03-01' = {
  name: hostname
  parent: app

  properties: {
    sslState: 'SniEnabled'
    thumbprint: cert.properties.thumbprint
  }
}

resource dns 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: hostname
  location: location
}

resource a 'Microsoft.Network/privateDnsZones/A@2020-06-01' = {
  name: hostname
  parent: dns
  properties: {
    aRecords: [
      {
        ipv4Address: ase.properties.ipConfigurations[0].properties.privateIPAddress
      }
    ]
  }
}

resource link 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  name: 'link'
  location: location
  parent: dns
  properties: {
    virtualNetwork: {
      id: vnet.id
    }
  }
}
