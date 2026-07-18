#!/usr/bin/env pwsh
<#
.SYNOPSIS
Prepares a reviewed GitOps cleanup for a Backstage-delivered application.

.DESCRIPTION
Removes the Git-owned desired state for one Backstage-delivered application:
1. gitops/apps/backstage-delivery/<app>
2. backstage/generated/<app>
3. the matching target in backstage/catalog/catalog-info.yaml

The script does not delete live Kubernetes resources directly. ArgoCD prunes
them after the cleanup pull request is merged into the watched branch.

By default, this script prepares and stages the cleanup only. Use -Commit,
-Push, or -CreatePR explicitly for the later steps.

The script never merges the cleanup pull request and never enables auto-merge.
After -CreatePR, a platform reviewer must inspect and merge the PR manually.

.PARAMETER AppName
The Backstage-delivered application name to remove, for example kind-store-demo.

.PARAMETER BaseBranch
The protected ArgoCD-watched branch to target.

.PARAMETER Remote
The git remote that contains BaseBranch.

.PARAMETER Repository
The GitHub repository used when creating a PR with gh.

.PARAMETER Commit
Commit the staged cleanup changes after validation.

.PARAMETER Push
Commit, then push the cleanup branch to Remote.

.PARAMETER CreatePR
Commit, push, and create a pull request with gh. The PR is left open for manual
review and manual merge.

.PARAMETER SkipFetch
Skip git fetch. Intended for local validation only.

.EXAMPLE
.\scripts\cleanup-app.ps1 -AppName kind-store-demo

.EXAMPLE
.\scripts\cleanup-app.ps1 -AppName kind-store-demo -CreatePR
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9]([-a-z0-9]*[a-z0-9])?$')]
    [string]$AppName,

    [Parameter(Mandatory = $false)]
    [ValidatePattern('^[A-Za-z0-9._/-]+$')]
    [string]$BaseBranch = "zhangchl007-arc-multi-cluster-access",

    [Parameter(Mandatory = $false)]
    [ValidatePattern('^[A-Za-z0-9._/-]+$')]
    [string]$Remote = "origin",

    [Parameter(Mandatory = $false)]
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string]$Repository = "zhangchl007/aks-platform-engineering",

    [Parameter(Mandatory = $false)]
    [switch]$Commit,

    [Parameter(Mandatory = $false)]
    [switch]$Push,

    [Parameter(Mandatory = $false)]
    [switch]$CreatePR,

    [Parameter(Mandatory = $false)]
    [switch]$SkipFetch
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    & git --no-pager @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
}

function Get-GitOutput {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = & git --no-pager @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }

    return $output
}

function Assert-CleanWorktree {
    $status = @(Get-GitOutput @("status", "--porcelain"))
    if ($status.Count -gt 0) {
        throw "Working tree is not clean. Commit, stash, or discard unrelated changes before running cleanup."
    }
}

function Test-GitRef {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Ref
    )

    & git rev-parse --verify --quiet $Ref *> $null
    return $LASTEXITCODE -eq 0
}

$cleanupBranch = "manual-cleanup/$AppName"
$catalogFile = "backstage/catalog/catalog-info.yaml"
$argocdDeliveryPath = "gitops/apps/backstage-delivery/$AppName"
$backstageDeliveryPath = "gitops/apps/backstage-delivery"
$backstageGeneratedPath = "backstage/generated/$AppName"
$catalogTarget = "../generated/$AppName/catalog-info.yaml"
$baseRef = if ($SkipFetch.IsPresent) { $BaseBranch } else { "$Remote/$BaseBranch" }
$doCommit = $Commit.IsPresent -or $Push.IsPresent -or $CreatePR.IsPresent
$doPush = $Push.IsPresent -or $CreatePR.IsPresent

Write-Host "Backstage delivery cleanup"
Write-Host "App name:      $AppName"
Write-Host "Base ref:      $baseRef"
Write-Host "Cleanup branch:$cleanupBranch"
Write-Host ""

Assert-CleanWorktree

if (-not $SkipFetch.IsPresent) {
    Invoke-Git @("fetch", "--prune", $Remote, $BaseBranch)
}

if (-not (Test-GitRef $baseRef)) {
    throw "Base ref '$baseRef' was not found."
}

if (Test-GitRef "refs/heads/$cleanupBranch") {
    throw "Cleanup branch '$cleanupBranch' already exists. Review or delete it manually before rerunning."
}

Invoke-Git @("switch", "-c", $cleanupBranch, $baseRef)

$changedPaths = New-Object System.Collections.Generic.List[string]

