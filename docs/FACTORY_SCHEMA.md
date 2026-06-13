# Factory schema notation

A compact, tile-exact way to describe Factorio layouts so the LLM can
*plan*, *render*, and *execute* in one shared representation.

Every cell = exactly **one tile**. The grid uses world coordinates
(`+x = east`, `+y = south`). One glyph per tile, rendered as 2–4 chars
in a monospace column for alignment.

## Tile glyphs

| Glyph | Meaning |
|---|---|
| `..` | walkable ground, empty |
| `~~` | water (blocks placement, blocks walking) |
| `##` | rock / cliff |
| `*c` `*i` `*u` `*C` | exposed ore tile: coal / iron-ore / uranium / copper-ore |
| `dN` | burner-mining-drill instance #N (occupies 2×2 — all 4 cells share the label) |
| `DN` | electric-mining-drill instance #N (3×3) |
| `fN` | stone-furnace #N (burner, 2×2) |
| `FN` | steel-furnace #N (burner, 2×2) |
| `aN` | assembling-machine-1 #N (3×3) |
| `Bx` | belt with flow `B>` `B<` `B^` `Bv` (1×1) |
| `Ux` `Dx` | underground-belt entry/exit |
| `iD` | burner-inserter (1×1); `D` ∈ `^v<>` = **drop side** (pickup is opposite, 1 tile) |
| `ID` | regular inserter (electric, range 1) |
| `LD` | long-handed inserter (electric, range 2) |
| `Ch` | wooden-chest |
| `Cs` | steel-chest |

**Suffix** = the resource tile *underneath* the entity. `d1c` = drill 1
standing on coal. Visible if the entity were removed.

**Facing block** below the grid spells out every drill/inserter direction
explicitly:

```
facing:
  d1: S    # 0=N 4=E 8=S 12=W
  d2: N
  ix: E    # inserter face = pickup side
```

## Planning prefixes (diffs)

| Prefix | Meaning |
|---|---|
| `+d1c` | add this entity |
| `-d1`  | remove |
| `?d1`  | candidate / alternative |
| `!..`  | known-blocked tile |

## Verified entity geometry (probed live, do **not** guess)

### `burner-mining-drill`
- Footprint: 2×2, centered on integer position. For `center=(cx,cy)`
  the body covers tiles `(cx-1, cy-1)`, `(cx, cy-1)`, `(cx-1, cy)`, `(cx, cy)`.
- `mining_drill_radius = 0.99` → effective 2×2 mining footprint = body itself.
- `drop_position` (where mined items land), computed live per instance:

| facing | dir | drop world-pos (Δ from center) | drop **tile** |
|---|---|---|---|
| N | 0 | `(-0.5, -1.3)` | `(cx-1, cy-2)` |
| E | 4 | `(+1.3, -0.5)` | `(cx+1, cy-1)` |
| S | 8 | `(+0.5, +1.3)` | `(cx,   cy+1)` |
| W | 12 | `(-1.3, +0.5)` | `(cx-2, cy)` |

### `burner-inserter`
- Footprint: 1×1.
- `pickup_offset = (0, -1)`, `drop_offset = (0, +1.2)` at `dir=0` (N).
- `direction` = **pickup side**. Rotates the offsets clockwise.
- Pickup tile and drop tile are both **range 1** from the inserter body.

| dir | pickup tile (Δ) | drop tile (Δ) | glyph (drop side) |
|---|---|---|---|
| 0 N | `(0, -1)` | `(0, +1)` | `iv` |
| 4 E | `(+1, 0)` | `(-1, 0)` | `i<` |
| 8 S | `(0, +1)` | `(0, -1)` | `i^` |
| 12 W | `(-1, 0)` | `(+1, 0)` | `i>` |

### `transport-belt`
- 1×1, `direction` = flow direction. Items accumulate at the last tile of a
  belt segment that has no downstream consumer.

## Placement validity rules

1. **Footprint must not overlap** any other entity body. Belts can sit
   under an inserter's *arm path* but not under its body.
