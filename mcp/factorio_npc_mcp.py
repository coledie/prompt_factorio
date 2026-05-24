"""factorio_npc_mcp — MCP server exposing NPC-control tools to an LLM.

Every tool boils down to a single `remote.call("npc", "<fn>", ...)` shipped
over RCON via the backend. Responses come back as JSON strings printed
with `rcon.print(...)` inside the Lua call, and are parsed before
returning to the LLM.

See mod/npc_mcp/PLAN.md and mod/npc_mcp/control.lua for the in-game side.
"""

from __future__ import annotations

import json
import os
from typing import Any

import httpx
from fastmcp import FastMCP

BACKEND_URL = os.environ.get("BACKEND_URL", "http://127.0.0.1:8000")

# Server-level instructions are sent in the MCP `initialize` response and
# Claude Desktop folds them into the system context automatically — so the
# operator briefing is in effect from the first message of every chat that
# has the `factorio-npc` MCP server enabled. No need to attach the
# `factorio_briefing` prompt manually each session.
_BRIEFING = """\
# Factorio NPC operator briefing (headless edition)

You are driving **Botty**, a detached character on a HEADLESS Factorio
dedicated server. **No human player is connected** — you are the only
actor in the world. The mod auto-spawned Botty on server boot. A human
is watching chat and confirming each non-trivial action.

## What Factorio is (1-minute version)

2D top-down infinite map. Goal: research tech by feeding science packs
into labs, ultimately launching a rocket. Early game: chop wood,
hand-mine ore, smelt plates in stone furnaces over coal, craft a burner
mining drill, then assemblers + labs + red science.

Visible resources: trees (wood), stone, coal (black), iron-ore (blue),
copper-ore (orange), water (impassable), biters / spitters (enemies).

## Toolset (everything below is implemented)

Perception:
- **`npc_observe(radius=16)`** — your default. Position + inventory +
  nearby entities + enemy_count + daytime, one round-trip.
- `npc_drain_events()` — pull queued events (arrived, craft_done,
  research_finished, mined_out, died...). Call at start of each turn.
- `npc_look`, `npc_look_at(x,y,r)`, `npc_inventory`,
  `npc_screenshot(zoom, width, height)`, `npc_chart(x,y,r)`,
  `npc_map_summary`, `npc_research_status`, `npc_tech_tree(only_available=True)`.

Movement:
- `npc_walk_to(x, y)` — async pathfind; emits `arrived`.
- `npc_walk(direction)`, `npc_stop()`.

Gathering: `npc_mine_at(x, y)` (auto-approaches into reach).

Crafting (simulated, works without a player):
- `npc_craft(recipe, count)`, `npc_craft_status()`, `npc_cancel_craft(i)`.

Building: `npc_place(item, x, y, dir=0)`, `npc_pickup(x, y)`,
`npc_rotate(x, y, dir)`, `npc_set_recipe(x, y, recipe)`.

Logistics: `npc_insert_into(x,y,item,n)`, `npc_take_from(x,y,item,n)`,
`npc_fuel(x,y,fuel="coal",n=5)`.

Research: `npc_research(tech)`.

Combat: `npc_equip(armor, gun, ammo, ammo_count)`, `npc_shoot_at(x, y)`.

Chat / cheats (need approval): `npc_say`, `npc_give`, `npc_save`,
`npc_despawn`.

## Coordinates & latency

- +x = east, +y = south. Botty walks ~9 tiles/sec.
- Each tool call is a round-trip; **do not poll mid-walk**. Estimate
  `eta = distance / 9` seconds, then `npc_drain_events()` to check.
- One perception call per turn.

## Operating loop

1. **DRAIN.** `npc_drain_events()` — what changed?
2. **OBSERVE.** `npc_observe(16)`.
3. **REPORT.** Status / Scene / Proposal block (see below).
4. **CONFIRM.** Wait for human "go".
5. **ACT.** Fire the proposed tool calls back-to-back without
   interleaved observes.
6. Goto 1 once you expect the leg to be done.

## Output format

> **Status:** Botty at (12, -4), HP 250. Holding 3 wood, 6 iron-ore.
> **Scene:** Iron patch ~6 east. Coal seam ~10 south. No biters.
> **Proposal:** walk_to(18, -4) -> mine_at(20, -4) until 20 iron-ore. ETA ~25s.

## Hard rules

- Never `npc_despawn` or `npc_give` without explicit human approval.
- If `enemy_count > 0` within ~15 tiles, STOP and ask.
- If a tool returns `{"ok": false, ...}`, surface the error verbatim.
- Single legs ≤ 30 tiles. No global pathfinding shortcuts.

## First-session checklist

When the human says "hi" / "go" / anything in a fresh chat:
1. `npc_drain_events()` (probably sees a `spawn` event).
2. `npc_observe(24)`.
3. Status / Scene / Proposal → wait for "go".
"""