if (Test-Path -LiteralPath $argocdDeliveryPath) {
    Invoke-Git @("rm", "-r", "--", $argocdDeliveryPath)
    $changedPaths.Add($argocdDeliveryPath)
} else {
    Write-Host "Not found, skipping: $argocdDeliveryPath"
}

if (Test-Path -LiteralPath $backstageGeneratedPath) {
    Invoke-Git @("rm", "-r", "--", $backstageGeneratedPath)
    $changedPaths.Add($backstageGeneratedPath)
} else {
    Write-Host "Not found, skipping: $backstageGeneratedPath"
}

if (-not (Test-Path -LiteralPath $catalogFile)) {
    throw "Catalog file not found: $catalogFile"
}

$catalogLines = New-Object System.Collections.Generic.List[string]
$removedCatalogTarget = $false
foreach ($line in [System.IO.File]::ReadAllLines((Resolve-Path $catalogFile))) {
    if ($line.Trim() -eq "- $catalogTarget") {
        $removedCatalogTarget = $true
        continue
    }

    $catalogLines.Add($line)
}

if ($removedCatalogTarget) {
    [System.IO.File]::WriteAllLines((Resolve-Path $catalogFile), $catalogLines, [System.Text.UTF8Encoding]::new($false))
    Invoke-Git @("add", "--", $catalogFile)
    $changedPaths.Add($catalogFile)
} else {
    Write-Host "No matching Catalog target found: $catalogTarget"
}

$remainingAppDirectories = @()
if (Test-Path -LiteralPath $backstageDeliveryPath) {
    $remainingAppDirectories = @(Get-ChildItem -LiteralPath $backstageDeliveryPath -Directory -ErrorAction Stop)
}

if ($remainingAppDirectories.Count -eq 0) {
    New-Item -ItemType Directory -Force $backstageDeliveryPath | Out-Null
    New-Item -ItemType File -Force "$backstageDeliveryPath/.keep" | Out-Null
    Invoke-Git @("add", "--", "$backstageDeliveryPath/.keep")
    $changedPaths.Add("$backstageDeliveryPath/.keep")
}

$stagedChanges = @(Get-GitOutput @("diff", "--cached", "--name-only"))
if ($stagedChanges.Count -eq 0) {
    throw "No cleanup changes were staged for '$AppName'. Check the application name and Git state."
}

Invoke-Git @("diff", "--cached", "--check")

Write-Host ""
Write-Host "Staged cleanup changes:"
Invoke-Git @("diff", "--cached", "--name-status")

if (-not $doCommit) {
    Write-Host ""
    Write-Host "Cleanup is staged but not committed."
    Write-Host "Review the diff, then commit and open a PR into '$BaseBranch'."
    exit 0
}

$commitMessage = @"
Remove $AppName demo application

Cleanup removes the Git-owned Backstage delivery state for $AppName so ArgoCD can prune the generated Applications and workloads after review and merge.

Co-authored-by: Copilot App <223556219+Copilot@users.noreply.github.com>
"@

$commitMessagePath = Join-Path ([System.IO.Path]::GetTempPath()) ("cleanup-$AppName-commit-message.txt")
[System.IO.File]::WriteAllText($commitMessagePath, $commitMessage, [System.Text.UTF8Encoding]::new($false))
try {
    Invoke-Git @("commit", "-F", $commitMessagePath)
} finally {
    Remove-Item -LiteralPath $commitMessagePath -Force -ErrorAction SilentlyContinue
}

if ($doPush) {
    Invoke-Git @("push", "-u", $Remote, $cleanupBranch)
}

if ($CreatePR.IsPresent) {
    & gh --version *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub CLI 'gh' is not available. The branch was pushed; create the PR manually."
    }

    $pullRequestBody = @{
        title = "Remove $AppName demo application"
        head = $cleanupBranch
        base = $BaseBranch
        body = "Cleanup removes $AppName from Git-owned Backstage delivery state: delivery manifest, generated Catalog descriptor, and Catalog index target. This script does not merge the PR or enable auto-merge; a platform reviewer must inspect and merge it manually. ArgoCD will prune live resources only after the reviewed PR is merged."
        maintainer_can_modify = $true
    } | ConvertTo-Json

    $pullRequestBody | gh api "repos/$Repository/pulls" --method POST --input -
    if ($LASTEXITCODE -ne 0) {
        throw "gh REST pull request creation failed."
    }
}

Write-Host ""
if ($CreatePR.IsPresent) {
    Write-Host "Pull request created only. Review and merge it manually; auto-merge was not enabled."
}
Write-Host "Cleanup workflow finished."