2. **A drill's drop tile is on the outer edge of its body** — no room
   exists for an inserter between a drill and the tile it drops on.
3. **An inserter is the tile *between* its pickup and drop** — it cannot
   bridge two tiles that are already touching.
4. **Burner inserter range = 1** (vanilla). To bridge a 2-tile gap use
   `long-handed-inserter` (range 2, but electric).
5. **A burner entity's `drop_target` accepts the mined item directly into
   its fuel inventory** if the item is a valid fuel for that entity.
   This is the foundation of the self-feeding pair pattern below.
6. **An inserter that picks from a tile occupied by a burner entity reads
   that entity's fuel inventory** (verified — burner-inserter pulls coal
   out of a burner-mining-drill's fuel slot).
7. **Belts do NOT deposit into containers.** A belt tile adjacent to a
   chest / furnace / assembler does **not** transfer items. You MUST
   place an inserter between the belt and the container. The only
   destinations a belt can pour into directly are another belt or an
   underground-belt entry. This is the single most common LLM planning
   mistake — every belt that terminates anywhere except another belt
   needs an `iL` loader inserter at its end.
8. **Drills must sit on dense interior tiles, not patch edges.** All 4
   tiles of a 2×2 burner-drill body (or all 9 tiles of an electric
   drill) must overlap an ore tile with non-trivial `amount`. A drill
   with even one corner off the patch wastes ~25% of its mining rate
   AND depletes much faster because it concentrates work on fewer ore
   tiles. `npc_find.nearest_tile` returns the tile **closest to the
   bot**, which is almost always on the patch edge — walk into the
   patch toward `bbox` center before placing.

## Validating a candidate schema

For each entity in the proposed layout:

1. **Footprint check** — expand to occupied tiles; assert no overlap.
2. **Drill resource check** — every tile under the drill body must carry
   the same ore suffix (`*c` ≠ `*i` ≠ mixed). Mixed = jammed belt.
3. **Drill density check** — every tile under the drill body must be on
   ore (not empty ground). Re-check by `npc_look_at(center, radius=2)`
   and confirm every tile in the body has a resource entry. Move the
   drill one tile interior if any corner is empty.
4. **Drop tile check** — compute the drill's `drop tile` from its facing
   (table above). Assert that tile is exactly one of:
   - a belt the LLM is also placing this batch, or
   - the body of another entity that will accept this item (for the
     pair pattern), or
   - a chest the LLM is also placing this batch at that tile.
   "One tile off" = items dropped on the ground = stalled line.
5. **Belt-terminus check** — every belt segment must end with one of:
   - another belt / underground-belt entry, or
   - an inserter loading something else from that belt's last tile.
   A belt whose last tile sits next to a chest/furnace/assembler with
   no inserter is broken.
6. **Inserter pickup/drop check** — compute pickup and drop tiles.
   Assert pickup tile is a real source (belt tile, chest body, burner
   body) and drop tile is a valid target (entity body, belt, or chest).
7. **Inventory check** — sum item costs across all `+` entries, compare
   to NPC inventory before emitting the batch.
8. **Fuel kick-start** — every burner entity (drill AND inserter) needs
   at least one `fuel` op to bootstrap. After that the pattern
   self-sustains as long as coal keeps flowing.

## Verified primitive: self-feeding coal drill pair + surplus extractor

This is the foundation of any all-burner-tier base. Verified live
2026-05-24 on Factorio 2.0.76 Space Age headless.

