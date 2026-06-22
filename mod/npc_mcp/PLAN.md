# `npc_mcp` mod — implementation plan

> **Status: implementation plan / design reference.** The behaviour
> described here is implemented in [control.lua](control.lua); this file
> is the design rationale, not a TODO list.

This mod is the Factorio-side half of the agent. It owns persistent state,
runs the per-tick dispatcher, and exposes a single RCON-callable remote
interface (`remote.call("npc", fn, ...)`). The MCP server emits raw Lua
over RCON; this file is what catches it.

The goal: **Claude Desktop drives a fully autonomous Factorio character
on a headless server with no Steam GUI ever opened.**

---

## Constraints

- No connected `LuaPlayer` ever — `game.players[1]` is nil. The agent is a
  detached `LuaCharacter` stored in `storage.npc.entity`.
- RCON commands are one-shot; anything continuous (walking, mining,
  crafting timer, combat) must live in `on_tick`.
- Claude is blind between calls — every remote function returns a JSON
  string via `rcon.print` so one round-trip carries useful state.
- Server runs with `auto_pause=false` (see `start-factorio-server.ps1`),
  so the sim advances with zero players connected.

---

## Architecture inside the mod

```
storage.npc = {
  entity        = LuaEntity,         -- the character, created on_init
  intent        = { kind, ... },     -- current high-level goal
  path          = { waypoints, i },  -- async pathfind result
  mine_target   = {x,y} | nil,       -- per-tick mining_state target
  craft_queue   = [ {recipe, count, time_left} ],
  build_queue   = [ ... ],
  events        = [ {tick, kind, data} ],  -- ring buffer, drained by MCP
  config        = { auto_flee_radius, ... },
  map           = { charted_patches = {...} },
}
```

`script.on_tick` dispatches in this order each tick:

1. `drive_walking()` — if `intent.kind == "walk"` or `intent.kind == "walk_to"`, set `character.walking_state` toward the next waypoint.
2. `drive_mining()` — if `intent.kind == "mine"`, set `character.mining_state`.
3. `drive_crafting()` — decrement `craft_queue[1].time_left`; finalize on 0.
4. `drive_safety()` — if `find_enemy_units(pos, auto_flee_radius)` non-empty, push `flee` event.

`script.on_init` creates Botty at the nauvis force spawn point so the
agent exists the moment the server boots — no human action required.

`script.on_load` re-binds nothing (storage refs survive); just used to
keep the engine happy.

---

## Remote interface surface (`remote.add_interface("npc", { ... })`)

Each function returns a JSON string the MCP server parses.

### Lifecycle
- `spawn(opts)` — create / return existing Botty.
- `despawn()` — destroy entity.
- `rename(name)` — update nameplate via `entity.color` / chat tag.
- `status()` — lightweight existence/position/intent check.
- `save(name?)` — `game.server_save(...)`.

### Perception
- `observe(radius)` — combined: position, hp, intent, inventory, nearby
  entities (grouped by `type`), enemy_count, daytime, tick.
- `look(radius)` — nearby entities only.
- `look_at(x, y, radius)` — perception anchored at arbitrary point.
- `inventory()` — main + ammo + armor + guns + trash.
- `chart(x, y, radius)` — reveal map via `force.chart`, no movement.
- `map_summary()` — charted resource patches.
- `tech_tree(filter?)` — researchable techs with prereqs satisfied.
- `research_status()` — current research + queue + progress.
- `drain_events()` — return + clear `storage.npc.events`.
- `screenshot(opts)` — `game.take_screenshot{path="botty/..."}`; MCP
  fetches the PNG from the backend's `/screenshot/{name}` route.

### Movement
- `walk(direction)` — continuous cardinal walk until stopped.
- `walk_to(x, y)` — pathfind via `surface.request_path`, then drive
  per-tick. Auto-stops on arrival / failure / enemy proximity.
- `stop()` — clears intent.

### Resource gathering
- `mine_at(x, y)` — pathfind to within reach, then per-tick `mining_state`.
- `mine_patch(name, count)` — find nearest resource tile of that name in
  charted area, mine it, repeat until count reached or patch exhausted.
- `chop_nearest(count)` — same pattern for trees.
- `pickup(x, y)` — mine a placed entity to return it to inventory.

### Crafting (simulated; we don't have a `LuaPlayer.begin_crafting`)
- `craft(recipe, count)` — validates `force.recipes[recipe].enabled` and
  ingredient availability, then enqueues. `drive_crafting` consumes
  ingredients atomically and inserts products when `time_left` hits 0.
- `craft_status()` — queue + ETAs.
- `cancel_craft(index)` — drop entry; no refund of consumed ingredients.

### Building / placement
- `place(item, x, y, direction?)` — consume item from inventory,
  `surface.can_place_entity` then `create_entity{... , raise_built=true}`.
- `rotate(x, y, direction)` — `entity.direction = d` on rotatable entity.
- `set_recipe(x, y, recipe)` — for assembling machines.

### Logistics
- `insert_into(x, y, item, count)` — into container/machine at point.
- `take_from(x, y, item, count)` — opposite.
- `fuel(x, y, fuel?, count?)` — convenience wrapper for burner fuel slot.

### Research
- `research(tech)` — append to `force.research_queue`.

### Combat
- `equip(armor?, gun?, ammo?)` — manage character armor/guns/ammo slots.
- `shoot_at(x, y)` — per-tick `shooting_state` selected target.

### Cheats (gated; need explicit human approval)
- `give(item, count, quality?)` — direct insert into Botty's inventory.
- `force_unlock(tech?)` — research tech instantly or all if `tech == nil`.

---

## Event push channel

The mod subscribes to:

- `on_entity_died` (filtered to Botty)
- `on_research_finished`
- `on_chunk_charted`
- `on_script_path_request_finished`
- `on_pre_player_died` (informational)
- `on_player_mined_entity` / `on_robot_mined_entity` (when relevant)

Each handler appends a `{tick, kind, data}` to `storage.npc.events`.
The MCP server periodically calls `npc_drain_events()` to consume the
buffer. Later we can promote this to an SSE stream the backend tails
from a script-output file so Claude can `wait_for_event(...)`.

---

## Implementation order (working build → richer build)

1. **info.json** + skeleton `control.lua` with `spawn`, `status`, `stop`.
2. `observe` (Claude's bread and butter).
3. `walk_to` with `request_path` + per-tick driver.
4. `mine_at` + `mine_patch` + `chop_nearest`.
5. Crafting queue.
6. `place`, `rotate`, `set_recipe`.
7. Logistics: `insert_into`, `take_from`, `fuel`.
8. Research + tech_tree.
9. Events buffer + `drain_events`.
10. `screenshot` + backend route.
11. Combat: `equip`, `shoot_at`.
12. Save / chart / map_summary.

Anything not in the running mod is documented as `not_implemented` in
the returned JSON so Claude knows.
