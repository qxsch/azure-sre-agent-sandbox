<#
.SYNOPSIS
    Deploys the Azure SRE Agent Demo Lab infrastructure using Bicep.

.DESCRIPTION
    This script deploys all Azure infrastructure needed for the SRE Agent demo,
    including AKS, Container Registry, Key Vault, observability tools, and
    Azure SRE Agent (Microsoft.App/agents@2025-05-01-preview).
    It uses device code authentication by default for dev container support.

.PARAMETER Location
    Azure region for deployment. Must be an SRE Agent supported region.
    Valid values: eastus2, swedencentral, australiaeast

.PARAMETER WorkloadName
    Name prefix for resources. Default: srelab

.PARAMETER SkipRbac
    Skip RBAC role assignments (useful if subscription policies block them)

.PARAMETER WhatIf
    Show what would be deployed without making changes

.EXAMPLE
    .\deploy.ps1 -Location eastus2

.EXAMPLE
    .\deploy.ps1 -Location eastus2 -WhatIf

.NOTES
    Author: Azure SRE Agent Demo Lab
    Prerequisites: Azure CLI, Bicep CLI
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet('eastus2', 'swedencentral', 'australiaeast')]
    [string]$Location = 'eastus2',

    [Parameter()]
    [ValidateLength(3, 10)]
    [string]$WorkloadName = 'srelab',

    [Parameter()]
    [switch]$SkipRbac,

    [Parameter()]
    [switch]$WhatIf,

    [Parameter()]
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'

function Invoke-AzCliJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Command
    )

    # Run command and capture all output
    $raw = Invoke-Expression $Command 2>&1 | Out-String
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        return [pscustomobject]@{
            ExitCode = $exitCode
            Raw      = $raw
            Json     = $null
        }
    }

    # Extract JSON from output (skip any warning lines before the JSON)
    $jsonStart = $raw.IndexOf('{')
    if ($jsonStart -ge 0) {
        $jsonContent = $raw.Substring($jsonStart)
    }
    else {
        $jsonContent = $raw
    }

    try {
        $json = $jsonContent | ConvertFrom-Json
    }
    catch {
        return [pscustomobject]@{
            ExitCode = $exitCode
            Raw      = $raw
            Json     = $null
        }
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Raw      = $raw
        Json     = $json
    }
}

# Banner
Write-Host @"

╔══════════════════════════════════════════════════════════════════════════════╗
║                    Azure SRE Agent Demo Lab Deployment                       ║
╠══════════════════════════════════════════════════════════════════════════════╣
║  This script deploys:                                                        ║
║  • Azure Kubernetes Service (AKS) with multi-service demo app               ║
║  • Azure Container Registry                                                  ║
║  • Observability stack (Log Analytics, App Insights, Grafana)               ║
║  • Key Vault for secrets management                                         ║
║  • Azure SRE Agent for AI-powered diagnostics                               ║
╚══════════════════════════════════════════════════════════════════════════════╝

"@ -ForegroundColor Cyan

# Verify prerequisites
Write-Host "🔍 Checking prerequisites..." -ForegroundColor Yellow

# Check Azure CLI
try {
    $azVersion = az version --output json | ConvertFrom-Json
    Write-Host "  ✅ Azure CLI version: $($azVersion.'azure-cli')" -ForegroundColor Green
}
catch {
    Write-Error "Azure CLI is not installed. Please install it from https://aka.ms/installazurecli"
    exit 1
}

# Check Bicep
try {
    $bicepVersion = az bicep version 2>&1
    Write-Host "  ✅ Bicep: $bicepVersion" -ForegroundColor Green
}
catch {
    Write-Host "  ⚠️  Bicep not found, installing..." -ForegroundColor Yellow
    az bicep install
}

# Check login status
Write-Host "`n🔐 Checking Azure authentication..." -ForegroundColor Yellow
$account = az account show --output json 2>$null | ConvertFrom-Json

if (-not $account) {
    Write-Host "  Not logged in. Initiating device code authentication..." -ForegroundColor Yellow
    Write-Host "  This method works well in dev containers and codespaces." -ForegroundColor Gray
    az login --use-device-code
    $account = az account show --output json | ConvertFrom-Json
}

Write-Host "  ✅ Logged in as: $($account.user.name)" -ForegroundColor Green
Write-Host "  📋 Subscription: $($account.name) ($($account.id))" -ForegroundColor Green

# Confirm subscription
Write-Host "`n⚠️  Resources will be deployed to subscription: $($account.name)" -ForegroundColor Yellow
if (-not $Yes) {
    $confirm = Read-Host "Continue? (y/N)"
    if ($confirm -ne 'y' -and $confirm -ne 'Y') {
        Write-Host "Deployment cancelled." -ForegroundColor Red
        exit 0
    }
}
else {
    Write-Host "  ✅ Confirmation skipped (-Yes)" -ForegroundColor Gray
}

