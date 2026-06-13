# Inspect a single save: stop server, swap save in, start server, query Botty
# inventory + tick + entity counts, then leave running.
#
# Usage: .\scripts\inspect-save.ps1 -SaveFile _autosave3.zip
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SaveFile
)
$ErrorActionPreference = 'Stop'

$repoRoot   = Split-Path -Parent $PSScriptRoot
$serverRoot = Join-Path $repoRoot '.factorio-server'
$saves      = Join-Path $serverRoot 'saves'
$quarantine = Join-Path $saves 'quarantine-fresh-1230am'

# Find the save file (in saves/ or quarantine/)
$src = $null
foreach ($d in @($saves, $quarantine)) {
    $p = Join-Path $d $SaveFile
    if (Test-Path $p) { $src = $p; break }
}
if (-not $src) { throw "save not found: $SaveFile" }

# Stop any running factorio
Get-Process factorio -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 3

# Swap save in (and touch so "newest-save" logic picks it)
$dst = Join-Path $saves 'npc-world.zip'
Copy-Item $src $dst -Force
(Get-Item $dst).LastWriteTime = Get-Date

Write-Host "==> inspecting: $SaveFile  ($([math]::Round((Get-Item $src).Length/1KB,1)) KB, mtime $((Get-Item $src).LastWriteTime))"

# Start server in background
$exe = 'C:\Program Files (x86)\Steam\steamapps\common\Factorio\bin\x64\factorio.exe'
$cfg = Join-Path $serverRoot 'config\config.ini'
$ss  = Join-Path $serverRoot 'server-settings.json'
$envFile = Join-Path $repoRoot '.env'
$rcon = (Select-String -Path $envFile -Pattern '^RCON_PASSWORD=(.*)$').Matches.Groups[1].Value
$proc = Start-Process -FilePath $exe -ArgumentList @(
    '--config', $cfg,
    '--start-server', $dst,
    '--server-settings', $ss,
    '--rcon-bind', '127.0.0.1:27015',
    '--rcon-password', $rcon
) -PassThru -WindowStyle Hidden

# Wait for RCON to be reachable
$apiKey = (Select-String -Path $envFile -Pattern '^API_KEY=(.*)$').Matches.Groups[1].Value
$h = @{ 'X-API-Key' = $apiKey }
$ready = $false
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 1
    try {
        $body = @{command='/sc rcon.print("ready")'} | ConvertTo-Json -Compress
        $r = Invoke-RestMethod -Uri http://127.0.0.1:8000/execute_command `
              -Method Post -Headers $h -ContentType 'application/json' -Body $body -TimeoutSec 3
        if ($r.result -match 'ready') { $ready = $true; break }
    } catch { }
}
if (-not $ready) { throw "server did not come up within 30s" }

# Burn the achievements-warning first hit
$body = @{command='/sc rcon.print(game.tick)'} | ConvertTo-Json -Compress
Invoke-RestMethod -Uri http://127.0.0.1:8000/execute_command `
    -Method Post -Headers $h -ContentType 'application/json' -Body $body | Out-Null

function Call($cmd) {
    $body = @{command=$cmd} | ConvertTo-Json -Compress
    (Invoke-RestMethod -Uri http://127.0.0.1:8000/execute_command `
        -Method Post -Headers $h -ContentType 'application/json' -Body $body).result
}

Write-Host "--- tick ---"
Call '/sc rcon.print(game.tick)'

Write-Host "--- npc list ---"
Call '/sc rcon.print(remote.call("npc","list"))'

# Inventory + furnace count via direct Lua (works even if multi-NPC fns aren't loaded yet)
Write-Host "--- inventory + world entities ---"
$probe = @'
/sc local p = game.forces.player.get_spawn_position(game.surfaces.nauvis)
local inv_lines = {}
for _, c in pairs(game.surfaces.nauvis.find_entities_filtered{type="character"}) do
  local mi = c.get_inventory(defines.inventory.character_main)
  local contents = mi and mi.get_contents() or {}
  local parts = {}
  for _, it in ipairs(contents) do parts[#parts+1] = it.name.."="..it.count end
  table.insert(inv_lines, c.name..": {"..table.concat(parts, ", ").."}")
end
local furn = game.surfaces.nauvis.count_entities_filtered{type="furnace"}
local drills = game.surfaces.nauvis.count_entities_filtered{type="mining-drill"}
local chests = game.surfaces.nauvis.count_entities_filtered{type="container"}
rcon.print("furnaces="..furn.." drills="..drills.." chests="..chests.." | "..table.concat(inv_lines, " || "))
'@
Call $probe
Write-Host ""
Write-Host "==> done. server is RUNNING on $SaveFile -- stop manually when finished."
