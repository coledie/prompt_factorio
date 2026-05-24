# Symlinks (junction) the in-repo mod folder into Factorio's mods directory.
# Run from an elevated PowerShell if Windows refuses to create the junction.
#
#   .\scripts\install-mod.ps1                 # default Factorio mods path
#   .\scripts\install-mod.ps1 -Force          # replace existing link/folder
#   .\scripts\install-mod.ps1 -ModsDir 'D:\Factorio\mods'

[CmdletBinding()]
param(
    [string]$ModsDir = (Join-Path $env:APPDATA 'Factorio\mods'),
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$repoRoot   = Split-Path -Parent $PSScriptRoot
$sourceMod  = Join-Path $repoRoot 'mod\npc_mcp'
$targetLink = Join-Path $ModsDir  'npc_mcp'

if (-not (Test-Path $sourceMod)) {
    throw "Source mod folder not found: $sourceMod"
}
if (-not (Test-Path $ModsDir)) {
    Write-Host "Creating Factorio mods directory: $ModsDir"
    New-Item -ItemType Directory -Path $ModsDir | Out-Null
}

if (Test-Path $targetLink) {
    if (-not $Force) {
        throw "$targetLink already exists. Re-run with -Force to replace."
    }
    Write-Host "Removing existing $targetLink"
    Remove-Item -LiteralPath $targetLink -Recurse -Force
}

Write-Host "Creating junction: $targetLink  ->  $sourceMod"
New-Item -ItemType Junction -Path $targetLink -Target $sourceMod | Out-Null

Write-Host "Done. Enable 'npc_mcp' in Factorio's Mods menu (or edit mod-list.json)."
