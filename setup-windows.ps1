#Requires -Version 5.1
<#
.SYNOPSIS
    Scaffolds the SmartOps-Lite project folder structure on Windows.

.DESCRIPTION
    Creates the standard folder tree at the given path (or the caller's
    current directory) and writes placeholder .gitkeep files so empty
    folders are checkable into git.

    This script is IDEMPOTENT — safe to run multiple times.

.PARAMETER RootPath
    Where to create the smartops-lite tree.
    Default: C:\Users\dhanym\Documents\personal\Project

.EXAMPLE
    .\setup-windows.ps1

.EXAMPLE
    .\setup-windows.ps1 -RootPath "D:\projects"
#>

[CmdletBinding()]
param(
    [string]$RootPath = "$env:USERPROFILE\Documents\personal\Project"
)

$ErrorActionPreference = "Stop"
$ProjectName = "smartops-lite"
$ProjectRoot = Join-Path $RootPath $ProjectName

Write-Host "=== SmartOps-Lite scaffold ===" -ForegroundColor Cyan
Write-Host "Target: $ProjectRoot" -ForegroundColor Cyan
Write-Host ""

# ---- folder tree ---------------------------------------------------------
$folders = @(
    "apps\crashy-app",
    "dashboards\grafana",
    "docs\adr",
    "docs\curriculum",
    "docs\diagrams",
    "docs\modules",
    "infra\modules",
    "infra\envs\dev",
    "controller\src",
    "controller\tests",
    "lambdas\rca-generator",
    "lambdas\remediator",
    "lambdas\mttr-aggregator",
    "helm\crashy-app",
    "helm\smartops-controller",
    "scripts",
    ".github\workflows"
)

foreach ($f in $folders) {
    $full = Join-Path $ProjectRoot $f
    if (-not (Test-Path $full)) {
        New-Item -ItemType Directory -Path $full -Force | Out-Null
        Write-Host "  created  $f" -ForegroundColor Green
    } else {
        Write-Host "  exists   $f" -ForegroundColor DarkGray
    }

    # keep empty folders trackable in git
    $keep = Join-Path $full ".gitkeep"
    if (-not (Test-Path $keep)) { New-Item -ItemType File -Path $keep | Out-Null }
}

Write-Host ""
Write-Host "Folder scaffold complete." -ForegroundColor Green
Write-Host ""

# ---- prerequisite checks --------------------------------------------------
Write-Host "=== Prerequisite checks ===" -ForegroundColor Cyan

$checks = @(
    @{ Name = "WSL";            Cmd = "wsl.exe";      Args = "--status" },
    @{ Name = "Git";            Cmd = "git";          Args = "--version" },
    @{ Name = "Docker Desktop"; Cmd = "docker";       Args = "--version" }
)

$missing = @()
foreach ($c in $checks) {
    try {
        $out = & $c.Cmd $c.Args 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host ("  [OK]   {0,-16} {1}" -f $c.Name, ($out -join ' ').Substring(0, [Math]::Min(60, ($out -join ' ').Length))) -ForegroundColor Green
        } else {
            Write-Host ("  [X]    {0}" -f $c.Name) -ForegroundColor Red
            $missing += $c.Name
        }
    } catch {
        Write-Host ("  [X]    {0}" -f $c.Name) -ForegroundColor Red
        $missing += $c.Name
    }
}

Write-Host ""
if ($missing.Count -gt 0) {
    Write-Host "Missing prerequisites: $($missing -join ', ')" -ForegroundColor Yellow
    Write-Host "See docs\INSTALL.md section 2B (Windows/WSL) for install steps." -ForegroundColor Yellow
} else {
    Write-Host "All base prerequisites detected." -ForegroundColor Green
}

# ---- next-steps banner ----------------------------------------------------
Write-Host ""
Write-Host "=== Next steps ===" -ForegroundColor Cyan
Write-Host "1. cd '$ProjectRoot'"
Write-Host "2. In WSL: run 'make setup' to complete the toolchain install (docs\INSTALL.md section 2B)."
Write-Host "3. Set up AWS + Slack + Groq accounts (docs\INSTALL.md section 3)."
Write-Host "4. Run 'make module-0' to bootstrap the AWS backend + secrets + repo (docs\INSTALL.md section 5)."
Write-Host ""
Write-Host "Cost reminder: every session ends with 'make eod'. Billing alarm at \$5." -ForegroundColor Yellow
