"""factorio_npc_mcp — MCP server exposing NPC-control tools to an LLM.

Multi-NPC edition: every tool takes `npc_name` as its first required
argument. Multiple Claude Desktop instances can each be told their own
NPC name and share one Factorio world.

Every tool boils down to a single `remote.call("npc", "<fn>", name, ...)`
shipped over RCON via the backend. Responses come back as JSON strings
printed with `rcon.print(...)` inside the Lua call, and are parsed before
returning to the LLM.

See mod/npc_mcp/control.lua for the in-game side.
"""

from __future__ import annotations

import json
import os
from io import BytesIO
from typing import Any

import httpx
from fastmcp import FastMCP
from fastmcp.utilities.types import Image
from PIL import Image as PILImage, ImageDraw, ImageFont

BACKEND_URL = os.environ.get("BACKEND_URL", "http://127.0.0.1:8000")


# Server-level instructions are sent in the MCP `initialize` response and
# Claude Desktop folds them into the system context automatically.
_BRIEFING = """\
# Factorio NPC operator briefing

Headless Factorio dedicated server. You drive ONE named character. Other
AI agents may share the world; each has its own NPC name.

## Your name
At session start, ask the human: "What is my NPC name?" Pass that string
as `npc_name` on EVERY tool call. No default. If `npc_status` returns
`exists=false`, call `npc_spawn` once.

## Coordinates & directions
+x = east, +y = south. Walk speed ~9 tiles/sec. Directions 0..15
(cardinals only matter): 0=N, 4=E, 8=S, 12=W.

## Core loop (per turn)
1. `npc_turn(npc_name, 16)` — ONE call returns observation + drained events
   + craft queue. Do NOT call observe/status/drain_events/craft_status
   separately; `npc_turn` already includes them.
2. Decide. **If you are about to place ≥2 entities, you MUST first emit
   a schema diagram in your reply text** (see "Mandatory schema-first
   planning" below). No exceptions — not even for "just two drills".
3. Execute. Bundle multiple world-mutating actions (place + fuel +
   rotate, several inserters, etc.) into a single `npc_batch` so they
   run in one Factorio tick and one LLM round-trip.
4. For long actions (walking, mining, crafting): estimate ETA, then
   `npc_turn` again when you expect it to be done. Do NOT poll faster
   than ~once per second of in-game time.
5. Stop only if you are blocked, a hard rule says stop, or you are about
   to do something destructive (`npc_despawn`, `npc_give`, attacking a
   non-enemy).

## Mandatory schema-first planning
This is the single most important rule in this briefing. Layout bugs
(drill on patch edge, drop tile off-by-one, belt-into-chest with no
inserter) come from skipping this step. Before EVERY `npc_batch` that
places 2 or more entities, your reply text MUST contain, in order:

1. **A tile grid diagram** in the notation from `docs/FACTORY_SCHEMA.md`
   (glyphs: `*c` coal, `*i` iron, `d1c` `d2c` `d1i`... drills with id
   and resource, `B>c` `B<c` `B^c` `Bvc` belts with flow+content, `ix`
   extractor inserter, `iL` loader inserter, `Ch` chest, `Fu` furnace,
   `..` empty ground). Use absolute tile coords on the rows/cols.
2. **Facing + drop-tile annotations** — one line per drill and inserter
   stating its `(x, y)` body center, facing letter, and computed drop
   tile (and pickup tile, for inserters). Cross-check each drop tile
   against the drill table below; cross-check each inserter pickup/
   drop against the inserter table.
3. **The 7-step validation checklist run line-by-line** ("1. footprints
   don't overlap: ✓ — d1 body {...}, d2 body {...}, ix at (3,0)…";
   "4. every belt→container junction has an inserter: ✓ — iL at
   (10,0) drops east into Ch at (11,0)").
4. Only THEN emit the `npc_batch` call.

If your reply omits the diagram, the facings, OR the validation
walkthrough, that's a self-violation — stop, redo the plan with the
diagram, then proceed. The human will reject builds that skip schema
planning.

## Tool-call budget
Claude Desktop caps tool calls per turn. To avoid stopping mid-build:
- Always use `npc_turn` — never call observe/status/drain_events/
  craft_status separately.
- Any sequence of 2+ world-mutating calls (place, fuel, rotate,
  set_recipe, insert_into, etc.) MUST go through a single `npc_batch`.
- Prefer `npc_belt` / `npc_inserter` over multiple raw `npc_place`
  calls — one helper call expands server-side into many ops.

## Perception fields to trust
- Inserters: `facing` = pickup side, `pickup`/`drop` = world coords.
  Rotate twice to swap pickup<->drop.
- Belts: `flow` = direction items move; `lanes` = per-lane contents.
- Underground belts: `ug_type`, `ug_pair`.
- Resources/trees are returned as AGGREGATED rows
  `{name, count, nearest:{x,y}, total_amount}` — feed `nearest` straight
  into `npc_walk_to`/`npc_mine_at`. Do NOT call `npc_look_at` with large
  radius to enumerate tiles; `look_at` is capped to radius 8 server-side.

## Picking targets to mine
Prefer `npc_find(resource)` — returns clustered patches with
`nearest_tile`. If using `npc_map_summary` samples, verify with
`npc_look_at(x,y, radius=2)` before mining.

## Burner fuel
Burner inserters/drills/furnaces need coal in their fuel slot. After
placing, call `npc_fuel(npc_name, x, y, "coal", 2)`.

## Placing things — use the smart helpers, not raw `npc_place`
- `npc_belt(from, to, item)` — straight axis-aligned belt run; direction is
  auto-derived. Use TWO calls for L-corners (first leg, then second leg).
- `npc_inserter(pickup, drop, variant)` — places one inserter with the
  correct facing. No need to compute `defines.direction` yourself.
- `npc_place(item, x, y, dir)` — single placement; **auto-walks** into
  reach if needed. Async response includes `{async:true, queued:1}` when
  walking; the real result arrives as `placed` or `place_failed` events
  in your next `npc_turn`.
- All placement errors are structured: check `error.code` for
  `missing_item`, `tile_blocked` (with `blockers` + `suggestion`),
  `not_placeable`, `engine_refused`, `walk_stuck`.

## Placing mining drills
A burner/electric drill has a 3x3 mining footprint. It will mine ANY
ore tile inside that footprint — including ore of a DIFFERENT type
than you intended. Placing a drill that straddles iron+copper or any
two ores produces a single mixed-ore output stream that jams furnaces
and assemblers.

**Rule A — same resource only:** before `npc_place(item="burner-mining-drill", x, y)`,
verify every ore tile within ±1 of `(x,y)` is the SAME resource:
1. `npc_look_at(x, y, radius=2)` and inspect the `resource` list.
2. If `name` is not uniform across the 3x3, MOVE the drill one tile
   away from the contamination and re-check.
3. Pillar-of-ore patches (e.g., iron-ore touching coal) need the drill
   recentered into pure iron tiles or you'll co-mine coal into your
   iron belt.

**Rule B — DENSE CENTER, not edge:** `npc_find(resource)` returns
`nearest_tile` which is the tile CLOSEST TO THE BOT, almost always on
the edge of the patch. Drills placed on the edge deplete in minutes
because half their footprint is empty ground. Before placing:
1. Use `npc_find` to get the patch.
2. Walk INTO the patch by several tiles toward the patch centroid
   (the patch dict carries `bbox` and `count`).
3. `npc_look_at(candidate_center, radius=2)` and confirm ALL FOUR tiles
   of the drill body sit on the target ore with high `amount` values.
4. If any of the four tiles are empty ground or another resource,
   shift one tile and re-check. Repeat until all four are pure.

**Rule C — drop tile MUST land on a real target:** after picking center
and facing, compute the drop tile from the table below. The drop tile
MUST be exactly one of: (a) a belt tile you are also placing, (b) the
body of a partner burner entity that accepts the mined item as fuel,
or (c) a chest you are also placing at that exact tile. "One tile
off" = items pile on the ground and the line stalls.

After placement, `npc_look_at` the drill and confirm `drop` (the
output tile) lands where your belt or chest sits.

## Layout schema (notation + verified primitives)
Use the tile-exact schema notation when planning multi-entity layouts.
Full reference: `docs/FACTORY_SCHEMA.md`. Critical rules in-line:

**Drill drop-tile table** (2×2 body, center = `(cx, cy)` snaps to integer):
- facing N (dir=0):  drop tile = `(cx-1, cy-2)`
- facing E (dir=4):  drop tile = `(cx+1, cy-1)`
- facing S (dir=8):  drop tile = `(cx,   cy+1)`
- facing W (dir=12): drop tile = `(cx-2, cy)`

**Inserter direction convention (READ CAREFULLY — the MCP convention is
INVERTED vs. Factorio's engine convention):**
- In this MCP, `direction` of an inserter = the side its **pickup tile**
  is on, NOT the side it drops to. (Factorio internally uses the
  opposite. Don't trust your prior Factorio knowledge here.)
- Always prefer `npc_inserter(pickup, drop)` over raw `npc_place` for
  inserters — it computes `direction` for you.

**Inserter pickup/drop** (range 1; offsets from inserter body tile;
+x = east, +y = south):

| direction | pickup offset (from body) | drop offset (from body) |
|---|---|---|
| 0  (pickup-from-NORTH) | `(0, -1)` | `(0, +1)` |
| 4  (pickup-from-EAST)  | `(+1, 0)` | `(-1, 0)` |
| 8  (pickup-from-SOUTH) | `(0, +1)` | `(0, -1)` |
| 12 (pickup-from-WEST)  | `(-1, 0)` | `(+1, 0)` |

Worked example: inserter body at `(x=-7.5, y=-70.5)` placed with
`direction=8`. By the table, pickup offset is `(0, +1)`, drop offset is
`(0, -1)`. Therefore pickup tile = `(-7.5, -69.5)`, drop tile =
`(-7.5, -71.5)`. The observation will confirm exactly those numbers.

**Self-feeding coal drill pair + extractor + belt + LOADER inserter +
chest** (verified working — the foundation of any burner-tier base):

```
  ..  *c  d1c d1c  ix→ B>c B>c ... B>c iL→ Ch
  ..  *c  d1c d1c  *c     d1 faces S, drop = (2,2) INSIDE d2 body → d2.fuel
  ..  *c  d2c d2c  *c     d2 faces N, drop = (1,1) INSIDE d1 body → d1.fuel
  ..  *c  d2c d2c  *c     ix faces E, picks coal from d1.fuel → belt
                          iL faces W, picks coal off last belt tile → Ch
```

**HARD RULE — belts do NOT pour into chests.** A belt tile next to a
chest does NOT deposit items into that chest. Items pile on the belt
end and back-pressure the whole line. You MUST place an inserter (`iL`
above) between the belt end and the chest:
- `iL` body sits at `(belt_end.x + 1, belt_end.y)` for an east-flowing belt.
- `iL` direction = W (12) so pickup tile = belt end, drop tile = chest body.
- Same applies to belt → furnace, belt → assembler: ALWAYS an inserter.

Mechanic: a burner drill's `drop_position` lands **inside** the partner
drill's 2×2 body. The game inserts the mined item directly into the
partner's fuel inventory because coal is valid fuel for that entity.
An inserter whose pickup tile sits on a burner-drill body reads from
that drill's fuel slot — so `ix` continuously drains d1's stockpile
onto a belt while d2's drops keep refilling d1.

**Build sequence** (one `npc_batch`, then wait one `npc_turn`):
```
npc_batch(ops=[
  {"fn":"place",   "kwargs":{"item":"burner-mining-drill","x":cx,    "y":cy,    "direction":8}},
  {"fn":"place",   "kwargs":{"item":"burner-mining-drill","x":cx,    "y":cy+2,  "direction":0}},
  {"fn":"place",   "kwargs":{"item":"burner-inserter",    "x":cx+1,  "y":cy-1,  "direction":4}},
  {"fn":"belt",    "kwargs":{"from":[cx+2, cy-1],"to":[cx+7, cy-1],"item":"transport-belt"}},
  {"fn":"place",   "kwargs":{"item":"burner-inserter",    "x":cx+8,  "y":cy-1,  "direction":12}},
  {"fn":"place",   "kwargs":{"item":"wooden-chest",       "x":cx+9,  "y":cy-1}},
  {"fn":"fuel",    "kwargs":{"x":cx,   "y":cy,   "item":"coal","count":2}},
  {"fn":"fuel",    "kwargs":{"x":cx+1, "y":cy-1, "item":"coal","count":2}},
  {"fn":"fuel",    "kwargs":{"x":cx+8, "y":cy-1, "item":"coal","count":2}},
])
```

The iron-drill pair works the same way structurally; iron drills do
NOT burn iron, so the partner's body fills with iron ore and stalls
within seconds unless an extractor inserter is pulling the iron out.
Use the SAME `ix` extractor on the iron pair, dropping onto an iron
belt that feeds furnace iron inputs.

**Validation checklist before emitting a build batch:**
1. Footprints don't overlap.
2. Drill body covers only ONE resource type AND all 4 (burner) / 9
   (electric) tiles have a high resource `amount` — i.e. the drill is
   in the dense interior, not on the patch edge.
3. Every drill drop tile lands on either: a partner drill body, a belt
   tile you placed, or a chest you placed at exactly that tile.
4. Every belt → chest / belt → furnace / belt → assembler junction has
   an inserter between them. Belts NEVER deposit directly into anything
   except another belt or an underground belt.
5. Every inserter pickup tile is a real coal/item source (belt-end,
   chest, or burner body).
6. Inventory has enough items for every `+` entry.
7. Every isolated burner subgraph has one `fuel` kick-start op per
   burner entity (every burner-inserter and burner-drill needs ≥1 coal).

## Output format
> **[Name]** Status: pos, HP, inventory highlights.
> Scene: what's nearby, ETA notes.
> Proposal: ordered tool calls.

## Hard rules
- You are a PLAYER, not a developer. No file edits, no shell commands,
  no git, no log reading. Only the `npc_*` tools.
- **NEVER CHEAT.** No `/sc`, `/c`, `/command`, `/editor`, or any console
  command. No spawning items, no teleporting, no inventory injection,
  no map-revealing scripts, no toggling god mode, no editing
  `game.*` state. Every item must be mined, crafted, or handed to you
  via `npc_give` by an admin human. If you find yourself reaching for a
  cheat to "save time" or unblock progress, STOP and ask the human.
  `npc_give` is the ONLY sanctioned bypass and it requires explicit
  human approval each time.
- If something is broken, report verbatim error + arguments and stop.
- If RCON drops or tick rewinds, STOP and tell the human.
- Pass `npc_name` on every call.
- Never `npc_despawn` or `npc_give` without explicit human approval.
- If `enemy_count > 0` within ~15 tiles, STOP and ask.
- `npc_screenshot` is disabled. Use `npc_text_map` for spatial awareness.

## First-session checklist
1. Ask name. 2. `npc_status`. 3. `npc_spawn` if missing.
4. `npc_turn` (covers events + observation + craft). 5. Plan and act.
"""

