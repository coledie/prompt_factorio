---
name: factorio-npc
description: Operator playbook for driving an NPC character on the headless Factorio dedicated server via the `factorio-npc` MCP. USE WHEN the user asks you to play Factorio, run a Botty/NPC turn, build a factory, mine ore, place drills/belts/inserters, or call any `npc_*` tool. Covers the per-turn loop, smart placement helpers, the tile-exact layout schema notation, verified burner-tier primitives, and the three most common LLM planning bugs (drill on patch edge, drill drop tile not on belt, belt feeding chest with no inserter).
---

# Factorio NPC operator skill

You drive ONE named character on a headless Factorio 2.0.76 Space Age
dedicated server through the `factorio-npc` MCP server. Multiple AI
agents may share the same world — always pass `npc_name` on every call.

## When this skill applies
- Any `npc_*` tool is about to be called.
- The user asks you to play Factorio, build something, mine, or run a turn.
- You need to plan a multi-entity layout (drills, belts, inserters, chests).

## First-session checklist
1. Ask the human: **"What is my NPC name?"** No default. Pass it as
   `npc_name=` on EVERY tool call.
2. Call `npc_status(npc_name)`. If `exists=false`, call `npc_spawn` once.
3. Call `npc_turn(npc_name, 16)` to get current observation + drained
   events + craft queue in a single round-trip.

## The core loop (per turn)
1. **One** `npc_turn(npc_name, 16)` call — never call observe/status/
   drain_events/craft_status separately; `npc_turn` already includes them.
2. Decide. **If you are about to place ≥2 entities, you MUST emit a
   schema diagram first** (see "Mandatory schema-first planning" below).
3. Execute. Bundle 2+ world-mutating ops into one `npc_batch` so they
   run in a single Factorio tick and a single LLM round-trip.
4. For long actions (walking, mining, crafting), estimate ETA then call
   `npc_turn` when you expect it to be done. Don't poll faster than
   ~1×/sec of in-game time.
5. Stop only if: blocked, a hard rule says so, or you're about to do
   something destructive (`npc_despawn`, `npc_give`, attacking a non-enemy).

## Mandatory schema-first planning (READ THIS BEFORE EVERY BUILD)
The three most common LLM bugs in this domain — drill on patch edge,
drop tile off by one, belt feeding chest with no inserter — all come
from skipping the schema step. Before EVERY `npc_batch` that places 2+
entities, your reply MUST contain, IN THIS ORDER:

1. **A tile-coord grid diagram** using the glyph set:
   - `*c` coal, `*i` iron, `*u` copper, `*s` stone
   - `d1c`, `d2c`, `d1i`… drills (id + resource); fills 2×2 body
   - `B>c`, `B<c`, `B^c`, `Bvc` belts (arrow = flow, suffix = content)
   - `ix` extractor inserter (pulls off entity body)
   - `iL` loader inserter (drops onto chest/furnace/assembler)
   - `Ch` chest, `Fu` furnace, `As` assembler, `..` empty ground
   Label rows/cols with absolute tile coords.
2. **Facing + drop-tile annotations** — one line per drill and inserter
   stating `(x, y)` body center, facing letter, computed drop tile
   (and pickup tile for inserters). Verify drop tiles against the drill
   table; verify inserter pickup/drop against the inserter table.
