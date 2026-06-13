# Symlinks (junction) the in-repo mod folder into Factorio's mods directory
# AND enables it in mod-list.json so the Steam GUI client can join the
# dedicated server (Factorio refuses to connect unless the client has the
# same mods; npc_mcp isn't on the portal, so no auto-sync).
#
# Run from an elevated PowerShell if Windows refuses to create the junction.
#
#   .\scripts\install-mod.ps1                 # default Factorio mods path
#   .\scripts\install-mod.ps1 -Force          # replace existing link/folder
#   .\scripts\install-mod.ps1 -MatchServer    # also disable space-age/quality/
#                                              # elevated-rails so the client
#                                              # can multiplayer-join the server
#   .\scripts\install-mod.ps1 -ModsDir 'D:\Factorio\mods'

[CmdletBinding()]
param(
    [string]$ModsDir = (Join-Path $env:APPDATA 'Factorio\mods'),
    [switch]$Force,
    [switch]$MatchServer
)

$ErrorActionPreference = 'Stop'

$repoRoot   = Split-Path -Parent $PSScriptRoot
$sourceMod  = Join-Path $repoRoot 'mod\npc_mcp'
$targetLink = Join-Path $ModsDir  'npc_mcp'
$modList    = Join-Path $ModsDir  'mod-list.json'

if (-not (Test-Path $sourceMod)) {
    throw "Source mod folder not found: $sourceMod"
}
if (-not (Test-Path $ModsDir)) {
    Write-Host "Creating Factorio mods directory: $ModsDir"
    New-Item -ItemType Directory -Path $ModsDir | Out-Null
}

# --- junction ----------------------------------------------------------------
$needLink = $true
if (Test-Path $targetLink) {
    $item = Get-Item $targetLink -Force
    $isJunction = $item.Attributes.ToString().Contains('ReparsePoint')
    $linkOk = $isJunction -and (Test-Path (Join-Path $targetLink 'info.json'))
    if ($linkOk -and -not $Force) {
        Write-Host "Junction already present: $targetLink"
        $needLink = $false
    } else {
        if (-not $Force -and -not $linkOk) {
            Write-Host "Replacing broken/non-junction entry at: $targetLink"
        }
        Remove-Item -LiteralPath $targetLink -Recurse -Force
    }
}
if ($needLink) {
    Write-Host "Creating junction: $targetLink  ->  $sourceMod"
    # PowerShell 5.1's `New-Item -ItemType Junction` is flaky for paths it
    # can't pre-resolve. cmd's mklink /J is reliable.
    & cmd /c mklink /J "`"$targetLink`"" "`"$sourceMod`"" | Out-Null
    if (-not (Test-Path (Join-Path $targetLink 'info.json'))) {
        throw "junction failed: $targetLink has no info.json after mklink"
    }
}

# --- enable in mod-list.json -------------------------------------------------
# Without this entry, Factorio loads the mod folder but leaves it disabled,
# and the multiplayer connect fails with a mod-mismatch error.
if (-not (Test-Path $modList)) {
    Write-Host "Creating fresh mod-list.json"
    $listObj = [pscustomobject]@{
        mods = @(
            [pscustomobject]@{ name = 'base';    enabled = $true }
            [pscustomobject]@{ name = 'npc_mcp'; enabled = $true }
        )
    }
} else {
    $listObj = Get-Content -Raw -LiteralPath $modList | ConvertFrom-Json
    if (-not $listObj.mods) {
        $listObj | Add-Member -NotePropertyName mods -NotePropertyValue @() -Force
    }
    $existing = $listObj.mods | Where-Object { $_.name -eq 'npc_mcp' }
    if ($existing) {
        if (-not $existing.enabled) {
            Write-Host "Enabling existing npc_mcp entry in mod-list.json"
            $existing.enabled = $true
        } else {
            Write-Host "npc_mcp already enabled in mod-list.json"
        }
    } else {
        Write-Host "Adding npc_mcp entry to mod-list.json"
        $listObj.mods = @($listObj.mods) + [pscustomobject]@{ name = 'npc_mcp'; enabled = $true }
    }
}

# --- optional: match server's loadout ---------------------------------------
# Server only loads `base + npc_mcp` (see scripts/start-factorio-server.ps1).
# Vanilla Steam installs ship space-age/quality/elevated-rails enabled, which
# causes Multiplayer -> Connect to fail with "mods are not identical". This
# flag disables those three on the client so the join succeeds.
if ($MatchServer) {
    $dlc = @('space-age','quality','elevated-rails')
    foreach ($m in $listObj.mods) {
        if ($dlc -contains $m.name -and $m.enabled) {
            Write-Host "Disabling $($m.name) (server doesn't load it)"
            $m.enabled = $false
        }
    }
}

$listObj | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $modList -Encoding UTF8

Write-Host ""
Write-Host "Done. If Factorio is open, fully quit and relaunch so it re-reads mods."
Write-Host "Then: Multiplayer -> Connect to address -> 127.0.0.1"