# Single source of truth: prefer the workspace SKILL.md so edits there
# flow straight into the MCP `instructions` field (delivered to the agent
# on `initialize`, regardless of any skill-loader / sandbox). Falls back
# to the embedded copy above if the file isn't present.
def _load_skill_briefing() -> str:
    here = os.path.dirname(os.path.abspath(__file__))
    candidates = [
        os.path.join(here, "..", ".claude-plugin", "plugins", "factorio-npc",
                     "skills", "factorio-npc", "SKILL.md"),
        os.path.join(here, "..", ".claude", "skills", "factorio-npc", "SKILL.md"),
        os.path.join(here, "..", "CLAUDE.md"),
    ]
    for path in candidates:
        try:
            with open(path, "r", encoding="utf-8") as fh:
                text = fh.read()
            if len(text) > 500:
                return text
        except OSError:
            continue
    return _BRIEFING


_BRIEFING = _load_skill_briefing()

mcp = FastMCP("Factorio NPC", dependencies=["httpx"], instructions=_BRIEFING)


# ---------- low-level transport -----------------------------------------------

def _rcon(command: str) -> str:
    api_key = os.environ.get("API_KEY")
    if not api_key:
        return json.dumps({"ok": False, "error": "API_KEY not set in MCP env"})
    r = httpx.post(
        f"{BACKEND_URL}/execute_command",
        headers={"X-API-Key": api_key},
        json={"command": command},
        timeout=15.0,
    )
    if r.status_code != 200:
        return json.dumps({"ok": False, "error": f"backend {r.status_code}: {r.text}"})
    return r.json().get("result", "")


