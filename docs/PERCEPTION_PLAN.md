# Perception hardship — root causes and a plan

## What just happened

Botty was trying to find a stone patch. The sequence Claude actually ran:

1. `npc_map_summary` returned "stone exists somewhere within 128 tiles"
   — but only one `sample_position` per resource type, not the full set
   of tiles.
2. `npc_walk_to` → `arrived` near the sample point.
3. `npc_mine_at` on the sample tile → inventory still empty afterwards.
   The sample point landed on a non-mineable tile or an already-mined
   gap inside the patch.
4. `npc_look` came back with **iron-ore only** in its 25-entity sample
   per type (the rest of the resources were truncated by the cap).
5. Brute-force `npc_mine_at` at neighbouring guess coordinates — all
   missed.
6. Tried to read the world via screenshot — `npc_chart` +
   `npc_screenshot` produced a file, but Claude Desktop's URL fetch
   refused the connection.
7. Fell back to filesystem search tools — but those aren't allowed
   under "you are a player, not a developer."

End result: Claude flailed for many turns. Not a regression; the
perception toolset was always thin. We just stopped getting lucky.

## Why each failure happened

### 1. `npc_map_summary` is too coarse

It aggregates resource tiles by name and returns ONE
`sample_position`. For a stone patch with 100 tiles spread across a
20-tile region, you learn there's stone "near here" but not where to
actually mine. The sample point is whichever tile `pairs()` enumerated
first — effectively random.

### 2. `npc_look` and `npc_observe` truncate at 25 entries per type

Inside [mod/npc_mcp/control.lua](mod/npc_mcp/control.lua) the
`nearby_summary` helper replaces any group with >25 entries with a
sample slice. For dense resource patches this is exactly the wrong
truncation strategy — Claude needs the cluster boundaries, not 25
random tiles inside the cluster.

### 3. Screenshots are fundamentally unreachable from the agent

`game.take_screenshot` writes a PNG into
`.factorio-server/script-output/botty/`. The backend serves it at
`http://127.0.0.1:8000/screenshot/{name}`. **But Claude Desktop's URL
fetch tool runs server-side at Anthropic**, not on the user's machine.
`127.0.0.1` from Anthropic's egress is not the user's localhost, hence
`ECONNREFUSED`. We can't fix this with a port change — the entire
"fetch a URL from the agent" model is incompatible with a local
backend.

### 4. The 25-cap also silently dropped trees / stone / coal

`npc_look` returned only iron-ore in its sample because iron-ore tiles
happened to be enumerated last and crowded out the rest after the
group-level truncation kicked in. Whole resource types vanished from
Claude's view.

---

## Plan: text-first perception, image as backup

Goal: make the world legible to Claude through MCP text responses
alone. No browser fetches, no filesystem reads. Three additions to the
mod + MCP, ordered by impact.

### Phase 1 — `npc_find` (highest impact, smallest change)

A direct "nearest resource" lookup that returns actual mineable
positions.

**Mod side** (`control.lua`):

```lua
remote.add_interface fn_find(name, resource, radius)
```

- Scans `surface.find_entities_filtered{type="resource", name=resource}`
  (or by tile name for stone/oil) within `radius` of the NPC.
- Clusters adjacent tiles into patches via flood-fill on tile
  adjacency.
- Returns:
  ```json
  {"patches": [
     {"name": "stone", "center": {"x": 18, "y": -4},
      "tile_count": 87, "bounding_box": {...},
      "nearest_tile": {"x": 16, "y": -3}},
     ...
  ], "ok": true}
  ```
- `nearest_tile` is the closest mineable tile to the NPC, ready to
  hand to `npc_mine_at`.

**MCP side**:

```python
@mcp.tool()
def npc_find(npc_name, resource, radius=128) -> dict
```

Briefing addition: "to gather X, call `npc_find(npc_name, 'X')` and
walk to `result.patches[0].nearest_tile`, then `npc_mine_at` on it."

This alone replaces the entire flail sequence we just watched.

### Phase 2 — ASCII map (medium impact, medium change)

Render the world as a text grid Claude can read inline.

**Mod side**: new `fn_text_map(name, radius)`. Walks tiles in a
`(2r+1) × (2r+1)` square around the NPC. Each cell becomes one
character:

