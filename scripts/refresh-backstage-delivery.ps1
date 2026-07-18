<#
.SYNOPSIS
Refreshes Backstage-generated ArgoCD delivery immediately after a PR merge.

.DESCRIPTION
This is an operational acceleration helper. It does not change Git desired state
or permanently configure Kubernetes resources. It asks ArgoCD to refresh the
Backstage delivery root, waits for the requested revision, and optionally waits
for the generated Application or ApplicationSet children to become
Synced/Healthy.
#>
[CmdletBinding()]
param(
  [string] $Context = "gitops-aks-admin",
  [string] $ArgoCdNamespace = "argocd",
  [string] $DeliveryRootApplication = "backstage-delivery-apps",
  [string] $ApplicationName,
  [string] $Revision,
  [int] $TimeoutSeconds = 300
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Invoke-Kubectl {
  param([string[]] $Arguments)

  $output = kubectl --context $Context @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "kubectl failed: kubectl --context $Context $($Arguments -join ' ')"
  }
  return $output
}

function Get-ArgoApplication {
  param([string] $Name)

  $json = Invoke-Kubectl -Arguments @("-n", $ArgoCdNamespace, "get", "application", $Name, "-o", "json") 2>$null
  if (-not $json) {
    return $null
  }
  return $json | ConvertFrom-Json
}

function Request-ArgoRefresh {
  param([string] $Kind, [string] $Name)

  Invoke-Kubectl -Arguments @(
    "-n",
    $ArgoCdNamespace,
    "annotate",
    $Kind,
    $Name,
    "argocd.argoproj.io/refresh=hard",
    "--overwrite"
  ) | Out-Null
}

function Wait-ForApplication {
  param(
    [string] $Name,
    [string] $ExpectedRevision,
    [switch] $RequireHealthy
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    $application = Get-ArgoApplication -Name $Name
    if ($null -ne $application) {
      $revisionOk = [string]::IsNullOrWhiteSpace($ExpectedRevision) -or
        $application.status.sync.revision -eq $ExpectedRevision
      $syncOk = $application.status.sync.status -eq "Synced"
      $healthOk = -not $RequireHealthy -or $application.status.health.status -eq "Healthy"

      if ($revisionOk -and $syncOk -and $healthOk) {
        return $application
      }
    }

    Start-Sleep -Seconds 5
  }

  throw "Timed out waiting for ArgoCD Application $Name to reach the requested state."
}

function Get-GeneratedChildApplications {
  param([string] $Name)

  $applications = (
    Invoke-Kubectl -Arguments @("-n", $ArgoCdNamespace, "get", "applications", "-o", "json") |
      ConvertFrom-Json
  ).items
  $children = @(
    $applications |
      Where-Object {
        $_.metadata.PSObject.Properties["ownerReferences"] -and
        ($_.metadata.ownerReferences |
          Where-Object { $_.kind -eq "ApplicationSet" -and $_.name -eq $Name }
        )
      } |
      ForEach-Object { $_.metadata.name } |
      Sort-Object
  )
  if ($children.Count -gt 0) {
    return $children
  }

  return @(
    $applications |
      Where-Object { $_.metadata.name -like "$Name-*" } |
      ForEach-Object { $_.metadata.name } |
      Sort-Object
  )
}

if ([string]::IsNullOrWhiteSpace($Revision)) {
  $currentRoot = Get-ArgoApplication -Name $DeliveryRootApplication
  $repoUrl = $currentRoot.spec.source.repoURL
  $targetRevision = $currentRoot.spec.source.targetRevision
  if (-not [string]::IsNullOrWhiteSpace($repoUrl) -and
      -not [string]::IsNullOrWhiteSpace($targetRevision) -and
      $targetRevision -notmatch '^[0-9a-f]{40}$') {
    $remoteRevision = git ls-remote $repoUrl "refs/heads/$targetRevision" 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($remoteRevision)) {
      $Revision = ($remoteRevision -split "\s+")[0]
    }
  } elseif ($targetRevision -match '^[0-9a-f]{40}$') {
    $Revision = $targetRevision
  }
}

Request-ArgoRefresh -Kind application -Name $DeliveryRootApplication
$root = Wait-ForApplication -Name $DeliveryRootApplication -ExpectedRevision $Revision
Write-Host "$DeliveryRootApplication is Synced at $($root.status.sync.revision)."

if ([string]::IsNullOrWhiteSpace($ApplicationName)) {
  return
}

$applicationSetExists = $true
try {
  Request-ArgoRefresh -Kind applicationset -Name $ApplicationName
} catch {
  $applicationSetExists = $false
}

if ($applicationSetExists) {
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $children = @()
  while ((Get-Date) -lt $deadline -and $children.Count -eq 0) {
    $children = Get-GeneratedChildApplications -Name $ApplicationName
    if ($children.Count -eq 0) {
      Start-Sleep -Seconds 5
    }
  }
  if ($children.Count -eq 0) {
    throw "ApplicationSet $ApplicationName did not create any child Applications."
  }
} else {
  $children = @($ApplicationName)
}

foreach ($child in $children) {
  Request-ArgoRefresh -Kind application -Name $child
  $childApplication = Wait-ForApplication -Name $child -RequireHealthy
  Write-Host "$child is $($childApplication.status.sync.status)/$($childApplication.status.health.status)."
}