def _call(fn: str, *args: Any) -> dict:
    """Invoke remote.call("npc", fn, ...) and parse the JSON response."""
    lua_args = ", ".join(_lua_repr(a) for a in args)
    cmd = f'/sc rcon.print(remote.call("npc", "{fn}"{", " + lua_args if lua_args else ""}))'
    raw = _rcon(cmd)
    if not raw:
        return {"ok": False, "error": "empty response (is the npc_mcp mod loaded?)"}
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return {"ok": False, "error": "non-json response", "raw": raw}


def _lua_repr(v: Any) -> str:
    if v is None:
        return "nil"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, str):
        return '"' + v.replace("\\", "\\\\").replace('"', '\\"') + '"'
    if isinstance(v, dict):
        parts = [f"{_lua_key(k)}={_lua_repr(val)}" for k, val in v.items()]
        return "{" + ", ".join(parts) + "}"
    if isinstance(v, (list, tuple)):
        return "{" + ", ".join(_lua_repr(x) for x in v) + "}"
    raise TypeError(f"cannot serialise {type(v).__name__} to Lua")


def _lua_key(k: Any) -> str:
    if isinstance(k, str) and k.replace("_", "a").isalnum() and not k[:1].isdigit():
        return k
    return "[" + _lua_repr(k) + "]"


