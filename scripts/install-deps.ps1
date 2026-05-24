# One-shot: install Python deps for both backend and MCP server.
# Uses the currently active Python; activate a venv first if you want isolation.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

python -m pip install -r backend\requirements.txt
python -m pip install -r mcp\requirements.txt
