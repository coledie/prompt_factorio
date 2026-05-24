# Registers the factorio_npc_mcp server into Claude Desktop's config.
# Delegates JSON manipulation to scripts/_register_claude.py because
# PowerShell 5.1's ConvertTo-Json produces output Claude Desktop rejects.
#
#   .\scripts\register-claude.ps1
#   .\scripts\register-claude.ps1 -Force
#   .\scripts\register-claude.ps1 -ServerName factorio-npc -ConfigPath '...'

[CmdletBinding()]
param(
    [string]$ServerName = 'factorio-npc',
    [string]$ConfigPath = (Join-Path $env:APPDATA 'Claude\claude_desktop_config.json'),
    [string]$PythonExe  = (Get-Command python).Source,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$repoRoot  = Split-Path -Parent $PSScriptRoot
$mcpScript = Join-Path $repoRoot 'mcp\factorio_npc_mcp.py'
$envFile   = Join-Path $repoRoot '.env'
$pyHelper  = Join-Path $PSScriptRoot '_register_claude.py'

foreach ($p in $mcpScript, $ConfigPath, $envFile, $pyHelper) {
    if (-not (Test-Path $p)) { throw "Missing: $p" }
}

# --- parse .env (KEY=VALUE per line, ignores comments/blanks) -----------------
$envVars = @{}
Get-Content $envFile | ForEach-Object {
    if ($_ -match '^\s*([^#=\s]+)\s*=\s*(.*?)\s*$') {
        $envVars[$Matches[1]] = $Matches[2]
    }
}
foreach ($k in 'API_KEY','BACKEND_URL') {
    if (-not $envVars.ContainsKey($k) -or [string]::IsNullOrWhiteSpace($envVars[$k])) {
        throw "$k missing from $envFile"
    }
}

$pyArgs = @(
    $pyHelper, $ConfigPath, $ServerName, $PythonExe, $mcpScript,
    $envVars['API_KEY'], $envVars['BACKEND_URL']
)
if ($Force) { $pyArgs += '--force' }

& python @pyArgs
if ($LASTEXITCODE -ne 0) { throw "register helper exited with $LASTEXITCODE" }

Write-Host ""
Write-Host "Restart Claude Desktop (right-click tray icon -> Quit, then reopen)."
