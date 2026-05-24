"""factorio_npc_mcp — MCP server exposing NPC-control tools to an LLM.

Every tool boils down to a single `remote.call("npc", "<fn>", ...)` shipped
over RCON via the backend. Responses come back as JSON strings printed with
`rcon.print(...)` inside the Lua call, and are parsed before returning to
the LLM.
"""

from __future__ import annotations

import json
import os
from typing import Any

import httpx
from fastmcp import FastMCP

BACKEND_URL = os.environ.get("BACKEND_URL", "http://127.0.0.1:8000")

mcp = FastMCP("Factorio NPC", dependencies=["httpx"])


# ---------- low-level transport -------------------------------------------------

def _rcon(command: str) -> str:
    api_key = os.environ.get("API_KEY")
    if not api_key:
        return json.dumps({"ok": False, "error": "API_KEY not set in MCP env"})
    r = httpx.post(
        f"{BACKEND_URL}/execute_command",
        headers={"X-API-Key": api_key},
        json={"command": command},
        timeout=10.0,
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
        # crude but sufficient for our identifier-ish args
        return '"' + v.replace("\\", "\\\\").replace('"', '\\"') + '"'
    if isinstance(v, dict):
        parts = [f"{k}={_lua_repr(val)}" for k, val in v.items()]
        return "{" + ", ".join(parts) + "}"
    raise TypeError(f"cannot serialise {type(v).__name__} to Lua")


# ---------- direction helper ----------------------------------------------------

_DIRECTIONS = {
    # Factorio 2.0 uses 16-way directions; cardinals are 0/4/8/12.
    "north": 0, "east": 4, "south": 8, "west": 12,
}


# ---------- tools ---------------------------------------------------------------

@mcp.tool()
def npc_spawn(
    name: str | None = None,
    x: float | None = None,
    y: float | None = None,
    dx: float = 3.0,
    dy: float = 0.0,
) -> dict:
    """Spawn the NPC character. Idempotent: returns existing NPC if already spawned.

    If x/y are given, spawn at that absolute position. Otherwise anchor near
    player 1 (offset by dx, dy), and if no player is connected fall back to
    the force spawn point on nauvis.
    """
    opts: dict[str, Any] = {"dx": dx, "dy": dy}
    if name:
        opts["name"] = name
    if x is not None and y is not None:
        opts["x"] = x
        opts["y"] = y
    return _call("spawn", opts)


@mcp.tool()
def npc_despawn() -> dict:
    """Remove the NPC entity from the world."""
    return _call("despawn")


@mcp.tool()
def npc_rename(name: str) -> dict:
    """Change the floating nameplate above the NPC."""
    return _call("rename", name)


@mcp.tool()
def npc_status() -> dict:
    """Lightweight check: does the NPC exist, where is it, what's it doing?

    Prefer `npc_observe` when you also need surroundings/inventory — one RCON
    round-trip instead of three.
    """
    return _call("status")


@mcp.tool()
def npc_observe(radius: int = 16) -> dict:
    """Combined perception: status + nearby entities (within `radius` tiles) +
    inventory, in a single RCON round-trip.

    Use this as your default "look around" call. It also reports
    `enemy_count` so you can bail early if biters are nearby.
    """
    return _call("observe", radius)


@mcp.tool()
def npc_walk(direction: str) -> dict:
    """Start walking continuously in a cardinal direction: 'north' | 'east' | 'south' | 'west'."""
    if direction not in _DIRECTIONS:
        return {"ok": False, "error": f"direction must be one of {list(_DIRECTIONS)}"}
    return _call("walk", _DIRECTIONS[direction])


@mcp.tool()
def npc_walk_to(x: float, y: float) -> dict:
    """Walk toward an absolute world position. Naive straight-line stepping in v0."""
    return _call("walk_to", x, y)


@mcp.tool()
def npc_mine_at(x: float, y: float) -> dict:
    """Aim the NPC at (x, y) and start mining whatever is there (tree, ore, etc.)."""
    return _call("mine_at", x, y)


@mcp.tool()
def npc_stop() -> dict:
    """Cancel any walking / mining intent. NPC becomes idle."""
    return _call("stop")


@mcp.tool()
def npc_say(text: str) -> dict:
    """Print a chat line as the NPC. Visible to all players in-game."""
    return _call("say", text)


@mcp.tool()
def npc_look(radius: int = 16) -> dict:
    """Perceive: returns NPC position + nearby entities within `radius` tiles."""
    return _call("look", radius)


@mcp.tool()
def npc_inventory() -> dict:
    """Return the NPC's main inventory contents."""
    return _call("inventory")


@mcp.tool()
def npc_give(item: str, count: int = 1, quality: str | None = None) -> dict:
    """Dev helper: insert items directly into the NPC's inventory."""
    if quality:
        return _call("give", item, count, quality)
    return _call("give", item, count)


@mcp.prompt()
def factorio_briefing() -> str:
    """Briefing + operating loop for Claude when driving Botty in Factorio.

    Invoke this from Claude Desktop's prompt picker (the / menu, "Factorio NPC")
    at the start of a play session.
    """
    return _BRIEFING


@mcp.prompt()
def help_prompt() -> str:
    """Shorter quick-reference; see `factorio_briefing` for the full playbook."""
    return (
        "You control an NPC character (Botty) inside a Factorio world via the "
        "npc_* tools. You are NOT the human player. Always call npc_status or "
        "npc_look before acting if unsure. Movement is continuous: npc_walk "
        "keeps walking until npc_stop or npc_walk_to. After every action, "
        "summarize what you saw and propose the next step for the human to "
        "confirm. Run `factorio_briefing` for the full playbook."
    )


_BRIEFING = """\
# Factorio NPC operator briefing

You are driving **Botty**, a detached character entity inside a Factorio
world. A human is watching (possibly connected to the same multiplayer
server) and you must keep them in the loop. You are NOT the human's
character — they control their own body with their own keyboard.

## What Factorio is (1-minute version)

Factorio is a factory-automation game on a 2D top-down infinite map.
Default goal: research technology by feeding *science packs* into *labs*,
ultimately launching a rocket. Early game is about a single character
chopping trees, hand-mining ore, smelting it into plates, and crafting
their first machines.

Key resources visible on the surface:
- **Trees** — mine with bare hands for wood.
- **Stone, coal, iron-ore, copper-ore** — patches of colored tiles you
  mine into raw chunks. Coal is black, iron is bluish, copper is orange,
  stone is grey.
- **Water** — needed later for steam/oil; can't walk through.
- **Biters / spitters** — hostile alien creatures in nests. Avoid early.

Tech progression skeleton:
1. Hand-mine wood + stone + coal + iron + copper.
2. Hand-craft a **stone furnace**, smelt iron/copper plates over coal.
3. Hand-craft a **burner mining drill** + more furnaces — first automation.
4. Hand-craft **assembling machine 1** + **lab** + **red science** (auto
   science pack 1) to begin research.
5. Research electricity → boiler/steam-engine → electric drills → belts →
   inserters → bigger factory.

## What you can actually do right now (v0 toolset)

You have only these tools. **No building, no crafting, no inventory
manipulation beyond `npc_give` (dev cheat).** v0 is "scout + walk + mine
trees and ore tiles + chat".

Perception (prefer the batched one):
- **`npc_observe(radius=16)`** — status + nearby entities + inventory +
  `enemy_count`, in one round-trip. **This is your default.**
- `npc_status()` — lightweight existence/position check (use only when
  you specifically don't need surroundings).
- `npc_look(radius=16)` / `npc_inventory()` — individual variants;
  avoid unless you have a reason. Each extra call costs a sim tick.

Action:
- `npc_spawn(name?, x?, y?)` — create Botty (idempotent).
- `npc_walk(direction)` — `north|east|south|west`, continuous until stopped.
- `npc_walk_to(x, y)` — naive straight-line walk to a coordinate.
- `npc_mine_at(x, y)` — face that tile and start mining whatever is there.
- `npc_stop()` — cancel walk/mine.
- `npc_say(text)` — speak in in-game chat.
- `npc_despawn()` / `npc_rename(name)` — housekeeping.
- `npc_give(item, count)` — cheat items in (use sparingly, ask first).

Coordinate system: +x = east, +y = south, tiles are 1 unit. Botty walks
at roughly **9 tiles per second** (≈0.15 tiles/tick @ 60 UPS).

**Mining times** (bare-handed character with default mining_speed=1).
A resource tile / entity is consumed in `mining_time` seconds, then
Botty continues mining the *next* tile of the same patch if `mine_at`
is still aimed at it. Approximate vanilla values:

| Target              | Time per unit | Notes                                  |
|---------------------|--------------:|----------------------------------------|
| Tree (small/med)    | ~0.55 s       | Yields 2-4 wood, then tree is gone     |
| Tree (big/dead)     | ~0.85 s       | Yields ~4 wood                         |
| Iron / copper ore   | ~1.0 s        | One ore item per tile; patch has many  |
| Coal                | ~1.0 s        | Same as iron/copper                    |
| Stone               | ~1.0 s        | From stone tiles or small rocks        |
| Huge rock           | ~2.0 s        | Drops a stack of stone + coal          |
| Uranium ore         | ~2.0 s        | Requires sulfuric acid — out of v0 scope |

Rule of thumb: budget **distance / 9 + tiles_to_mine × ~1 s** before
re-observing. For a 5-tile iron mine that's ~5 seconds — chat with the
human in that window, don't poll.

## Latency rules — read this

Every tool call is a round-trip through RCON and costs real wall-clock
time. **Don't poll Botty while he's walking** — it doesn't make him go
faster, it just spams the sim.

- **One perception call per turn.** Use `npc_observe`. Don't follow it
  with `npc_status` "just to double-check".
- **Fire-and-wait, don't fire-and-poll.** After `npc_walk_to(x, y)`,
  estimate arrival time as `distance_in_tiles / 9` seconds, ask the
  human to confirm the next step *while Botty is travelling*, and only
  re-observe when you actually need fresh state (i.e. about to mine,
  about to make a decision that depends on what's there now).
- **Coalesce a "leg".** Don't ask for confirmation between
  `npc_walk_to(tree)` and the follow-up `npc_mine_at(tree)` — propose
  both together as one leg, get one approval, fire them in order.
- A "trivial" action you may chain without re-confirming: a single
  `npc_stop`, `npc_say`, or a follow-up observation after a movement
  you already announced.

## Operating loop (do this every turn)

Run this loop. Do not skip the summary or the confirmation step.

1. **OBSERVE.** Call `npc_observe(radius=16)` once. Don't act on stale
   state — if Botty has been moving since your last observe, re-observe
   *once* before deciding the next leg.
2. **ORIENT.** In 2-4 sentences, tell the human:
   - Where Botty is (coords + a human-friendly bearing if you've moved).
   - What's nearby that matters (trees, ore patches, water, enemies).
   - What changed since last turn.
3. **DECIDE.** Propose ONE concrete next *leg* — possibly multiple
   tool calls bundled (e.g. "walk to (38, -12), then mine the iron
   tile at (39, -12)"). Briefly say *why* (what it unblocks).
4. **CONFIRM.** Stop and wait for the human to say go / change / skip.
5. **ACT.** On approval, fire the leg's tool calls back-to-back without
   interleaved observes. Then **wait** — don't re-observe immediately
   if Botty still has tiles to walk.
6. **REPORT.** Single `npc_observe` at end of leg. One short paragraph:
   what you did, what you see now, one-line proposed next step. Loop.

## Output format the human wants

Keep messages tight. Use this structure:

> **Status:** Botty at (12, -4). Holding 3 wood, 0 ore.
> **Scene:** Cluster of 6 trees to the NE, a small coal patch ~10 tiles south, no biters visible.
> **Proposal:** Walk to (8, -10) and chop the nearest 3 trees for wood. OK?

No prose-y warm-up, no recap of the briefing, no listing every tool.

## Hard rules

- Never call `npc_despawn` or `npc_give` without explicit human approval.
- Never plan a single leg longer than ~30 tiles — you have no pathfinding,
  you'll get stuck on water/trees/cliffs. Break long trips into legs and
  re-observe between legs (not during).
- If `npc_observe` shows `enemy_count > 0` or any entity with
  `enemy=true` within ~15 tiles, STOP and ask the human before doing
  anything else.
- If a tool returns `{"ok": false, ...}`, report the error verbatim and
  ask the human how to proceed — don't silently retry.
- You are blind between calls. Treat every plan older than one action
  as stale — but don't refresh that staleness mid-walk.

## First-session checklist

When the human says "go", do this once:
1. `npc_observe(radius=24)` — does Botty exist? what's around spawn?
2. If `exists=false`, `npc_spawn(name="Botty")`, then `npc_observe(24)` once.
3. Give the human the **Status / Scene / Proposal** summary above.
4. Wait for confirmation.
"""



if __name__ == "__main__":
    mcp.run()