_DIRECTIONS = {
    # Factorio 2.0 uses 16-way directions; cardinals are 0/4/8/12.
    "north": 0, "east": 4, "south": 8, "west": 12,
}


# ---------- Pillow rasterizer (synthetic screenshot) --------------------------

# Tile glyph -> RGB. See fn_render in control.lua for the source mapping.
_TILE_COLORS: dict[str, tuple[int, int, int]] = {
    "W": (24, 60, 110),    # deepwater
    "w": (60, 120, 180),   # water
    "g": (90, 140, 70),    # grass
    "d": (130, 100, 70),   # dirt
    "s": (200, 180, 120),  # sand
    "r": (180, 110, 80),   # red-desert
    "p": (150, 150, 150),  # built path (concrete/stone-path)
    "n": (160, 180, 80),   # nuclear ground
    "?": (20, 20, 20),     # uncharted / off-map
}

# Entity kind -> RGB. Order matters only for the legend; rendering looks up
# the exact key first, then a prefix fallback ("ore:" / "built:").
_ENTITY_COLORS: dict[str, tuple[int, int, int]] = {
    "self":            (255, 230, 30),
    "npc":             (255, 140, 40),
    "enemy":           (220, 40, 40),
    "tree":            (40, 80, 30),
    "rock":            (110, 110, 110),
    "other":           (160, 160, 160),
    "ore:stone":       (210, 210, 210),
    "ore:iron-ore":    (100, 150, 255),
    "ore:copper-ore":  (220, 120, 40),
    "ore:coal":        (20, 20, 20),
    "ore:uranium-ore": (60, 220, 90),
    "ore:crude-oil":   (160, 60, 200),
}
_ENTITY_PREFIX_COLORS: dict[str, tuple[int, int, int]] = {
    "ore:":   (180, 140, 200),  # unknown ore fallback
    "built:": (200, 200, 230),  # built structure fallback
}


def _color_for_entity(kind: str) -> tuple[int, int, int]:
    if kind in _ENTITY_COLORS:
        return _ENTITY_COLORS[kind]
    for prefix, color in _ENTITY_PREFIX_COLORS.items():
        if kind.startswith(prefix):
            return color
    return (200, 200, 200)


def _rasterize(payload: dict, tile_px: int) -> bytes:
    """Turn a fn_render response into a PNG byte string."""
    sz: int = payload["size"]
    radius: int = payload["radius"]
    cx, cy = payload["center"]["x"], payload["center"]["y"]
    tiles: str = payload["tiles"]
    entities: list[dict] = payload.get("entities", [])

    img_w = sz * tile_px
    img_h = sz * tile_px
    pixels: list[tuple[int, int, int]] = [(0, 0, 0)] * (img_w * img_h)
    for ty in range(sz):
        for tx in range(sz):
            idx = ty * sz + tx
            ch = tiles[idx] if idx < len(tiles) else "?"
            color = _TILE_COLORS.get(ch, _TILE_COLORS["g"])
            x0, y0 = tx * tile_px, ty * tile_px
            for py in range(y0, y0 + tile_px):
                base = py * img_w + x0
                for px in range(tile_px):
                    pixels[base + px] = color
    img = PILImage.new("RGB", (img_w, img_h))
    img.putdata(pixels)
    draw = ImageDraw.Draw(img)

    # Faint grid every 8 tiles for distance reading
    grid_step = 8 * tile_px
    for gx in range(0, img_w, grid_step):
        draw.line([(gx, 0), (gx, img_h - 1)], fill=(255, 255, 255), width=1)
    for gy in range(0, img_h, grid_step):
        draw.line([(0, gy), (img_w - 1, gy)], fill=(255, 255, 255), width=1)

    # Entities: small filled squares centered at tile midpoints
    dot = max(2, tile_px - 2)
    half = dot // 2
    for ent in entities:
        ex = (ent["x"] - cx + radius) * tile_px + tile_px / 2
        ey = (ent["y"] - cy + radius) * tile_px + tile_px / 2
        if ex < 0 or ey < 0 or ex >= img_w or ey >= img_h:
            continue
        color = _color_for_entity(ent.get("k", "other"))
        draw.rectangle((ex - half, ey - half, ex + half, ey + half), fill=color)

    # Character marker: yellow ring + crosshair at exact center
    cx_px = sz * tile_px // 2
    cy_px = sz * tile_px // 2
    ring = max(6, tile_px + 2)
    draw.ellipse(
        (cx_px - ring, cy_px - ring, cx_px + ring, cy_px + ring),
        outline=(255, 230, 30), width=2,
    )
    draw.line((cx_px - ring, cy_px, cx_px + ring, cy_px), fill=(255, 230, 30), width=1)
    draw.line((cx_px, cy_px - ring, cx_px, cy_px + ring), fill=(255, 230, 30), width=1)

    # Legend strip along the bottom
    legend_h = 14
    legend = PILImage.new("RGB", (img_w, legend_h), (0, 0, 0))
    ld = ImageDraw.Draw(legend)
    ld.text(
        (4, 1),
        f"center=({cx},{cy})  r={radius}  ents={len(entities)}  daytime={payload.get('daytime', 0):.2f}",
        fill=(220, 220, 220),
    )
    out = PILImage.new("RGB", (img_w, img_h + legend_h), (0, 0, 0))
    out.paste(img, (0, 0))
    out.paste(legend, (0, img_h))

    buf = BytesIO()
    out.save(buf, format="PNG", optimize=True)
    return buf.getvalue()


