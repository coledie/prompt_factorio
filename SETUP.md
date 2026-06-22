# Setup guide

End-to-end bring-up for `factorio_npc_mcp`: Factorio dedicated server with the
NPC mod, an HTTP→RCON backend, and Claude Desktop driving it all through MCP.

Architecture once running:

```
Claude Desktop  --stdio-->  MCP server (mcp/factorio_npc_mcp.py)
                              |
                              v  HTTP + X-API-Key
                            FastAPI backend (backend/rcon_server.py)
                              |
                              v  RCON TCP 127.0.0.1:27015
                            Factorio dedicated server  (-->  npc_mcp mod  -->  Botty)
                              ^
                              |  multiplayer (optional)
                            Your Steam Factorio GUI (you, the human player)
```

---

## 0. Prerequisites

- **Windows** with PowerShell 5.1+ (this repo's scripts are PowerShell).
- **Factorio** (Steam install with `factorio.exe` under
  `C:\Program Files (x86)\Steam\steamapps\common\Factorio\bin\x64\`).
  Tested on 2.0.76 with Space Age.
- **Python 3.10+** on PATH (`python --version`).
- **Claude Desktop** installed (`%APPDATA%\Claude\claude_desktop_config.json` exists).
- This repo cloned somewhere (these docs assume `C:\Users\<you>\Desktop\factorio_npc_mcp`).

---

## 1. One-time setup

Open PowerShell at the repo root.

### 1.1 Configure secrets

```powershell
Copy-Item .env.example .env
notepad .env
```

Set:
- `RCON_PASSWORD` — any random string. The Factorio server and backend will both use it.
- `API_KEY` — any random string. Backend and MCP server share it.
- Leave `RCON_HOST=127.0.0.1`, `RCON_PORT=27015`, `BACKEND_URL=http://127.0.0.1:8000`.

### 1.2 Install Python dependencies

```powershell
.\scripts\install-deps.ps1
```

Installs `fastapi`, `uvicorn`, `mcrcon`, `python-dotenv`, `fastmcp`, `httpx`.

### 1.3 Install the mod into your Steam Factorio GUI

Required if you want to **connect to the dedicated server as a player**
(see §2.5). `npc_mcp` is not on the mod portal, so Factorio's normal
"sync mods with server" flow can't fetch it — the client needs its own
copy with the exact same files. If you only ever drive Botty through
Claude and never watch in-game, you can skip this step.

```powershell
.\scripts\install-mod.ps1 -MatchServer
```

This:
1. Junctions `%APPDATA%\Factorio\mods\npc_mcp` → `mod\npc_mcp` (same source
   the server uses, so checksums match automatically).
2. Adds/enables `npc_mcp` in `%APPDATA%\Factorio\mods\mod-list.json`.
3. With `-MatchServer`: disables `space-age`, `quality`, and `elevated-rails`
   on the client. The server only loads `base + npc_mcp`, and Factorio
   refuses to multiplayer-join unless the enabled mod sets match exactly.
   Omit `-MatchServer` if you also play singleplayer with those DLCs and
   prefer to toggle them in the Mods menu yourself.

Re-run with `-Force` after pulling mod updates to refresh the junction.
Fully quit and relaunch Factorio so it picks up the change.

### 1.4 Register the MCP server in Claude Desktop

```powershell
.\scripts\register-claude.ps1
```

Adds a `factorio-npc` entry to `claude_desktop_config.json` (backing up the
existing file first) without disturbing any other MCP servers you already
have configured. The script pulls `API_KEY` and `BACKEND_URL` from your `.env`.

Then **fully quit Claude Desktop** (tray icon → Quit; closing the window
isn't enough) and reopen it.

---

## 2. Running the system

You need three things alive at the same time. Each one in its own terminal.

### 2.1 Terminal 1 — Factorio dedicated server

```powershell
.\scripts\start-factorio-server.ps1
```

First run does a one-time setup:
1. Creates `.factorio-server\` inside the repo (gitignored).
2. Writes a `config\config.ini` so this server uses its own data directory
   (won't fight your Steam Factorio for the `%APPDATA%\Factorio\.lock` file).
3. Junctions the `npc_mcp` mod into the server's mods folder and enables it
   in `mod-list.json`.
4. Generates a fresh save `npc-world.zip`.
5. Launches the server.

Wait until you see:

```
Hosting game at IP ADDR:({0.0.0.0:34197})
... changing state from(CreatingGame) to(InGame)
Starting RCON interface at IP ADDR:({127.0.0.1:27015})
```

Useful flags:
- `-Fresh` — delete the save and regenerate a new world.
- `-SaveName my-world` — use a different save file.
- `-RconPassword '...'` — override the password from `.env`.

### 2.2 Terminal 2 — backend (HTTP → RCON proxy)

```powershell
.\scripts\start-backend.ps1
```

Listens on `http://127.0.0.1:8000`. Single endpoint `POST /execute_command`
gated by `X-API-Key`.

### 2.3 Terminal 3 (optional) — sanity check the pipeline

```powershell
$k = (Select-String -Path .\.env -Pattern '^API_KEY=(.*)$').Matches.Groups[1].Value
$r = Invoke-RestMethod -Uri http://127.0.0.1:8000/execute_command -Method Post `
       -Headers @{'X-API-Key'=$k} -ContentType 'application/json' `
       -Body '{"command":"/sc rcon.print(remote.call(\"npc\",\"status\"))"}'
$r.result
```

Expected output: `{"ok":true,"exists":false}` (NPC not spawned yet).
If you see this, the **mod ↔ RCON ↔ backend** chain is healthy.

### 2.4 Drive from Claude Desktop

In Claude (after the restart from step 1.4), the tools below are now
available under the **`factorio-npc`** MCP server:

- `npc_spawn(name?, x?, y?, dx?, dy?)` — no player needs to be connected;
  if `x`/`y` are omitted and no player is in the game, Botty spawns at the
  nauvis force spawn point.
- `npc_despawn()`
- `npc_rename(name)`
- `npc_status()` — lightweight position/intent check.
- **`npc_observe(radius=16)`** — batched status + nearby entities +
  inventory + enemy count in one call. Prefer this over chaining
  status/look/inventory; each extra call costs a sim tick.
- `npc_walk(direction)` — `north` | `east` | `south` | `west`
- `npc_walk_to(x, y)`
- `npc_mine_at(x, y)`
- `npc_stop()`
- `npc_say(text)`
- `npc_look(radius=16)`
- `npc_inventory()`
- `npc_give(item, count, quality?)`

Try a prompt like:

> Use the factorio-npc tools to spawn the NPC, then make him say hello, walk
> 10 tiles east, and tell me what's around him.

You do **not** need to be connected to the server for this — Botty is a
detached character entity and the mod runs server-side. Connecting with
the Steam GUI (§2.5) is purely so you can watch.

### Giving Claude a Factorio playbook

The MCP server ships two **prompts** (Claude Desktop surfaces them in the
`+` / attachment menu → *Add from factorio-npc*):

- **`factorio_briefing`** — full operator playbook: a 1-minute Factorio
  primer, the v0 tool surface, a strict observe → orient → decide →
  confirm → act → report loop, output format ("Status / Scene /
  Proposal"), and hard rules (no surprise despawn, stop on enemies,
  re-observe every ~30 tiles).
- **`help_prompt`** — short quick-reference version.

**Recommended session start:**

1. New chat in Claude Desktop.
2. Click the `+` next to the input box → *Add from factorio-npc* →
   **`factorio_briefing`** → Submit.
3. Then say "go" (or "Botty, start the first-session checklist").

> ⚠️ **If you forget step 2, gameplay will be poor.** Claude Desktop
> does not auto-discover the briefing — without it the model will skip
> the schema-first planning step and produce broken layouts (drills on
> patch edges, belts dead-ending at chests with no inserter, drop tiles
> off by one). If you notice this mid-session, tell Claude verbatim:
> *"Read the `factorio_briefing` MCP prompt and the `npc_schema` tool,
> then restart the turn."* Re-attaching the prompt via the `+` menu
> works too.

Claude will run `npc_status` / `npc_look`, summarize the scene, and
propose its next move for you to confirm. Repeat. You stay in the loop
on every non-trivial action.

If you tweak the briefing in `mcp/factorio_npc_mcp.py`, fully quit and
reopen Claude Desktop so it re-reads the MCP server's prompts.

### 2.5 (Optional) Watch in-game

Prereq: you ran `.\scripts\install-mod.ps1` once (§1.3) so your GUI client
has `npc_mcp` installed and enabled with the same checksum as the server.

Launch Factorio normally through Steam → **Multiplayer → Connect to address
→ `127.0.0.1`**. You'll see Botty walking around, controlled by Claude.
Your WASD keys still drive only your own character — Botty is a separate
detached character entity.

**If connect fails with a mod mismatch:** the server only loads `base +
npc_mcp`, but a vanilla Steam install also has `space-age`, `quality`, and
`elevated-rails` enabled. Re-run `.\scripts\install-mod.ps1 -MatchServer`
to disable them on the client, then fully quit and relaunch Factorio.

**Spectator follow-cam (optional).** Once connected, you can fly around
freely instead of controlling your spawned character:

```
/c game.player.spectator = true        -- no collisions, ignored by biters
/c game.player.character = nil         -- detach: pan with arrow keys / mouse
```

Re-attach later with `/c game.player.create_character()`.

---

## 3. Shutdown

In any order:

- **Server (Terminal 1):** type `/quit` into the server console. *Don't* hard-close the window — it can corrupt the save mid-tick. The save is at `.factorio-server\saves\npc-world.zip` and auto-saves periodically anyway.
- **Backend (Terminal 2):** `Ctrl+C`.
- **Claude Desktop:** quit normally.
- **Steam Factorio GUI:** exit normally.

---

## 4. Common issues

### Botty seems to only move when I send RCON commands / the sim feels frozen

Factorio dedicated servers default to **`auto_pause: true`**, which freezes
the sim whenever zero players are connected. RCON commands still execute
during the pause, but each one advances roughly one tick, so polling
*looks* like it's the only way to make progress.

The launcher (`scripts/start-factorio-server.ps1`) now auto-generates a
`server-settings.json` with `auto_pause: false` on first run and passes
`--server-settings` to the server. If you upgraded from an older version:

1. Stop the server (`/quit`).
2. Delete `.factorio-server\server-settings.json` (or edit it and set
   `"auto_pause": false`).
3. Restart the server. You should see normal continuous simulation
   regardless of whether anyone is connected.

### `unknown interface: npc`
The mod isn't loaded in this game session.
- Check the server terminal for `Checksum for script __npc_mcp__/control.lua: ...` — it should appear during load.
- If you previously played a save without the mod and loaded it, mods may not be active. Use `-Fresh` to regenerate or load via "sync mods with save".

### I edited `control.lua` but my change has no effect
Factorio loads mod code when a save is loaded. After editing
`mod/npc_mcp/control.lua` (or bumping its version in `info.json`):
1. In the server terminal: `/quit`.
2. Relaunch: `.\scripts\start-factorio-server.ps1`.

No need to pass `-Fresh` — the existing save will re-load the updated mod.

### `no anchor player/character to spawn near`
You're on an old version of the mod. Pull the latest `control.lua` — spawn
now falls back to the force spawn point when no players are connected.
Reload the server after updating (see issue above).

### `[WinError 10061] target machine actively refused it`
RCON isn't listening. The dedicated server isn't running, or it's running
but stopped accepting connections. Check Terminal 1 — the server console
must be open and at `InGame` state.

```powershell
Get-NetTCPConnection -LocalPort 27015 -State Listen -ErrorAction SilentlyContinue
```

### `Couldn't create lock file ... Is another instance already running?`
You launched the dedicated server while your Steam Factorio GUI was open
*and* both were pointing at the same data dir. The launcher now generates
a separate `.factorio-server\config\config.ini` to avoid this. If you still
hit it, close one of the two and try again.

### `--rcon-port cannot be used with --rcon-bind`
You're on an old version of `start-factorio-server.ps1`. Pull the latest;
the script now passes only `--rcon-bind`.

### Claude Desktop reports a "syntax error in config"
PowerShell 5.1's `ConvertTo-Json` produces output Claude rejects. The repo
already routes JSON edits through Python (`scripts/_register_claude.py`).
If you edited the config by hand and broke it, restore the most recent
`claude_desktop_config.json.bak-*` next to it.

### Server console fills with `[WARNING] Player <server> tried using the command "..."`
Cosmetic only. Factorio logs every `/sc` invocation on a dedicated server.
The RCON response is unaffected — the JSON your tools return is clean.

### `empty response (is the npc_mcp mod loaded?)` from an MCP tool
The Lua call returned nothing. Either the mod isn't loaded (see first
issue) or you removed the `rcon.print(...)` wrapper from the call somehow.
Re-test with the sanity check in §2.3.

---

## 5. Repo layout reference

```
factorio_npc_mcp/
├─ mod/npc_mcp/                ← Factorio mod (control.lua, info.json)
├─ backend/                    ← FastAPI HTTP→RCON proxy
├─ mcp/                        ← FastMCP server with npc_* tools
├─ scripts/
│  ├─ install-deps.ps1
│  ├─ install-mod.ps1          ← junction into %APPDATA%\Factorio\mods (optional)
│  ├─ start-factorio-server.ps1
│  ├─ start-backend.ps1
│  ├─ start-mcp.ps1            ← only for standalone MCP testing; Claude launches it itself
│  ├─ register-claude.ps1      ← adds factorio-npc to Claude Desktop config
│  ├─ inspect-save.ps1         ← introspect a save file (see npcguides/SAVES.md)
│  ├─ sync-skill.ps1           ← mirror CLAUDE.md to the other skill copies
│  ├─ _register_claude.py      ← JSON-editing helper invoked by register-claude.ps1
│  ├─ _register_factorio_plugin.py ← manual one-off: register plugin globally (optional)
│  └─ _bench.py                ← manual dev utility: RCON latency benchmark (optional)
├─ .factorio-server/           ← gitignored: dedicated server's data dir
├─ .env.example
├─ .env                        ← gitignored: your secrets
├─ README.md
└─ SETUP.md                    ← this file
```