| char  | meaning              |
|-------|----------------------|
| `@`   | the NPC              |
| `A-Z` | other NPCs (name initial) |
| `~`   | water                |
| `.`   | passable terrain     |
| `T`   | tree                 |
| `s`   | stone                |
| `i`   | iron-ore             |
| `c`   | copper-ore           |
| `k`   | coal                 |
| `o`   | oil patch            |
| `#`   | player-built entity  |
| `*`   | enemy unit/nest      |
| `?`   | uncharted            |

**MCP side**:

```python
@mcp.tool()
def npc_text_map(npc_name, radius=24) -> dict
```

Returns:

```json
{"ok": true,
 "origin": {"x": 0, "y": 0}, "radius": 24, "scale_tiles_per_char": 1,
 "grid": [
   "?????????????????????????????????????????????????",
   "..........T..T.T....s.s.s..i.i.i.i................",
   "...........T..T.....s.s.s..i.i.i.i................",
   "............................@.....................",
   ...
 ]}
```

Each row is a single string, top of grid = north. Claude reads this
*much* faster than parsing 600 entity records, and it gets cluster
boundaries for free.

Cost: a 49×49 grid is 2500 chars per request — well under any token
limit and serialises in one RCON round-trip.

### Phase 3 — Smarter `observe` truncation (small change, prevents regressions)

Change `nearby_summary`'s group cap from "first 25 entries" to a
clustering strategy:

- For resource types: collapse to per-patch summaries instead of per-tile
  records. Each patch entry: `{name, center, tile_count, bounding_box}`.
- For trees: same — cluster by adjacency.
- For built entities: keep individual records (typically few).
- For enemies: keep all individual records (safety-critical).

This makes `npc_observe` self-sufficient for navigation without forcing
Claude to chain `npc_find` calls for context it already partially has.

### Phase 4 — Screenshot fallback via MCP image content (optional)

If we ever want images back in the loop, return them inline:

```python
from fastmcp.types import ImageContent

@mcp.tool()
def npc_screenshot(npc_name, ...) -> list:
    take_screenshot_via_rcon(...)
    png_bytes = read_local_file(path)
    return [ImageContent(data=base64.b64encode(png_bytes), mimeType="image/png")]
```

This bypasses the URL-fetch problem entirely — the image bytes are
delivered through MCP's content-block protocol. Claude Desktop renders
them directly.

But this is *backup*, not primary. Phases 1–3 should make screenshots
unnecessary for everything except "show the human a picture."

---

## Briefing changes

Once Phases 1–3 land, the briefing should be updated:

- **Add** to perception list:
  - `npc_find(npc_name, resource)` — fastest way to locate a patch.
  - `npc_text_map(npc_name, radius=24)` — ASCII overview of surroundings.
- **Remove or de-emphasise** the screenshot section. Add a note: "URL
  fetch is not available to the agent. Use `npc_text_map` for visual
  context."
- **Add** a worked example: "To gather 50 stone: `npc_find(npc_name,
  'stone')` → walk to `patches[0].nearest_tile` → `npc_mine_at` until
  inventory shows 50."

---

## Order of operations / acceptance test

When implementing, validate against this scenario (the one that just
failed):

1. Fresh world, Botty at (0, 0), inventory empty.
2. `npc_find(npc_name="Botty", resource="stone")` returns at least
   one patch with `tile_count >= 20` and `nearest_tile` within 60
   tiles.
3. `npc_walk_to` to `nearest_tile.x, nearest_tile.y` returns
   `arrived` (or `path_failed`, in which case `npc_walk_toward`
   reaches within `arrive_radius`).
4. `npc_mine_at` on the same tile yields stone in inventory within
   ~10 seconds.
5. `npc_text_map(radius=16)` shows `@` at the NPC and at least some
   `s` characters within the grid.

If those four pass, the hardship is solved.

---

## What we are NOT doing

- We are not changing the pathfinder. `walk_toward` is the fallback;
  the unreliable pathfinder is documented.
- We are not adding image generation, vision models, or external
  rendering. The whole point is to keep perception inside the MCP
  text channel.
- We are not making `npc_find` mutate state. It is read-only — the
  agent still decides where to walk.
- We are not auto-mining on behalf of the agent. The agent still
  proposes and the human still confirms.