def _error_image(message: str) -> Image:
    """Tiny PNG carrying an error message so MCP callers always get an image
    (the tool signature returns Image, not a dict)."""
    img = PILImage.new("RGB", (480, 80), (40, 0, 0))
    draw = ImageDraw.Draw(img)
    draw.text((6, 6), "npc_screenshot error:", fill=(255, 180, 180))
    text = message if len(message) <= 240 else message[:240] + "..."
    for i, line in enumerate([text[j : j + 60] for j in range(0, len(text), 60)][:4]):
        draw.text((6, 24 + i * 14), line, fill=(255, 220, 220))
    buf = BytesIO()
    img.save(buf, format="PNG", optimize=True)
    return Image(data=buf.getvalue(), format="png")


def _require_name(npc_name: str) -> dict | None:
    """Return an error dict if npc_name is missing/blank, else None."""
    if not npc_name or not isinstance(npc_name, str):
        return {
            "ok": False,
            "error": "npc_name is required — ask the human for your assigned NPC name "
                     "and pass it on every tool call.",
        }
    return None


# ============================================================================
# Lifecycle
# ============================================================================

@mcp.tool()
def npc_spawn(
    npc_name: str,
    x: float | None = None,
    y: float | None = None,
    dx: float = 0.0,
    dy: float = 0.0,
) -> dict:
    """Spawn the character `npc_name` (idempotent)."""
    err = _require_name(npc_name)
    if err:
        return err
    opts: dict[str, Any] = {"dx": dx, "dy": dy}
    if x is not None and y is not None:
        opts["x"] = x
        opts["y"] = y
    return _call("spawn", npc_name, opts)


@mcp.tool()
def npc_despawn(npc_name: str) -> dict:
    """Remove your character. Requires explicit human approval."""
    if err := _require_name(npc_name):
        return err
    return _call("despawn", npc_name)


@mcp.tool()
def npc_list() -> dict:
    """List every spawned NPC (no `npc_name` arg)."""
    return _call("list")


@mcp.tool()
def npc_rename(npc_name: str, new_name: str) -> dict:
    """Rename your character (human approval)."""
    if err := _require_name(npc_name):
        return err
    return _call("rename", npc_name, new_name)


@mcp.tool()
def npc_save(name: str | None = None) -> dict:
    """Snapshot the world. Auto-saves run every 10 min; only call for named checkpoints."""
    return _call("save", "_", name) if name else _call("save", "_")


# ============================================================================
# Perception
# ============================================================================

@mcp.tool()
def npc_status(npc_name: str) -> dict:
    """Existence/position/intent. Prefer `npc_observe`."""
    if err := _require_name(npc_name):
        return err
    return _call("status", npc_name)


@mcp.tool()
def npc_observe(npc_name: str, radius: int = 16) -> dict:
    """Default perception: position + inventory + nearby + enemy_count. radius<=24."""
    if err := _require_name(npc_name):
        return err
    return _call("observe", npc_name, radius)


@mcp.tool()
def npc_look(npc_name: str, radius: int = 16) -> dict:
    """Nearby entities only (no inventory). radius<=24."""
    if err := _require_name(npc_name):
        return err
    return _call("look", npc_name, radius)


@mcp.tool()
def npc_look_at(npc_name: str, x: float, y: float, radius: int = 4) -> dict:
    """Inspect tile (x,y). radius capped to 8 server-side; keep small."""
    if err := _require_name(npc_name):
        return err
    return _call("look_at", npc_name, x, y, radius)


@mcp.tool()
def npc_inventory(npc_name: str) -> dict:
    """Main inventory + armor/guns/ammo/trash."""
    if err := _require_name(npc_name):
        return err
    return _call("inventory", npc_name)


@mcp.tool()
def npc_drain_events(npc_name: str) -> dict:
    """Consume your event queue. Call at start of each turn."""
    if err := _require_name(npc_name):
        return err
    return _call("drain_events", npc_name)


@mcp.tool()
def npc_turn(npc_name: str, radius: int = 16) -> dict:
    """Compound per-turn perception in ONE call. Returns {observation, events, craft}
    where observation has the same shape as npc_observe (position, inventory,
    equipment, nearby, enemy_count, daytime, tick). Prefer this over calling
    npc_drain_events + npc_observe + npc_craft_status separately. radius<=24."""
    if err := _require_name(npc_name):
        return err
    return _call("turn", npc_name, radius)