mcp = FastMCP("Factorio NPC", dependencies=["httpx"], instructions=_BRIEFING)


# ---------- low-level transport -------------------------------------------------

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


# ============================================================================
# Lifecycle
# ============================================================================

@mcp.tool()
def npc_spawn(
    name: str | None = None,
    x: float | None = None,
    y: float | None = None,
    dx: float = 3.0,
    dy: float = 0.0,
) -> dict:
    """Spawn Botty. Idempotent. The mod auto-spawns on server boot, so this is
    mainly for relocating or re-spawning after `npc_despawn`."""
    opts: dict[str, Any] = {"dx": dx, "dy": dy}
    if name:
        opts["name"] = name
    if x is not None and y is not None:
        opts["x"] = x
        opts["y"] = y
    return _call("spawn", opts)


@mcp.tool()
def npc_despawn() -> dict:
    """Remove Botty. Requires explicit human approval."""
    return _call("despawn")


@mcp.tool()
def npc_rename(name: str) -> dict:
    """Change Botty's display name."""
    return _call("rename", name)


@mcp.tool()
def npc_save(name: str | None = None) -> dict:
    """`game.server_save(name)` — snapshot the world."""
    if name:
        return _call("save", name)
    return _call("save")


# ============================================================================
# Perception
# ============================================================================

@mcp.tool()
def npc_status() -> dict:
    """Lightweight existence/position/intent check. Prefer `npc_observe`."""
    return _call("status")


@mcp.tool()
def npc_observe(radius: int = 16) -> dict:
    """Default perception: position + inventory + nearby entities + enemy_count.
    One RCON round-trip; use this instead of chaining status/look/inventory."""
    return _call("observe", radius)


@mcp.tool()
def npc_look(radius: int = 16) -> dict:
    """Just nearby entities around Botty."""
    return _call("look", radius)


@mcp.tool()
def npc_look_at(x: float, y: float, radius: int = 16) -> dict:
    """Perception anchored at an arbitrary point (charted area only)."""
    return _call("look_at", x, y, radius)


@mcp.tool()
def npc_inventory() -> dict:
    """Main inventory + armor/guns/ammo/trash."""
    return _call("inventory")


@mcp.tool()
def npc_drain_events() -> dict:
    """Consume the in-game event ring buffer. Call at the start of each turn."""
    return _call("drain_events")


@mcp.tool()
def npc_screenshot(
    zoom: float = 0.5,
    width: int = 1024,
    height: int = 1024,
    show_entity_info: bool = True,
    x: float | None = None,
    y: float | None = None,
) -> dict:
    """Render a top-down screenshot. Response includes a URL hint:
    `http://127.0.0.1:8000/screenshot/{name}`."""
    opts: dict[str, Any] = {
        "zoom": zoom,
        "resolution": [width, height],
        "show_entity_info": show_entity_info,
    }
    if x is not None and y is not None:
        opts["position"] = {"x": x, "y": y}
    return _call("screenshot", opts)


@mcp.tool()
def npc_chart(x: float, y: float, radius: int = 64) -> dict:
    """Reveal an area on the map without moving."""
    return _call("chart", x, y, radius)


@mcp.tool()
def npc_map_summary() -> dict:
    """Aggregate of resource patches within ~128 tiles of Botty."""
    return _call("map_summary")


@mcp.tool()
def npc_research_status() -> dict:
    """Current research + progress + queue."""
    return _call("research_status")


@mcp.tool()
def npc_tech_tree(only_available: bool = True) -> dict:
    """List unresearched techs; `only_available=True` => prereqs met."""
    return _call("tech_tree", only_available)


# ============================================================================
# Movement
# ============================================================================

@mcp.tool()
def npc_walk(direction: str) -> dict:
    """Walk continuously in a cardinal direction until stopped."""
    if direction not in _DIRECTIONS:
        return {"ok": False, "error": f"direction must be one of {list(_DIRECTIONS)}"}
    return _call("walk", _DIRECTIONS[direction])


@mcp.tool()
def npc_walk_to(x: float, y: float) -> dict:
    """Pathfind and walk to (x, y). Async; emits `arrived` event when done."""
    return _call("walk_to", x, y)


@mcp.tool()
def npc_stop() -> dict:
    """Cancel current intent (walk / mine / shoot)."""
    return _call("stop")


