# Starts the FastAPI RCON-proxy backend. Loads .env from repo root.

[CmdletBinding()]
param(
    [string]$BindHost = '127.0.0.1',
    [int]$Port = 8000
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

if (-not (Test-Path .\.env)) {
    Write-Warning "No .env in repo root - copy .env.example to .env first."
}

python -m uvicorn backend.rcon_server:app --host $BindHost --port $Port