@mcp.tool()
def npc_batch(npc_name: str, ops: list[dict]) -> dict:
    """Execute several actions in ONE Factorio tick (one RCON round-trip).

    BEFORE FIRST USE: call `npc_help` to load the schema-first planning
    rules. Replies that place 2+ entities without a tile-grid diagram and
    a validation walkthrough will be rejected per the skill briefing.

    Each op is `{"fn": "<action>", ...}` where `<action>` is the bare action
    name (no `npc_` prefix), e.g. "place", "fuel", "insert_into", "walk_to".
    The npc_name applies to every op. Returns
    {count, results: [<per-op response>, ...]} in order.

    Two ways to pass parameters per op:
    - **kwargs** (recommended, unambiguous):
      {"fn":"insert_into", "kwargs":{"x":-5,"y":-67,"item":"iron-ore","count":30}}
    - **args** (positional, must match the matching `npc_<fn>` signature
      AFTER npc_name; e.g. npc_insert_into(npc_name, x, y, item, count)
      becomes args=[x, y, item, count]):
      {"fn":"insert_into", "args":[-5, -67, "iron-ore", 30]}

    Example: place a drill, fuel it, place a chest, then load iron into a
    furnace — all in one tick:
    ops=[
      {"fn":"place",       "kwargs":{"item":"burner-mining-drill","x":12,"y":-4,"direction":0}},
      {"fn":"fuel",        "kwargs":{"x":12,"y":-4,"item":"coal","count":2}},
      {"fn":"place",       "kwargs":{"item":"wooden-chest","x":12,"y":-2}},
      {"fn":"insert_into", "kwargs":{"x":-5,"y":-67,"item":"iron-ore","count":30}},
    ]

    Cannot nest `batch` or `turn` inside ops."""
    if err := _require_name(npc_name):
        return err
    return _call("batch", npc_name, ops)


@mcp.tool()
def npc_screenshot(
    npc_name: str,
    radius: int = 32,
    tile_px: int = 8,
    x: float | None = None,
    y: float | None = None,
) -> Image:
    """DISABLED. Use npc_text_map / npc_look instead."""
    if err := _require_name(npc_name):
        return _error_image(err["error"])
    opts: dict[str, Any] = {"radius": radius}
    if x is not None and y is not None:
        opts["x"] = x
        opts["y"] = y
    result = _call("render", npc_name, opts)
    if not result.get("ok"):
        return _error_image(str(result.get("error", "render failed")))
    png_bytes = _rasterize(result, max(4, min(int(tile_px), 16)))
    return Image(data=png_bytes, format="png")


@mcp.tool()
def npc_chart(npc_name: str, x: float, y: float, radius: int = 64) -> dict:
    """Reveal an area on the map without moving."""
    if err := _require_name(npc_name):
        return err
    return _call("chart", npc_name, x, y, radius)


@mcp.tool()
def npc_map_summary(npc_name: str) -> dict:
    """Coarse patch counts. Prefer `npc_find` for actionable coords."""
    if err := _require_name(npc_name):
        return err
    return _call("map_summary", npc_name)


@mcp.tool()
def npc_find(
    npc_name: str,
    resource: str,
    radius: int = 128,
    max_gap: int = 2,
) -> dict:
    """Find clustered patches; each carries `nearest_tile` for walk_to/mine_at. resource: 'stone'|'iron-ore'|'copper-ore'|'coal'|'uranium-ore'|'crude-oil'|'tree'."""
    if err := _require_name(npc_name):
        return err
    return _call("find", npc_name, resource, radius, max_gap)


@mcp.tool()
def npc_text_map(npc_name: str, radius: int = 24) -> dict:
    """ASCII grid around character. Legend: @self ~water .passable T tree R rock C cliff s stone i iron c copper k coal u uranium o oil ^v<>belts(walkable) =pipe(walkable) +pole/rail(walkable) I inserter S splitter W wall M drill A assembler F furnace L lab B chest G power-gen V vehicle # other-built * enemy P npc ? uncharted. radius in [4,40]."""
    if err := _require_name(npc_name):
        return err
    return _call("text_map", npc_name, radius)


@mcp.tool()
def npc_research_status(npc_name: str) -> dict:
    """Current research + progress + queue (force-wide)."""
    if err := _require_name(npc_name):
        return err
    return _call("research_status", npc_name)


@mcp.tool()
def npc_tech_tree(npc_name: str, only_available: bool = True) -> dict:
    """List unresearched techs; only_available => prereqs met."""
    if err := _require_name(npc_name):
        return err
    return _call("tech_tree", npc_name, only_available)


# ============================================================================
# Movement
# ============================================================================

@mcp.tool()
def npc_walk(npc_name: str, direction: str) -> dict:
    """Walk continuously: direction = north|east|south|west."""
    if err := _require_name(npc_name):
        return err
    if direction not in _DIRECTIONS:
        return {"ok": False, "error": f"direction must be one of {list(_DIRECTIONS)}"}
    return _call("walk", npc_name, _DIRECTIONS[direction])


@mcp.tool()
def npc_walk_to(npc_name: str, x: float, y: float) -> dict:
    """Async pathfind to (x,y). Emits arrived. On path_failed/path_busy fall back to walk_toward."""
    if err := _require_name(npc_name):
        return err
    return _call("walk_to", npc_name, x, y)


@mcp.tool()
def npc_walk_toward(
    npc_name: str,
    x: float,
    y: float,
    arrive_radius: float = 1.5,
    stall_limit: int = 60,
) -> dict:
    """Greedy steer (no pathfinder). Emits walk_stuck after stall_limit ticks stuck."""
    if err := _require_name(npc_name):
        return err
    return _call("walk_toward", npc_name, x, y, arrive_radius, stall_limit)


@mcp.tool()
def npc_stop(npc_name: str) -> dict:
    """Cancel current intent."""
    if err := _require_name(npc_name):
        return err
    return _call("stop", npc_name)