# Set variables
$resourceGroupName = "rg-$WorkloadName-$Location"
$deploymentName = "sre-demo-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$bicepFile = Join-Path $PSScriptRoot "..\infra\bicep\main.bicep"
$parametersFile = Join-Path $PSScriptRoot "..\infra\bicep\main.bicepparam"

Write-Host "`n📦 Deployment Configuration:" -ForegroundColor Cyan
Write-Host "  • Location:        $Location" -ForegroundColor White
Write-Host "  • Workload Name:   $WorkloadName" -ForegroundColor White
Write-Host "  • Resource Group:  $resourceGroupName" -ForegroundColor White
Write-Host "  • Deployment Name: $deploymentName" -ForegroundColor White

# Validate template
Write-Host "`n🔍 Validating Bicep template..." -ForegroundColor Yellow

if ($WhatIf) {
    Write-Host "  Running what-if analysis..." -ForegroundColor Gray
    az deployment sub what-if `
        --location $Location `
        --template-file $bicepFile `
        --parameters location=$Location workloadName=$WorkloadName `
        --name $deploymentName
    
    Write-Host "`n✅ What-if analysis complete. No changes were made." -ForegroundColor Green
    exit 0
}

# Deploy
Write-Host "`n🚀 Starting deployment..." -ForegroundColor Yellow
Write-Host "  This will take approximately 15-25 minutes." -ForegroundColor Gray

$startTime = Get-Date

try {
    $createCmd = @(
        "az deployment sub create",
        "--location $Location",
        "--template-file `"$bicepFile`"",
        "--parameters `"$parametersFile`" location=$Location workloadName=$WorkloadName",
        "--name $deploymentName",
        "--only-show-errors",
        "--output json"
    ) -join ' '

    $create = Invoke-AzCliJson -Command $createCmd

    if ($create.ExitCode -ne 0 -or -not $create.Json) {
        Write-Host "\nAzure CLI deployment command failed." -ForegroundColor Red
        if ($create.Raw) {
            Write-Host "Azure CLI output:\n$($create.Raw.Trim())" -ForegroundColor Red
        }

        # Best-effort: if a deployment record exists, pull structured error details.
        $showCmd = "az deployment sub show --name $deploymentName --output json"
        $show = Invoke-AzCliJson -Command $showCmd
        if ($show.ExitCode -eq 0 -and $show.Json) {
            $state = $show.Json.properties.provisioningState
            Write-Host "\nDeployment provisioningState: $state" -ForegroundColor Yellow
            if ($show.Json.properties.error) {
                Write-Host "\nDeployment error (structured):" -ForegroundColor Yellow
                Write-Host ($show.Json.properties.error | ConvertTo-Json -Depth 50) -ForegroundColor Yellow
            }
        }

        throw "Deployment failed (see output above)."
    }

    $deployment = $create.Json

    $endTime = Get-Date
    $duration = $endTime - $startTime

    Write-Host "`n✅ Deployment completed successfully!" -ForegroundColor Green
    Write-Host "   Duration: $($duration.Minutes) minutes $($duration.Seconds) seconds" -ForegroundColor Gray

    # Output deployment results
    Write-Host "`n📋 Deployment Outputs:" -ForegroundColor Cyan
    
    $outputs = $deployment.properties.outputs
    Write-Host "  • Resource Group:   $($outputs.resourceGroupName.value)" -ForegroundColor White
    Write-Host "  • AKS Cluster:      $($outputs.aksClusterName.value)" -ForegroundColor White
    Write-Host "  • AKS FQDN:         $($outputs.aksClusterFqdn.value)" -ForegroundColor White
    Write-Host "  • ACR Login Server: $($outputs.acrLoginServer.value)" -ForegroundColor White
    Write-Host "  • Key Vault URI:    $($outputs.keyVaultUri.value)" -ForegroundColor White
    Write-Host "  • Log Analytics ID: $($outputs.logAnalyticsWorkspaceId.value)" -ForegroundColor White
    Write-Host "  • App Insights ID:  $($outputs.appInsightsId.value)" -ForegroundColor White
    
    if ($outputs.grafanaDashboardUrl.value) {
        Write-Host "  • Grafana:          $($outputs.grafanaDashboardUrl.value)" -ForegroundColor White
        Write-Host "  • AMW ID:           $($outputs.azureMonitorWorkspaceId.value)" -ForegroundColor White
        Write-Host "  • Prometheus DCR:   $($outputs.prometheusDataCollectionRuleId.value)" -ForegroundColor White
    }

    if ($outputs.podRestartAlertId.value) {
        Write-Host "  • Alert (restarts): $($outputs.podRestartAlertId.value)" -ForegroundColor White
        Write-Host "  • Alert (HTTP 5xx): $($outputs.http5xxAlertId.value)" -ForegroundColor White
        Write-Host "  • Alert (failures): $($outputs.podFailureAlertId.value)" -ForegroundColor White
        Write-Host "  • Alert (crash/oom):$($outputs.crashLoopOomAlertId.value)" -ForegroundColor White
    }

    if ($outputs.defaultActionGroupId.value) {
        Write-Host "  • Action Group:     $($outputs.defaultActionGroupId.value)" -ForegroundColor White
        Write-Host "  • Incident Webhook: $($outputs.defaultActionGroupHasWebhook.value)" -ForegroundColor White
    }

    if ($outputs.sreAgentId.value) {
        Write-Host "  • SRE Agent:        $($outputs.sreAgentName.value)" -ForegroundColor White
        Write-Host "  • SRE Agent Portal: $($outputs.sreAgentPortalUrl.value)" -ForegroundColor White
    }

    # Save outputs to file
    $outputsFile = Join-Path $PSScriptRoot "deployment-outputs.json"
    $deployment.properties.outputs | ConvertTo-Json -Depth 10 | Set-Content $outputsFile
    Write-Host "`n  📄 Outputs saved to: $outputsFile" -ForegroundColor Gray

}
catch {
    Write-Host "`n❌ Deployment failed!" -ForegroundColor Red
    Write-Host "   Error: $_" -ForegroundColor Red
    exit 1
}