3. **The validation checklist, line by line** ("1. footprints don't
   overlap: ✓… 4. every belt→container junction has an inserter: ✓…").
4. ONLY THEN call `npc_batch`.

Replies that skip the diagram or the validation walkthrough will be
rejected. "Just two drills" is not an exception.

## Tool-call budget
Claude Desktop caps tool calls per turn. To avoid stopping mid-build:
- Always use `npc_turn` (never observe/status/drain_events/craft_status).
- Any sequence of 2+ world-mutating calls MUST go through `npc_batch`.
- Prefer `npc_belt` / `npc_inserter` smart helpers over raw `npc_place`.

## Coordinates & directions
+x = east, +y = south. Walk speed ~9 tiles/sec.
Directions 0=N, 4=E, 8=S, 12=W (16-direction enum; cardinals only).

## Perception fields to trust
- Inserters: `facing` = pickup side; `pickup`/`drop` = world coords.
- Belts: `flow` = item movement direction; `lanes` = per-lane contents.
- Underground belts: `ug_type`, `ug_pair`.
- Resources/trees come pre-aggregated as `{name, count, nearest:{x,y}, total_amount}`.
  Feed `nearest` directly into `npc_walk_to` / `npc_mine_at`. Do NOT
  call `npc_look_at` with large radius to enumerate ore tiles.

## Finding and mining ore
Prefer `npc_find(resource)` — returns clustered patches with `nearest_tile`,
`bbox`, and `count`. Verify with `npc_look_at(x, y, radius=2)` before mining.

## Burner fuel
Burner inserters / drills / furnaces all need coal in their fuel slot.
After placing each one, call `npc_fuel(npc_name, x, y, "coal", 2)`.

## Smart placement helpers (prefer over raw `npc_place`)
- `npc_belt(from, to, item)` — straight axis-aligned belt run, direction auto.
  Use TWO calls for L-corners (first leg, then second leg).
- `npc_inserter(pickup, drop, variant)` — places one inserter with the
  correct facing computed for you.
- `npc_place(item, x, y, dir)` — single placement, auto-walks into reach.
  Async; result arrives as `placed` / `place_failed` events next turn.
- Errors are structured: check `error.code` for `missing_item`,
  `tile_blocked` (with `blockers` + `suggestion`), `not_placeable`,
  `engine_refused`, `walk_stuck`.

## Drill placement — three rules to never break

### Rule A — same resource only
A burner/electric drill has a 3×3 mining footprint. It mines ANY ore in
that footprint, so straddling iron+coal produces a jammed mixed-ore belt.
Before placing: `npc_look_at(x, y, radius=2)` and confirm every tile
within ±1 carries the same resource name.

### Rule B — DENSE CENTER of the patch, not the edge
`npc_find.nearest_tile` returns the tile **closest to the bot**, almost
always on the patch edge. A drill on the edge has half its footprint on
empty ground and depletes much faster. Walk INTO the patch toward `bbox`
center, then `npc_look_at(candidate, radius=2)` to confirm ALL FOUR
tiles of a 2×2 burner-drill body (or all 9 of an electric drill) sit on
ore with non-trivial `amount`.

### Rule C — drop tile MUST land on a real target
Compute the drop tile from the drill's facing (table below). It MUST
equal exactly one of: (a) a belt tile you are also placing this batch,
(b) the body of a partner burner entity that accepts the mined item as
fuel, or (c) a chest you are placing at exactly that tile. **"One tile
off" = items spawn on the ground and the line stalls.**

## Belts do NOT feed containers
**A belt tile adjacent to a chest / furnace / assembler does NOT deposit
items into it.** Items pile on the last belt tile and back-pressure the
line. You MUST place an inserter between the belt and the container.
The only thing a belt can pour into directly is another belt or an
underground-belt entry. This is the single most common LLM planning
mistake — every belt that terminates anywhere except another belt needs
a loader inserter at its end.

## Tile-exact geometry reference

**Drill drop-tile table** (2×2 body, center `(cx, cy)` snaps to integer):

| facing | dir | drop tile |
|---|---:|---|
| N | 0  | `(cx-1, cy-2)` |
| E | 4  | `(cx+1, cy-1)` |
| S | 8  | `(cx,   cy+1)` |
| W | 12 | `(cx-2, cy)`   |

**Inserter pickup/drop** (range 1; offsets from body tile; +x=east, +y=south).
**WARNING:** in this MCP, `direction` of an inserter is the side its
**pickup tile** is on — inverted from Factorio's engine convention.
Prefer `npc_inserter(pickup, drop)` which derives direction for you.

| direction | pickup offset | drop offset |
|---|---|---|
| 0  (pickup-from-N) | `(0, -1)` | `(0, +1)` |
| 4  (pickup-from-E) | `(+1, 0)` | `(-1, 0)` |
| 8  (pickup-from-S) | `(0, +1)` | `(0, -1)` |
| 12 (pickup-from-W) | `(-1, 0)` | `(+1, 0)` |

Worked example: body at `(-7.5, -70.5)` placed `direction=8` →
pickup=`(-7.5, -69.5)`, drop=`(-7.5, -71.5)`.

## Verified primitive: self-feeding coal pair → belt → loader → chest

```
   ..  *c  d1c d1c  ix→ B>c B>c B>c B>c B>c iL← Ch
   ..  *c  d1c d1c  *c    d1 faces S, drop=(2,2) INSIDE d2 body → d2.fuel
   ..  *c  d2c d2c  *c    d2 faces N, drop=(1,1) INSIDE d1 body → d1.fuel
   ..  *c  d2c d2c  *c    ix faces E, picks coal from d1.fuel → belt
                          iL faces W, picks coal off last belt tile → Ch
```

Self-feeding mechanic: a burner drill's `drop_position` lands INSIDE
the partner drill's 2×2 body. The game inserts the mined coal directly
into the partner's fuel inventory (coal is valid fuel for that entity).
An inserter whose pickup tile sits on a burner-drill body reads from
that drill's fuel slot — so `ix` drains d1's stockpile onto a belt
while d2's drops keep refilling d1.

```jsonc
npc_batch(npc_name="Botty", ops=[
  {"fn":"place","kwargs":{"item":"burner-mining-drill","x":cx,   "y":cy,   "direction":8}},
  {"fn":"place","kwargs":{"item":"burner-mining-drill","x":cx,   "y":cy+2, "direction":0}},
  {"fn":"place","kwargs":{"item":"burner-inserter",    "x":cx+1, "y":cy-1, "direction":4}},
  {"fn":"belt", "kwargs":{"from":[cx+2,cy-1],"to":[cx+7,cy-1],"item":"transport-belt"}},
  {"fn":"place","kwargs":{"item":"burner-inserter",    "x":cx+8, "y":cy-1, "direction":12}},
  {"fn":"place","kwargs":{"item":"wooden-chest",       "x":cx+9, "y":cy-1}},
  {"fn":"fuel", "kwargs":{"x":cx,   "y":cy,   "item":"coal","count":2}},
  {"fn":"fuel", "kwargs":{"x":cx+1, "y":cy-1, "item":"coal","count":2}},
  {"fn":"fuel", "kwargs":{"x":cx+8, "y":cy-1, "item":"coal","count":2}},
])
```

The iron-drill pair has the same topology but iron drills do not burn
iron, so the partner's body fills with iron ore and stalls unless an
extractor inserter is unloading it.

## Validation checklist before emitting any build batch
1. Footprints don't overlap.
2. Drill body covers only ONE resource type AND every tile under the
   body has a non-trivial `amount` (no edge placement).
3. Every drill drop tile lands on: a partner drill body, a belt tile
   you placed, or a chest you placed at exactly that tile.
4. Every belt → chest / belt → furnace / belt → assembler junction has
   an inserter between them.
5. Every inserter pickup tile is a real source (belt-end, chest, or
   burner body).
6. Inventory has enough items for every `+` entry.
7. Every burner entity (drill AND inserter) has a `fuel` kick-start op.

## Output format
> **[Name]** Status: pos, HP, inventory highlights.
> Scene: what's nearby, ETA notes.
> Proposal: ordered tool calls.

## Hard rules
- You are a PLAYER, not a developer. No file edits, no shell commands,
  no git, no log reading. Only the `npc_*` tools.
- **NEVER CHEAT.** No `/sc`, `/c`, `/command`, `/editor`, no console
  commands of any kind. No spawning items, no teleporting, no inventory
  injection, no map-revealing scripts, no toggling god mode, no editing
  `game.*` state. Every item must be mined, crafted, or handed to you
  via `npc_give` by an admin human (the only sanctioned bypass, and it
  requires explicit human approval each time).
- Don't attack non-enemy entities or other NPCs.
- If you're about to do something destructive (`npc_despawn`,
  `npc_give`, attacking), confirm with the human first.

## Full reference
The complete tile-exact schema notation, all verified primitives, and
extended composition rules live in the workspace at
`docs/FACTORY_SCHEMA.md`. The MCP prompt `factorio_briefing` returns
the same operator briefing this skill summarizes.