# ============================================================================
# Gathering
# ============================================================================

@mcp.tool()
def npc_mine_at(x: float, y: float) -> dict:
    """Auto-approach to reach distance, then mine whatever's at (x, y) until gone."""
    return _call("mine_at", x, y)


# ============================================================================
# Crafting
# ============================================================================

@mcp.tool()
def npc_craft(recipe: str, count: int = 1) -> dict:
    """Queue a hand-craft. Ingredients consumed when each unit starts;
    product inserted when its timer expires. Emits `craft_done` per unit."""
    return _call("craft", recipe, count)


@mcp.tool()
def npc_craft_status() -> dict:
    """Inspect the simulated hand-craft queue."""
    return _call("craft_status")


@mcp.tool()
def npc_cancel_craft(index: int = 1) -> dict:
    """Drop a craft queue entry (1 = head). No refund of consumed ingredients."""
    return _call("cancel_craft", index)


# ============================================================================
# Building
# ============================================================================

@mcp.tool()
def npc_place(item: str, x: float, y: float, direction: int = 0) -> dict:
    """Place a building from inventory. `direction` is 0..15 (Factorio 16-way)."""
    return _call("place", item, x, y, direction)


@mcp.tool()
def npc_pickup(x: float, y: float) -> dict:
    """Mine a friendly entity at (x, y) back into Botty's inventory."""
    return _call("pickup", x, y)


@mcp.tool()
def npc_rotate(x: float, y: float, direction: int) -> dict:
    """Rotate the entity at (x, y) to a 0..15 direction."""
    return _call("rotate", x, y, direction)


@mcp.tool()
def npc_set_recipe(x: float, y: float, recipe: str) -> dict:
    """Set the recipe of the assembling machine at (x, y)."""
    return _call("set_recipe", x, y, recipe)


# ============================================================================
# Logistics
# ============================================================================

@mcp.tool()
def npc_insert_into(x: float, y: float, item: str, count: int = 1) -> dict:
    """Insert items from Botty into the container/machine at (x, y)."""
    return _call("insert_into", x, y, item, count)


@mcp.tool()
def npc_take_from(x: float, y: float, item: str, count: int = 1) -> dict:
    """Take items from the container/machine at (x, y) into Botty."""
    return _call("take_from", x, y, item, count)


@mcp.tool()
def npc_fuel(x: float, y: float, fuel: str = "coal", count: int = 5) -> dict:
    """Convenience: stick fuel into the burner at (x, y)."""
    return _call("fuel", x, y, fuel, count)


# ============================================================================
# Research
# ============================================================================

@mcp.tool()
def npc_research(tech: str) -> dict:
    """Append a tech to the force's research queue."""
    return _call("research", tech)


# ============================================================================
# Combat
# ============================================================================

@mcp.tool()
def npc_equip(
    armor: str | None = None,
    gun: str | None = None,
    ammo: str | None = None,
    ammo_count: int = 10,
) -> dict:
    """Set Botty's armor/gun/ammo. Pass "" to clear a slot."""
    opts: dict[str, Any] = {}
    if armor is not None:
        opts["armor"] = armor or None
    if gun is not None:
        opts["gun"] = gun or None
    if ammo:
        opts["ammo"] = ammo
        opts["ammo_count"] = ammo_count
    return _call("equip", opts)


@mcp.tool()
def npc_shoot_at(x: float, y: float) -> dict:
    """Shoot toward (x, y) (continuous until `npc_stop`)."""
    return _call("shoot_at", x, y)


# ============================================================================
# Chat / cheats
# ============================================================================

@mcp.tool()
def npc_say(text: str) -> dict:
    """Print a chat line as Botty."""
    return _call("say", text)


@mcp.tool()
def npc_give(item: str, count: int = 1, quality: str | None = None) -> dict:
    """Dev helper: insert items directly. Requires human approval."""
    if quality:
        return _call("give", item, count, quality)
    return _call("give", item, count)


# ============================================================================
# Prompts
# ============================================================================

@mcp.prompt()
def factorio_briefing() -> str:
    """Operator briefing + loop for Claude when driving Botty headlessly."""
    return _BRIEFING


@mcp.prompt()
def help_prompt() -> str:
    """Shorter quick-reference; see `factorio_briefing` for the full playbook."""
    return (
        "You control Botty, a detached character in a HEADLESS Factorio server. "
        "No human player is connected. Default perception: npc_observe(radius=16). "
        "Default loop: drain_events -> observe -> propose -> confirm -> act -> wait -> report. "
        "Run `factorio_briefing` for the full playbook."
    )


if __name__ == "__main__":
    mcp.run()
