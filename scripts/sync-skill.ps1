<#
.SYNOPSIS
    Sync the single-source operator skill to every discovery location.

.DESCRIPTION
    The same Factorio NPC operator playbook must physically exist at
    several fixed paths so that different agent runtimes can discover it:

      - CLAUDE.md                                          (canonical source; Claude Code)
      - AGENTS.md                                          (Codex / OpenAI agents)
      - .claude/skills/factorio-npc/SKILL.md               (Claude skills loader)
      - .claude-plugin/plugins/factorio-npc/skills/...     (Claude Desktop plugin)

    Editing four copies by hand drifts them out of sync (and historically
    introduced encoding corruption). Edit CLAUDE.md only, then run this
    script to mirror it byte-for-byte to the other three locations.

    The MCP server (mcp/factorio_npc_mcp.py) loads one of these files at
    startup for its `instructions` field, so keeping them identical means
    the agent always sees the same playbook regardless of runtime.

.PARAMETER Check
    Verify the copies match the canonical source without writing. Exits
    non-zero if any copy is out of date. Useful for CI / pre-commit.
#>
[CmdletBinding()]
param(
    [switch]$Check
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$canonical = Join-Path $root 'CLAUDE.md'

$targets = @(
    Join-Path $root 'AGENTS.md'
    Join-Path $root '.claude/skills/factorio-npc/SKILL.md'
    Join-Path $root '.claude-plugin/plugins/factorio-npc/skills/factorio-npc/SKILL.md'
)

if (-not (Test-Path $canonical)) {
    throw "Canonical skill file not found: $canonical"
}

$sourceHash = (Get-FileHash $canonical).Hash
$drift = @()

foreach ($target in $targets) {
    $rel = $target.Substring($root.Length).TrimStart('\', '/')
    $exists = Test-Path $target
    $matches = $exists -and ((Get-FileHash $target).Hash -eq $sourceHash)

    if ($Check) {
        if ($matches) {
            Write-Host "ok    $rel"
        }
        else {
            Write-Host "DRIFT $rel" -ForegroundColor Yellow
            $drift += $rel
        }
        continue
    }

    if ($matches) {
        Write-Host "unchanged  $rel"
    }
    else {
        $dir = Split-Path -Parent $target
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        Copy-Item -LiteralPath $canonical -Destination $target -Force
        Write-Host "synced     $rel" -ForegroundColor Green
    }
}

if ($Check -and $drift.Count -gt 0) {
    Write-Host ""
    Write-Host "$($drift.Count) file(s) out of sync. Run scripts/sync-skill.ps1 to fix." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Canonical: CLAUDE.md  ($sourceHash)"
