#!/usr/bin/env pwsh
<#
.SYNOPSIS
Cleanup script to remove a Backstage delivery application following a proper PR workflow.

.DESCRIPTION
This script automates the removal of:
1. ArgoCD delivery desired state
2. Backstage generated descriptor
3. Catalog index entries
4. Maintains .keep file if this is the last application

Creates a feature branch from the specified base branch and prepares it for PR submission.

.PARAMETER AppName
The name of the application to remove (e.g., "kind-store-demo")

.PARAMETER BaseBranch
The base branch to create cleanup branch from (default: "zhangchl007-arc-multi-cluster-access")

.PARAMETER CreatePR
Automatically create a PR using GitHub CLI (gh) after pushing changes

.EXAMPLE
.\cleanup-app.ps1 -AppName "kind-store-demo"

.\cleanup-app.ps1 -AppName "kind-store-demo" -BaseBranch "main" -CreatePR
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$AppName,
    
    [Parameter(Mandatory = $false)]
    [string]$BaseBranch = "zhangchl007-arc-multi-cluster-access",
    
    [Parameter(Mandatory = $false)]
    [switch]$CreatePR
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"

$cleanupBranch = "manual-cleanup/$AppName"
$catalogFile = "backstage/catalog/catalog-info.yaml"
$argocdDeliveryPath = "gitops/apps/backstage-delivery/$AppName"
$backstageGeneratedPath = "backstage/generated/$AppName"

Write-Host "🧹 App Cleanup Workflow" -ForegroundColor Cyan
Write-Host "================================" -ForegroundColor Cyan
Write-Host "App Name:     $AppName" -ForegroundColor White
Write-Host "Base Branch:  $BaseBranch" -ForegroundColor White
Write-Host "Cleanup Br:   $cleanupBranch" -ForegroundColor White
Write-Host "================================" -ForegroundColor Cyan
Write-Host ""

# Step 1: Save current branch and setup
Write-Host "📦 Step 1: Repository setup..." -ForegroundColor Yellow
$currentBranch = git rev-parse --abbrev-ref HEAD
Write-Host "   Current branch: $currentBranch" -ForegroundColor Gray

git fetch origin
if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ Failed to fetch from origin" -ForegroundColor Red
    exit 1
}

git switch $BaseBranch
if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ Failed to switch to base branch: $BaseBranch" -ForegroundColor Red
    exit 1
}

git pull origin $BaseBranch --ff-only
if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ Failed to pull latest from $BaseBranch" -ForegroundColor Red
    exit 1
}

Write-Host "   ✓ Updated $BaseBranch" -ForegroundColor Green

# Create cleanup branch from base branch
git branch -D $cleanupBranch 2>$null
git switch -c $cleanupBranch
if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ Failed to create cleanup branch" -ForegroundColor Red
    exit 1
}

Write-Host "   ✓ Created feature branch: $cleanupBranch" -ForegroundColor Green
Write-Host ""

# Step 2: Remove ArgoCD delivery desired state
Write-Host "📦 Step 2: Removing ArgoCD delivery directory..." -ForegroundColor Yellow
if (Test-Path $argocdDeliveryPath) {
    git rm -r $argocdDeliveryPath
    Write-Host "   ✓ Removed: $argocdDeliveryPath" -ForegroundColor Green
} else {
    Write-Host "   ⚠️  Not found: $argocdDeliveryPath" -ForegroundColor Yellow
}
Write-Host ""

# Step 3: Remove Backstage generated descriptor
Write-Host "📦 Step 3: Removing Backstage generated directory..." -ForegroundColor Yellow
if (Test-Path $backstageGeneratedPath) {
    git rm -r $backstageGeneratedPath
    Write-Host "   ✓ Removed: $backstageGeneratedPath" -ForegroundColor Green
} else {
    Write-Host "   ⚠️  Not found: $backstageGeneratedPath" -ForegroundColor Yellow
}
Write-Host ""

# Step 4: Remove catalog index entry
Write-Host "📦 Step 4: Removing catalog index entry..." -ForegroundColor Yellow
if (Test-Path $catalogFile) {
    $catalogContent = Get-Content $catalogFile -Raw
    $pattern = "^\s*-\s+\.\./generated/$AppName/catalog-info\.yaml\s*$"
    $updatedContent = $catalogContent -replace $pattern, ""
    
    if ($updatedContent -ne $catalogContent) {
        Set-Content $catalogFile -Value $updatedContent -NoNewline
        git add $catalogFile
        Write-Host "   ✓ Removed entry from: $catalogFile" -ForegroundColor Green
    } else {
        Write-Host "   ⚠️  No matching entry found in catalog file" -ForegroundColor Yellow
    }
} else {
    Write-Host "   ❌ Catalog file not found: $catalogFile" -ForegroundColor Red
}
Write-Host ""