# ============================================================================
# Gathering
# ============================================================================

@mcp.tool()
def npc_mine_at(npc_name: str, x: float, y: float) -> dict:
    """Approach into reach then mine entity at (x,y) until gone."""
    if err := _require_name(npc_name):
        return err
    return _call("mine_at", npc_name, x, y)


# ============================================================================
# Crafting
# ============================================================================

@mcp.tool()
def npc_craft(npc_name: str, recipe: str, count: int = 1) -> dict:
    """Queue a hand-craft. Emits craft_done per unit."""
    if err := _require_name(npc_name):
        return err
    return _call("craft", npc_name, recipe, count)


@mcp.tool()
def npc_craft_status(npc_name: str) -> dict:
    """Inspect hand-craft queue."""
    if err := _require_name(npc_name):
        return err
    return _call("craft_status", npc_name)


@mcp.tool()
def npc_cancel_craft(npc_name: str, index: int = 1) -> dict:
    """Drop craft queue entry (1=head). No refund."""
    if err := _require_name(npc_name):
        return err
    return _call("cancel_craft", npc_name, index)


# ============================================================================
# Building
# ============================================================================

@mcp.tool()
def npc_place(npc_name: str, item: str, x: float, y: float, direction: int = 0) -> dict:
    """Place item at (x,y). dir 0..15 (cardinals: 0=N 4=E 8=S 12=W).

    For multi-entity builds, call `npc_help` first and use `npc_batch`.

    If the target is within build reach (~10 tiles), the placement is
    synchronous and the response includes `placed`/`position`.

    If out of reach, the call returns `{async:true, queued:1, distance, reach}`
    and the NPC auto-walks into reach then places. Pull `npc_turn` to see
    `placed` / `place_failed` / `place_seq_done` events.

    On failure the response includes a structured `error` plus a `code`:
      - `missing_item`     — inventory lacks the item; craft or take_from.
      - `tile_blocked`     — `blockers` array + `suggestion`; e.g. mine the rock.
      - `not_placeable`    — item has no place_result.
      - `engine_refused`   — Factorio refused (rare; usually force/collision).
    """
    if err := _require_name(npc_name):
        return err
    return _call("place", npc_name, item, x, y, direction)


@mcp.tool()
def npc_belt(
    npc_name: str,
    from_: dict,
    to: dict,
    item: str = "transport-belt",
) -> dict:
    """Place a straight axis-aligned line of belts from `from_` to `to` inclusive.

    REMEMBER: belts do NOT deposit into chests/furnaces/assemblers; you
    MUST put an inserter at every belt->container junction. See `npc_help`.

    `from_` and `to` are {"x":..,"y":..}. The segment must be axis-aligned
    (dx=0 or dy=0). Direction is derived automatically so items flow from
    `from_` toward `to`. For an L-corner call npc_belt twice (first leg,
    then second leg). Works for any 1x1 directional belt-like item:
    `transport-belt`, `fast-transport-belt`, `express-transport-belt`.

    Returns `{async:true, queued:N, direction, from, to}`. Watch events
    via `npc_turn` for per-tile `placed` and final `place_seq_done`.

    Pre-validates that the inventory has at least N belt items.
    """
    if err := _require_name(npc_name):
        return err
    return _call("belt", npc_name, from_, to, item)


@mcp.tool()
def npc_inserter(
    npc_name: str,
    pickup: dict,
    drop: dict,
    variant: str = "inserter",
) -> dict:
    """Place ONE inserter so it picks from `pickup` and drops on `drop`.

    Direction is derived from pickup/drop, so you do NOT compute it. See
    `npc_help` for the (inverted-from-engine) direction convention.

    No need to compute direction; the server derives it from the pickup/drop
    tiles. The inserter base ends up at the midpoint. Works for `inserter`,
    `burner-inserter`, `fast-inserter`, `long-handed-inserter` (long handed
    expects pickup/drop 4 tiles apart on the same axis).

    Both `pickup` and `drop` are {"x":..,"y":..} world coordinates.

    Returns `{async:true, base, direction, pickup, drop}`. After the `placed`
    event arrives, you may need to `npc_fuel(..., "coal", 1)` for burner
    inserters.
    """
    if err := _require_name(npc_name):
        return err
    return _call("inserter", npc_name, pickup, drop, variant)


@mcp.tool()
def npc_pickup(npc_name: str, x: float, y: float) -> dict:
    """Mine friendly entity at (x,y) back into inventory."""
    if err := _require_name(npc_name):
        return err
    return _call("pickup", npc_name, x, y)


@mcp.tool()
def npc_rotate(npc_name: str, x: float, y: float, direction: int) -> dict:
    """Rotate entity at (x,y) to dir 0..15."""
    if err := _require_name(npc_name):
        return err
    return _call("rotate", npc_name, x, y, direction)


@mcp.tool()
def npc_set_recipe(npc_name: str, x: float, y: float, recipe: str) -> dict:
    """Set recipe of assembler at (x,y)."""
    if err := _require_name(npc_name):
        return err
    return _call("set_recipe", npc_name, x, y, recipe)


# ============================================================================
# Logistics
# ============================================================================

@mcp.tool()
def npc_insert_into(npc_name: str, x: float, y: float, item: str, count: int = 1) -> dict:
    """Insert items into container/machine at (x,y)."""
    if err := _require_name(npc_name):
        return err
    return _call("insert_into", npc_name, x, y, item, count)


@mcp.tool()
def npc_take_from(npc_name: str, x: float, y: float, item: str, count: int = 1) -> dict:
    """Take items from container/machine at (x,y)."""
    if err := _require_name(npc_name):
        return err
    return _call("take_from", npc_name, x, y, item, count)


