// Function App that runs Warden on a daily timer.
//
// Azure Automation can't be created on Azure for Students subscriptions (its
// allowed regions don't overlap the subscription's region policy), so the job
// runs as a PowerShell timer function instead. The Consumption plan's free
// grant covers a daily run; the storage account costs cents a month.
//
// The app signs in to Graph with its own system-assigned managed identity,
// so no secret is stored anywhere.

@description('Azure region')
param location string = resourceGroup().location

@description('Function App name (globally unique)')
param appName string = 'warden-${uniqueString(resourceGroup().id)}'

@description('HR export as base64 CSV')
@secure()
param hrCsvBase64 string

@description('config/roles.json as base64')
param roleMapBase64 string

@description('Domain for new user principal names')
param upnDomain string

@description('Report changes without making them')
param dryRun bool = true

@description('NCRONTAB schedule, UTC (default: 06:00 daily)')
param schedule string = '0 0 6 * * *'

var storageName = 'warden${uniqueString(resourceGroup().id)}'

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

// Audit log: one blob per run.
resource auditContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'audit'
  properties: { publicAccess: 'None' }
}

var storageConnection = 'DefaultEndpointsProtocol=https;AccountName=${storage.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${storage.listKeys().keys[0].value}'

resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: '${appName}-plan'
  location: location
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
  properties: {}
}

resource app 'Microsoft.Web/sites@2023-12-01' = {
  name: appName
  location: location
  kind: 'functionapp'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    siteConfig: {
      powerShellVersion: '7.6'
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      use32BitWorkerProcess: false
      appSettings: [
        { name: 'AzureWebJobsStorage', value: storageConnection }
        { name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING', value: storageConnection }
        { name: 'WEBSITE_CONTENTSHARE', value: toLower(appName) }
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'powershell' }
        { name: 'FUNCTIONS_WORKER_RUNTIME_VERSION', value: '7.6' }
        { name: 'WARDEN_SCHEDULE', value: schedule }
        { name: 'WARDEN_HR_CSV_B64', value: hrCsvBase64 }
        { name: 'WARDEN_ROLE_MAP_B64', value: roleMapBase64 }
        { name: 'WARDEN_UPN_DOMAIN', value: upnDomain }
        { name: 'WARDEN_DRY_RUN', value: string(dryRun) }
      ]
    }
  }
}

// No FTP publishing; deployments go through the Azure CLI with Entra ID auth.
resource ftp 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2023-12-01' = {
  parent: app
  name: 'ftp'
  properties: { allow: false }
}

output appName string = app.name
output principalId string = app.identity.principalId
output storageName string = storage.name
