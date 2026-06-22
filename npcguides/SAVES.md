# Save management & recovery

Factorio dedicated-server saves live in
`.factorio-server/saves/`. This doc explains which file is which, how
saves get created, how to recover a lost session, and the guardrails
already wired into the scripts.

## The cast of files

| File                       | Created by                                  | When |
| -------------------------- | ------------------------------------------- | ---- |
| `npc-world.zip`            | `start-factorio-server.ps1` (default save name) | First boot creates it; **subsequent boots load whatever is newest by default**, see "Launch rules" below |
| `_autosave1.zip` .. `_autosaveN.zip` | Factorio itself, on a rolling buffer (default every 10 min) | While the server is running |
| `auto-<tick>.zip`          | The npc_mcp control script's auto-snapshot logic OR a leftover from a previous standalone session | Periodically |
| `<your-name>.zip`          | `npc_save("<your-name>")` (MCP tool) or `/sc game.server_save("<your-name>")` | On demand |
| `quarantine-fresh-*/`      | Recovery operations | When the operator quarantines suspect saves so the launcher won't pick them by accident |

Notes:
- **Different worlds (seeds) can coexist in the same folder.** A
  `-Fresh` boot deletes only `npc-world.zip`; older saves from prior
  worlds (including `auto-<tick>.zip` from earlier sessions) stay on
  disk and look identical at a glance.
- **File size is a weak hint at progress, not proof.** A fresh world
  is ~500 KB; an hour of play might only add a few KB. Check tick
  count and inventory, not bytes.

## Launch rules (built into `start-factorio-server.ps1`)

The launcher decides which save to load like this:

1. If `-Fresh` is passed: delete `npc-world.zip` and generate a brand
   new world. Loads the new `npc-world.zip`.
2. If `-ExactSave` is passed: loads `npc-world.zip` (or whatever
   `-SaveName` resolves to) exactly, even if older files exist.
3. **Default:** scans `saves/*.zip` and loads the file with the newest
   `LastWriteTime`. If that's not `npc-world.zip` it prints a yellow
   warning naming the file and how many seconds newer it is.

This is the guardrail. It exists because of the May 24 2026 incident
where a restart silently loaded a stale `npc-world.zip` and lost ~30
minutes of mining + furnace setup.

**You still have to read the warning.** If the newest save is the
wrong world (e.g. an `auto-<tick>.zip` left over from a previous
session), pass `-ExactSave` or rename the offender into the
quarantine folder.

## How to know which save has your real work

Run `scripts/inspect-save.ps1 -SaveFile <name.zip>`. It will:

1. Stop any running factorio process.
2. Copy the named save over `npc-world.zip` and start the server.
3. Print:
   - `game.tick` (how far into the world)
   - `npc list` (positions + intent of all NPCs)
   - **Inventory of every character entity** on Nauvis
   - **Counts** of furnaces, mining drills, and chests in the world
4. Leave the server running on that save so you can keep exploring it
   in a normal Claude session — or stop it and inspect another.

Decision rules:

- **High tick + non-empty inventory + non-zero furnace/drill count =
  real progress.** That's the save you want.
- **Tick < 1000 with zero furnaces/drills = a freshly-generated
  world.** Almost certainly not what you're looking for.
- **Same tick across two files = duplicates / consecutive snapshots.**
  Either is fine; the larger/newer is preferred.

## Recovery cookbook

### Symptom: "I restarted and my progress is gone"

```powershell
# 1. Stop the running server so saves don't keep mutating.
Get-Process factorio -ErrorAction SilentlyContinue | Stop-Process -Force

# 2. List every save sorted newest first.
Get-ChildItem .\.factorio-server\saves\*.zip |
    Sort-Object LastWriteTime -Descending |
    Select-Object Name, LastWriteTime, @{n='KB';e={[math]::Round($_.Length/1KB,1)}}

# 3. Inspect candidates one at a time. Start with the most recent autosave.
.\scripts\inspect-save.ps1 -SaveFile _autosave3.zip
# Look at the printed tick, inventory, and entity counts. Match against
# what you remember (e.g. "I had 113 stone and 3 furnaces").

# 4. Repeat with other candidates if it's not a match.
.\scripts\inspect-save.ps1 -SaveFile _autosave2.zip
.\scripts\inspect-save.ps1 -SaveFile <some-named-save>.zip

# 5. Once found, snapshot it under a clear name so you don't lose it again.
#    (Server must be running on that save.)
$k = (Select-String -Path .\.env -Pattern '^API_KEY=(.*)$').Matches.Groups[1].Value
$body = @{command='/sc game.server_save("phase1-recovered")'} | ConvertTo-Json -Compress
Invoke-RestMethod -Uri http://127.0.0.1:8000/execute_command `
    -Method Post -Headers @{'X-API-Key'=$k} `
    -ContentType 'application/json' -Body $body
```

### Symptom: "Two saves from different worlds are mixed in saves/"

Move the wrong-world files into a quarantine subfolder so the
"load newest" rule can't pick them by mistake:

```powershell
$qDir = ".\.factorio-server\saves\quarantine-$(Get-Date -Format yyyyMMdd-HHmm)"
New-Item -ItemType Directory -Path $qDir | Out-Null
Move-Item .\.factorio-server\saves\<wrong-file>.zip $qDir
```

Quarantined files are still there if you change your mind; they're
just out of the launcher's search path.

### Symptom: "I want to verify the running server is on the save I think it is"

Tick number is the source of truth:

```powershell
$k = (Select-String -Path .\.env -Pattern '^API_KEY=(.*)$').Matches.Groups[1].Value
$body = @{command='/sc rcon.print(game.tick)'} | ConvertTo-Json -Compress
(Invoke-RestMethod -Uri http://127.0.0.1:8000/execute_command `
    -Method Post -Headers @{'X-API-Key'=$k} `
    -ContentType 'application/json' -Body $body).result
```

Then `npc_status('Botty')` (or any NPC) for position + intent.

## Best practices going forward

- **Call `npc_save("<descriptive-name>")` at every meaningful
  milestone.** Names like `phase1-complete`, `before-rocket-launch`,
  `pre-biter-attack`. These survive `-Fresh`, restarts, and "load
  newest" picks.
- **Don't trust autosaves as your sole backup.** They roll over every
  ~30 min by default and the oldest is silently discarded.
- **Never run `-Fresh` without an explicit named save of the current
  world first.** `-Fresh` deletes `npc-world.zip` and leaves the
  autosaves from the previous world stranded with no canonical pointer.
- **If you see a yellow `Newer save detected:` warning at boot,
  read it.** It's either saving you (good) or about to load the wrong
  world (bad — pass `-ExactSave` to override).
- **Snapshot before any structural change** (restoring an old save,
  reloading mods, manual save shuffling). `game.server_save("pre-<X>")`
  costs ~1 second and a few hundred KB.