```
             col     0    1    2    3     4    5    6    7    8    9    10   11
       row -1:      ..   *c   *c   *c    ..   ..   ..   ..   ..   ..   ..   ..
       row  0:      ..   *c  d1c  d1c    ix→ B>c  B>c  B>c  B>c  B>c  iL← Ch
                                 ↓ d1 drops south
       row  1:      ..   *c  d1c  d1c    *c
                                 drop tile (2,2) is inside d2 body
       row  2:      ..   *c  d2c  d2c    *c
                                 ↑ d2 drops north
       row  3:      ..   *c  d2c  d2c    *c
                                 drop tile (1,1) is inside d1 body

facing:
  d1: S    drop_tile=(2,2)
  d2: N    drop_tile=(1,1)
  ix: E    pickup_tile=(2,0) drop_tile=(4,0)
  iL: W    pickup_tile=(9,0) drop_tile=(11,0)
flow:
  d1 mines  → (2,2) → d2.fuel
  d2 mines  → (1,1) → d1.fuel
  ix        reads  → d1.fuel → drops on belt (4,0)
  belt      flows  → east across (4,0)..(9,0)
  iL        reads  → belt tile (9,0) → drops in chest (11,0)
```

Note `iL` (the loader inserter). **A belt cannot pour into a chest —
you need this inserter.** Without `iL`, items pile on the last belt
tile, back-pressure travels upstream, and the extractor `ix` eventually
stalls.

Build batch:

```jsonc
npc_batch(npc_name="Botty", ops=[
  {"fn":"place","kwargs":{"item":"burner-mining-drill","x":2,"y":1,"direction":8}},  // d1 south
  {"fn":"place","kwargs":{"item":"burner-mining-drill","x":2,"y":3,"direction":0}},  // d2 north
  {"fn":"place","kwargs":{"item":"burner-inserter",    "x":3,"y":0,"direction":4}},  // ix east
  {"fn":"belt", "kwargs":{"from":[4,0],"to":[9,0],"item":"transport-belt"}},
  {"fn":"place","kwargs":{"item":"burner-inserter",    "x":10,"y":0,"direction":12}}, // iL west
  {"fn":"place","kwargs":{"item":"wooden-chest",       "x":11,"y":0}},
  {"fn":"fuel", "kwargs":{"x":2, "y":1,"item":"coal","count":2}},   // kick d1
  {"fn":"fuel", "kwargs":{"x":3, "y":0,"item":"coal","count":2}},   // kick ix
  {"fn":"fuel", "kwargs":{"x":10,"y":0,"item":"coal","count":2}},   // kick iL
])
```

Verified outcomes from the earlier 7-op build (without the `iL` loader
inserter, belt terminated next to a chest):

| Slot | t=0 | t=60s |
|---|---:|---:|
| `d1.fuel` | 2 | 0 (oscillating, still working) |
| `d2.fuel` | 0 | 13 |
| `chest`   | 0 | **0** — items piled on the last belt tile, never entered chest |
| `d1.status` `d2.status` | working | working |

The self-feeding fuel loop works. The chest-loading half does not work
without `iL` — that is precisely the bug the loader inserter above
fixes. Re-verify with `iL` next build cycle and update this table.

## Composition rules

- **One pair = one coal source.** Anchor coordinates to the lower-right
  cell of d1 (its center). The pattern is translation-invariant on coal.
- **Iron-drill pair works the same way** — iron drills route mined iron
  ore into the partner's *output* inventory (iron drills don't burn iron).
  The partner must therefore be *unloaded* by an extractor inserter or
  it stalls within seconds. Same `ix` extractor pattern applies, picking
  from the partner's body and dropping onto an iron belt.
- **Furnaces** are 2×2, two inserter sides: one for the input ore belt,
  one for the coal belt. Compose by routing the coal-pair surplus belt
  and the iron-pair surplus belt to converge at a furnace.

## How to render this schema from a live observation

Pseudocode for an `npc_schema(center, radius)` tool:

```
for tile in (radius+1)*(radius+1) box around center:
    if tile has water:      glyph = "~~"
    elif tile has rock:     glyph = "##"
    else:                   glyph = ".."
    if resource on tile:    overlay suffix from resource.name
for entity in find_entities(area):
    expand entity footprint over its tiles
    for each footprint tile: replace glyph with entity_label + suffix
    record entity in facing[] block with its direction
emit grid + facing + flow annotations as one string
```

This gives the LLM a single representation it can both *read from
perception* and *write as a build plan*, with byte-identical glyphs.
