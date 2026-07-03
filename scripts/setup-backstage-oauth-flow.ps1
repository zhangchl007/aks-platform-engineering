<#
.SYNOPSIS
  Reserve the Backstage public IP, pause for GitHub OAuth App setup, then deploy Backstage.

.DESCRIPTION
  This guided flow solves the first-time GitHub OAuth callback URL problem:
  Terraform first creates or keeps the static Azure Public IP for the Backstage
  LoadBalancer, prints the Backstage homepage and callback URLs, waits for the
  operator to configure the GitHub OAuth App in the browser, then deploys
  Backstage with the supplied OAuth credentials.

  OAuth client secret values are stored only in this PowerShell process
  environment for the second Terraform apply. They are not written to disk.
#>
[CmdletBinding()]
param(
  [string]$TerraformDir,
  [string]$GitOpsAddonsOrg = "https://github.com/zhangchl007",
  [string]$GitOpsAddonsRevision = "zhangchl007-azure-arc-onboarding",
  [string]$BackstageImageRepository = "amllearning02.azurecr.io/backstage",
  [string]$BackstageImageTag = "github-idp-fix2",
  [switch]$SkipInit,
  [switch]$AutoApprove
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Write-Step($Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok($Message) { Write-Host "    $Message" -ForegroundColor Green }
function Write-Warn($Message) { Write-Host "    $Message" -ForegroundColor Yellow }

function Invoke-Terraform {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments
  )

  & terraform "-chdir=$TerraformDir" @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "terraform $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
  }
}

function Get-TerraformOutputRaw {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name
  )

  $value = & terraform "-chdir=$TerraformDir" output -raw $Name
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to read Terraform output '$Name'."
  }

  return ($value | Out-String).Trim()
}

function ConvertFrom-SecureStringToPlainText {
  param(
    [Parameter(Mandatory = $true)]
    [securestring]$SecureString
  )

  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
  try {
    return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
  } finally {
    if ($bstr -ne [IntPtr]::Zero) {
      [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
  }
}

if (-not $TerraformDir) {
  $TerraformDir = Join-Path (Split-Path -Parent $PSScriptRoot) "terraform"
}

foreach ($tool in @("terraform", "gh")) {
  if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
    throw "Required tool '$tool' not found on PATH."
  }
}

if (-not (Test-Path -Path $TerraformDir -PathType Container)) {
  throw "Terraform directory not found: $TerraformDir"
}

$originalGithubToken = $env:GITHUB_TOKEN
$originalTfGithubToken = $env:TF_VAR_github_token
$originalClientId = $env:TF_VAR_backstage_github_client_id
$originalClientSecret = $env:TF_VAR_backstage_github_client_secret

try {
  if (-not $env:TF_VAR_github_token) {
    if (-not $env:GITHUB_TOKEN) {
      Write-Step "Reading GitHub token from gh auth"
      $env:GITHUB_TOKEN = (& gh auth token).Trim()
      if ($LASTEXITCODE -ne 0 -or -not $env:GITHUB_TOKEN) {
        throw "Failed to read GitHub token from gh auth. Run 'gh auth login' first."
      }
    }

    $env:TF_VAR_github_token = $env:GITHUB_TOKEN
  }

  if (-not $SkipInit) {
    Write-Step "Initializing Terraform"
    Invoke-Terraform -Arguments @("init")
  }

  $approvalArgs = @()
  if ($AutoApprove) {
    $approvalArgs += "-auto-approve"
  }

  $commonVars = @(
    "-var", "gitops_addons_org=$GitOpsAddonsOrg",
    "-var", "gitops_addons_revision=$GitOpsAddonsRevision",
    "-var", "backstage_image_repository=$BackstageImageRepository",
    "-var", "backstage_image_tag=$BackstageImageTag"
  )

  Write-Step "Reserving static Backstage public IP"
  Invoke-Terraform -Arguments (@(
      "apply"
    ) + $approvalArgs + @(
      "-refresh=false",
      "-target=azurerm_public_ip.backstage_public_ip[0]",
      "-var", "build_backstage=false",
      "-var", "reserve_backstage_public_ip=true"
    ) + $commonVars)

  Write-Step "Reading Backstage OAuth URLs from Terraform outputs"
  $backstagePublicIp = Get-TerraformOutputRaw -Name "backstage_public_ip"
  $backstageBaseUrl = Get-TerraformOutputRaw -Name "backstage_base_url"
  $backstageCallbackUrl = Get-TerraformOutputRaw -Name "backstage_github_oauth_callback_url"

  Write-Host ""
  Write-Ok "Backstage public IP: $backstagePublicIp"
  Write-Ok "GitHub OAuth App Homepage URL: $backstageBaseUrl"
  Write-Ok "GitHub OAuth App Authorization callback URL: $backstageCallbackUrl"
  Write-Host ""
  Write-Warn "Configure or update the GitHub OAuth App in the browser with the URLs above."
  Write-Warn "For production, prefer stable DNS and trusted TLS instead of raw IP-based OAuth URLs."
  Read-Host "Press Enter after the GitHub OAuth App is configured"

  $clientId = Read-Host "GitHub OAuth Client ID"
  if (-not $clientId) {
    throw "GitHub OAuth Client ID is required."
  }

  $clientSecretSecure = Read-Host "GitHub OAuth Client Secret" -AsSecureString
  if ($clientSecretSecure.Length -eq 0) {
    throw "GitHub OAuth Client Secret is required."
  }

  $env:TF_VAR_backstage_github_client_id = $clientId
  $env:TF_VAR_backstage_github_client_secret = ConvertFrom-SecureStringToPlainText -SecureString $clientSecretSecure

  Write-Step "Deploying Backstage with the reserved public IP and GitHub OAuth credentials"
  Invoke-Terraform -Arguments (@(
      "apply"
    ) + $approvalArgs + @(
      "-var", "build_backstage=true",
      "-var", "reserve_backstage_public_ip=true"
    ) + $commonVars)

  Write-Step "Backstage deployment requested"
  Write-Ok "Verify pods: kubectl --context gitops-aks -n backstage get pods"
  Write-Ok "Verify service: kubectl --context gitops-aks -n backstage get svc backstage-backstagechart -o wide"
  Write-Ok "Verify GitHub auth redirect: curl.exe -k -I --max-time 20 `"$backstageBaseUrl/api/auth/github/start?env=development`""
} finally {
  $env:GITHUB_TOKEN = $originalGithubToken
  $env:TF_VAR_github_token = $originalTfGithubToken
  $env:TF_VAR_backstage_github_client_id = $originalClientId
  $env:TF_VAR_backstage_github_client_secret = $originalClientSecret
}