# Get AKS credentials
Write-Host "`n🔑 Getting AKS credentials..." -ForegroundColor Yellow
az aks get-credentials `
    --resource-group $resourceGroupName `
    --name $outputs.aksClusterName.value `
    --overwrite-existing

Write-Host "  ✅ kubectl configured for cluster: $($outputs.aksClusterName.value)" -ForegroundColor Green

# Apply RBAC if not skipped
if (-not $SkipRbac) {
    Write-Host "`n🔐 Applying RBAC assignments..." -ForegroundColor Yellow
    Write-Host "  ⚠️  Note: If this fails due to subscription policies, run with -SkipRbac" -ForegroundColor Gray
    
    $rbacScript = Join-Path $PSScriptRoot "configure-rbac.ps1"
    if (Test-Path $rbacScript) {
        & $rbacScript -ResourceGroupName $resourceGroupName
    }
    else {
        Write-Host "  ⚠️  RBAC script not found, skipping..." -ForegroundColor Yellow
    }
}

# Deploy application
Write-Host "`n📦 Deploying demo application to AKS..." -ForegroundColor Yellow
$k8sPath = Join-Path $PSScriptRoot "..\k8s\base\application.yaml"

if (Test-Path $k8sPath) {
    kubectl apply -f $k8sPath
    Write-Host "  ✅ Demo application deployed" -ForegroundColor Green
    
    # Wait for pods to start
    Write-Host "`n⏳ Waiting for pods to be ready (this may take 2-3 minutes)..." -ForegroundColor Yellow
    kubectl wait --for=condition=ready pod -l app=store-front -n pets --timeout=180s 2>$null
    
    # Wait for LoadBalancer IP
    Write-Host "⏳ Waiting for store-front external IP..." -ForegroundColor Yellow
    $maxWait = 120
    $waited = 0
    $storeUrl = $null
    while ($waited -lt $maxWait) {
        $externalIp = kubectl get svc store-front -n pets -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>$null
        if ($externalIp) {
            $storeUrl = "http://$externalIp"
            break
        }
        Start-Sleep -Seconds 5
        $waited += 5
    }
    
    if ($storeUrl) {
        Write-Host "  ✅ Store Front URL: $storeUrl" -ForegroundColor Green
    }
}
else {
    Write-Host "  ⚠️  Application manifest not found at: $k8sPath" -ForegroundColor Yellow
}

# Run validation
Write-Host "`n🔍 Running deployment validation..." -ForegroundColor Yellow
$validateScript = Join-Path $PSScriptRoot "validate-deployment.ps1"

if (Test-Path $validateScript) {
    & $validateScript -ResourceGroupName $resourceGroupName
}
else {
    Write-Host "  ⚠️  Validation script not found, skipping..." -ForegroundColor Yellow
}

# Final instructions
$aksName = if ($outputs.aksClusterName.value) { $outputs.aksClusterName.value } else { "<check Azure Portal>" }
$siteUrlDisplay = if ($storeUrl) { $storeUrl } else { "kubectl get svc store-front -n pets" }

Write-Host @"

╔══════════════════════════════════════════════════════════════════════════════╗
║                         Deployment Complete! 🎉                              ║
╠══════════════════════════════════════════════════════════════════════════════╣
║  Resources Deployed:                                                         ║
║    • AKS Cluster:    $($aksName.PadRight(44))║
║    • Store Front:    $($siteUrlDisplay.PadRight(44))║
║                                                                              ║
║  ✅ SRE Agent: Deployed automatically via Bicep                              ║
║    Portal: https://aka.ms/sreagent/portal                                    ║
║                                                                              ║
║  Quick Start (after SRE Agent setup):                                        ║
║    1. Open the store: $siteUrlDisplay
║    2. Break something: break-oom                                             ║
║    3. Refresh store to see failure                                           ║
║    4. Ask SRE Agent: "Why are pods crashing in the pets namespace?"         ║
║    5. Fix it: fix-all                                                        ║
╚══════════════════════════════════════════════════════════════════════════════╝

"@ -ForegroundColor Cyan