@mcp.tool()
def npc_fuel(npc_name: str, x: float, y: float, fuel: str = "coal", count: int = 5) -> dict:
    """Fuel the burner at (x,y) with `fuel` x `count`."""
    if err := _require_name(npc_name):
        return err
    return _call("fuel", npc_name, x, y, fuel, count)


# ============================================================================
# Research
# ============================================================================

@mcp.tool()
def npc_research(npc_name: str, tech: str) -> dict:
    """Queue tech for research (force-wide)."""
    if err := _require_name(npc_name):
        return err
    return _call("research", npc_name, tech)


# ============================================================================
# Combat
# ============================================================================

@mcp.tool()
def npc_equip(
    npc_name: str,
    armor: str | None = None,
    gun: str | None = None,
    ammo: str | None = None,
    ammo_count: int = 10,
) -> dict:
    """Set armor/gun/ammo. Pass "" to clear a slot."""
    if err := _require_name(npc_name):
        return err
    opts: dict[str, Any] = {}
    if armor is not None:
        opts["armor"] = armor or None
    if gun is not None:
        opts["gun"] = gun or None
    if ammo:
        opts["ammo"] = ammo
        opts["ammo_count"] = ammo_count
    return _call("equip", npc_name, opts)


@mcp.tool()
def npc_shoot_at(npc_name: str, x: float, y: float) -> dict:
    """Shoot toward (x,y) continuously until npc_stop."""
    if err := _require_name(npc_name):
        return err
    return _call("shoot_at", npc_name, x, y)


@mcp.tool()
def npc_combat_mode(
    npc_name: str,
    enabled: bool = True,
    range: int = 20,
    retreat_hp_pct: int = 30,
) -> dict:
    """Toggle per-tick auto-engage. Range 2..60; emits combat_retreat below retreat_hp_pct."""
    if err := _require_name(npc_name):
        return err
    return _call("combat_mode", npc_name, {
        "enabled": enabled, "range": range, "retreat_hp_pct": retreat_hp_pct,
    })


@mcp.tool()
def npc_attack_target(
    npc_name: str,
    unit_number: int | None = None,
    x: float | None = None,
    y: float | None = None,
) -> dict:
    """Focus fire one target by unit_number or (x,y). Overridden by combat_mode if on."""
    if err := _require_name(npc_name):
        return err
    opts: dict[str, Any] = {}
    if unit_number is not None:
        opts["unit_number"] = unit_number
    if x is not None and y is not None:
        opts["x"] = x
        opts["y"] = y
    return _call("attack_target", npc_name, opts)


# ============================================================================
# Vehicles
# ============================================================================

@mcp.tool()
def npc_drive(
    npc_name: str,
    unit_number: int | None = None,
    x: float | None = None,
    y: float | None = None,
    radius: float = 3.0,
) -> dict:
    """Mount a vehicle. Pass unit_number, or (x,y) for nearest within radius."""
    if err := _require_name(npc_name):
        return err
    opts: dict[str, Any] = {"radius": radius}
    if unit_number is not None:
        opts["unit_number"] = unit_number
    if x is not None:
        opts["x"] = x
    if y is not None:
        opts["y"] = y
    return _call("drive", npc_name, opts)


@mcp.tool()
def npc_dismount(npc_name: str) -> dict:
    """Exit current vehicle."""
    if err := _require_name(npc_name):
        return err
    return _call("dismount", npc_name)


@mcp.tool()
def npc_drive_to(
    npc_name: str,
    x: float,
    y: float,
    arrive_radius: float = 4.0,
) -> dict:
    """Drive vehicle to (x,y). Spidertron uses autopilot; car/tank may emit drive_stuck."""
    if err := _require_name(npc_name):
        return err
    return _call("drive_to", npc_name, x, y, {"arrive_radius": arrive_radius})


# ============================================================================
# Chat / cheats
# ============================================================================

@mcp.tool()
def npc_say(npc_name: str, text: str) -> dict:
    """Chat line tagged with your NPC name."""
    if err := _require_name(npc_name):
        return err
    return _call("say", npc_name, text)


@mcp.tool()
def npc_give(npc_name: str, item: str, count: int = 1, quality: str | None = None) -> dict:
    """Cheat: insert items into inventory. Requires human approval."""
    if err := _require_name(npc_name):
        return err
    if quality:
        return _call("give", npc_name, item, count, quality)
    return _call("give", npc_name, item, count)


# ============================================================================
# Briefing exposed as both a tool AND a prompt. Tools are surfaced by
# every MCP client; prompts are not. CALL `npc_help` ONCE PER SESSION
# BEFORE BUILDING.
# ============================================================================

@mcp.tool()
def npc_help() -> str:
    """REQUIRED READING before any build. Returns the full Factorio NPC operator
    skill: schema notation, drill rules A/B/C, inserter direction convention,
    verified primitives, validation checklist. Call this ONCE per session
    before using `npc_place`, `npc_batch`, `npc_belt`, or `npc_inserter`."""
    return _BRIEFING


@mcp.prompt()
def factorio_briefing() -> str:
    """Full operator briefing (same content as the `npc_help` tool)."""
    return _BRIEFING


@mcp.prompt()
def help_prompt() -> str:
    """Quick reference."""
    return (
        "You drive ONE named character on a headless Factorio server. "
        "Ask the human for your NPC name at session start and pass it as "
        "`npc_name=` on every tool call. Default loop: drain_events -> "
        "observe -> propose -> confirm -> act -> wait -> report. "
        "Run `factorio_briefing` for the full playbook."
    )


if __name__ == "__main__":
    mcp.run()
