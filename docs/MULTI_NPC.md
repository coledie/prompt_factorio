# Multi-NPC support

The mod and MCP server support multiple AI agents driving distinct
characters in one shared Factorio world. Each agent — typically a
separate Claude Desktop window — is bound to a single named NPC and
passes that name on every tool call.

---

## Architecture

```
┌──────────────────┐    ┌──────────────────┐
│ Claude Desktop A │    │ Claude Desktop B │
│  name = "Alice"  │    │  name = "Bravo"  │
└────────┬─────────┘    └────────┬─────────┘
         │ MCP stdio              │ MCP stdio
         ▼                        ▼
       ┌───────────────────────────────┐
       │   factorio_npc_mcp.py (one    │
       │   process per Claude window)  │
       └──────────────┬────────────────┘
                      │ HTTP (X-API-Key)
                      ▼
              ┌─────────────────┐
              │ rcon_server.py  │
              │   (FastAPI)     │
              └────────┬────────┘
                       │ RCON
                       ▼
             ┌──────────────────┐
             │ Factorio server  │
             │  + npc_mcp mod   │
             │                  │
             │ storage.npcs = { │
             │   Alice = {...}, │
             │   Bravo = {...}, │
             │ }                │
             └──────────────────┘
```

- **One Factorio server, one backend, one map.** Shared world.
- **One MCP server process per Claude Desktop window** (Claude Desktop
  spawns it as a stdio child). Both processes hit the same backend.
- **NPCs are keyed by name in `storage.npcs`** inside the mod. Each NPC
  has its own `entity`, `intent`, `path`, `events` queue, and
  `craft_queue`. No cross-talk.
- **Research is force-wide.** All NPCs are on the `"player"` force, so
  they share one tech tree. `research_finished` events fan out to every
  NPC's event queue.

---

## How a Claude session works

### 1. Agent asks for its name

The auto-injected operator briefing (`instructions=_BRIEFING` in
[mcp/factorio_npc_mcp.py](mcp/factorio_npc_mcp.py)) tells the agent:

> At the start of every session, ask the human: *"What is my NPC name?"*

The human replies with a string — e.g. `Alice`, `Bravo-7`, `Botty`.
That string is the agent's identity for the rest of the conversation.

### 2. Agent ensures it exists

```
npc_status(npc_name="Alice")
  -> {"exists": false, ...}

npc_spawn(npc_name="Alice")
  -> {"ok": true, "message": "spawned",
      "position": {"x": 3.0, "y": 0.0}, ...}
```

`npc_spawn` is idempotent — calling it on an existing NPC returns the
current position. The mod auto-spawns one default `Botty` on boot, so
solo sessions can skip the spawn call if they use that name.

When no spawn position is supplied, each new NPC is placed three tiles
east of the previous one to avoid stacking on the world spawn.

### 3. Every subsequent tool call carries the name

```
npc_observe(npc_name="Alice", radius=16)
npc_walk_to(npc_name="Alice", x=10, y=-5)
npc_craft(npc_name="Alice", recipe="iron-axe", count=1)
...
```

If the agent forgets, the mod responds:

```json
{"ok": false, "error": "npc_name is required (non-empty string)"}
```

If the agent passes a name that doesn't exist:

```json
{"ok": false,
 "error": "unknown npc 'Frank' — call npc_spawn('Frank') first"}
```

The briefing tells the agent to surface these verbatim to the human
rather than guessing.

---

## Tool reference

Every `npc_*` tool takes `npc_name` as its first required argument
**except**:

| Tool             | Why no `npc_name`                              |
|------------------|------------------------------------------------|
| `npc_list()`     | Lists all NPCs in the world (discovery tool).  |
| `npc_save(name)` | `game.server_save` snapshots the whole world.  |

### `npc_list()`

Returns every spawned NPC's name, alive status, position, and current
intent. Useful for an agent to:

- discover other agents in the world,
- verify its own NPC is still alive after a long absence,
- avoid mining a resource someone else is actively working.

```json
{
  "ok": true,
  "npcs": [
    {"name": "Alice", "alive": true, "position": {"x": 12.0, "y": -4.0}, "intent": "mine"},
    {"name": "Bravo", "alive": true, "position": {"x": 18.0, "y":  2.0}, "intent": "walk_to"},
    {"name": "Botty", "alive": false}
  ]
}
```

### Per-NPC event queues

`npc_drain_events(npc_name)` returns only events for that NPC. Movement,
mining, crafting, and path callbacks are routed by name through
`storage.path_requests[req_id] = npc_name` (for async pathfinder
results) and direct `push_event(self, ...)` calls (for everything else).

Force-wide events (`research_finished`, `chunk_charted`) are fanned out
to every NPC's queue.

---

## Running two Claude Desktops

### Option A — Single MCP entry, two windows

Easiest. Both windows share the same MCP server config; the only thing
that differs is what name the human assigns in each conversation.

In `%APPDATA%\Claude\claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "factorio-npc": {
      "command": "C:/path/to/python.exe",
      "args": ["C:/Users/coles/Desktop/prompt_factorio/mcp/factorio_npc_mcp.py"],
      "env": {
        "API_KEY": "...",
        "BACKEND_URL": "http://127.0.0.1:8000"
      }
    }
  }
}
```

1. Open Claude Desktop window #1 → tell it `Your NPC name is Alice`.
2. Open Claude Desktop window #2 (same install, new chat) → tell it
   `Your NPC name is Bravo`.

Each window runs its own `factorio_npc_mcp.py` child process, but both
hit the same backend and the same `storage.npcs` table.

### Option B — Pre-bound entries

If you want each window to start already knowing its name, register
multiple entries:

```json
{
  "mcpServers": {
    "factorio-npc-alice": { ... same command ... },
    "factorio-npc-bravo": { ... same command ... }
  }
}
```

Each chat still has to learn its name from the human (the env vars
aren't used for this), but the labels in Claude Desktop's UI make it
clear which window is which.

---

## Backwards compatibility

Existing single-NPC saves still work. On `ensure_storage()` the mod
detects an old `storage.npc` blob and migrates it to
`storage.npcs[<nameplate or "Botty">]`. The legacy key is then nilled
out.

If your save was generated before the rewrite and you just want to keep
playing as `Botty`:

1. Restart the Factorio server — the mod reloads and `ensure_storage()`
   runs the migration.
2. Tell Claude `Your NPC name is Botty` and proceed normally.

No data loss; the migration preserves the entity reference, intent,
path, craft queue, and event ring buffer.

---

## What the mod refuses to do

- **Two NPCs with the same name.** `npc_rename` fails if the new name
  is already taken. `npc_spawn` returns the existing character.
- **Despawn-by-name without confirmation.** The briefing forbids the
  agent from calling `npc_despawn` without explicit human approval —
  this is an LLM-level rule, not a mod-level one, but `npc_despawn` of
  the wrong name will return `unknown npc` rather than damage the wrong
  agent's character.

---

## Files touched

- [mod/npc_mcp/control.lua](mod/npc_mcp/control.lua) — rewrote storage
  to `storage.npcs[name]`, added `path_requests` routing table,
  added `fn_list`, made every public function take `npc_name` first,
  added migration shim, made `on_tick` iterate over all NPCs.
- [mcp/factorio_npc_mcp.py](mcp/factorio_npc_mcp.py) — every
  `@mcp.tool()` takes `npc_name: str` as its first required positional
  argument, with a `_require_name()` guard that returns a friendly
  error when the agent forgets. Added `npc_list()`. Updated the
  auto-injected briefing (`instructions=_BRIEFING`) to instruct the
  agent to ask for its name and pass it on every call.