# Step 5: Maintain .keep file if this is the last application
Write-Host "📦 Step 5: Checking for remaining applications..." -ForegroundColor Yellow
$backstageDeliveryPath = "gitops/apps/backstage-delivery"
$remainingApps = @(Get-ChildItem $backstageDeliveryPath -Exclude ".keep" -ErrorAction SilentlyContinue).Count

if ($remainingApps -eq 0) {
    Write-Host "   ℹ️  This is the last application, ensuring .keep file exists..." -ForegroundColor Cyan
    New-Item -ItemType Directory -Force $backstageDeliveryPath | Out-Null
    New-Item -ItemType File -Force "$backstageDeliveryPath/.keep" | Out-Null
    git add "$backstageDeliveryPath/.keep"
    Write-Host "   ✓ .keep file created/maintained" -ForegroundColor Green
} else {
    Write-Host "   ℹ️  $remainingApps application(s) still present" -ForegroundColor Cyan
}
Write-Host ""

# Step 6: Show changes
Write-Host "📋 Changes Summary:" -ForegroundColor Yellow
Write-Host ""
git status --short
Write-Host ""
Write-Host "📝 Detailed diff:" -ForegroundColor Yellow
git diff --name-status
Write-Host ""

# Validate changes
Write-Host "✓ Validation:" -ForegroundColor Cyan
git diff --check
if ($LASTEXITCODE -eq 0) {
    Write-Host "   ✓ No trailing whitespace or other issues found" -ForegroundColor Green
}

Write-Host ""

# Step 7: Commit and push
Write-Host "📦 Step 7: Committing and pushing changes..." -ForegroundColor Yellow
git add -A
git commit -m "Remove $AppName demo application"
if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ Failed to commit changes" -ForegroundColor Red
    exit 1
}

git push -u origin $cleanupBranch
if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ Failed to push to origin" -ForegroundColor Red
    exit 1
}

Write-Host "   ✓ Pushed to: origin/$cleanupBranch" -ForegroundColor Green
Write-Host ""

# Step 8: Create PR
Write-Host "📦 Step 8: Creating pull request..." -ForegroundColor Yellow

if ($CreatePR) {
    $ghInstalled = gh --version 2>$null
    if ($LASTEXITCODE -eq 0) {
        gh pr create `
            --base $BaseBranch `
            --head $cleanupBranch `
            --title "Remove $AppName demo application" `
            --body "Cleanup: Removes $AppName demo application and associated resources`n`n- Removed ArgoCD delivery state`n- Removed Backstage generated descriptor`n- Updated catalog index"
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "   ✓ PR created successfully" -ForegroundColor Green
            Write-Host ""
            Write-Host "✅ Cleanup completed successfully!" -ForegroundColor Green
        } else {
            Write-Host "   ⚠️  Could not create PR via gh CLI, but branch is ready" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "🔗 Create PR manually:" -ForegroundColor Cyan
            Write-Host "   https://github.com/Azure-Samples/aks-platform-engineering/compare/$BaseBranch...$cleanupBranch" -ForegroundColor White
        }
    } else {
        Write-Host "   ⚠️  GitHub CLI (gh) not found, but branch is ready for PR" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "🔗 Create PR manually:" -ForegroundColor Cyan
        Write-Host "   https://github.com/Azure-Samples/aks-platform-engineering/compare/$BaseBranch...$cleanupBranch" -ForegroundColor White
    }
} else {
    Write-Host "   ℹ️  Skipping PR creation (use -CreatePR to auto-create)" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "🔗 Create PR manually:" -ForegroundColor Cyan
    Write-Host "   https://github.com/Azure-Samples/aks-platform-engineering/compare/$BaseBranch...$cleanupBranch" -ForegroundColor White
    Write-Host ""
    Write-Host "Or use this command to create PR via gh:" -ForegroundColor Cyan
    Write-Host "   gh pr create --base $BaseBranch --head $cleanupBranch --title 'Remove $AppName demo application'" -ForegroundColor Gray
}

Write-Host ""
Write-Host "✅ Cleanup workflow complete!" -ForegroundColor Green
