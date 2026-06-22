# Documentation index

Reference and design docs for `factorio_npc_mcp`. Start with the
top-level [README.md](../README.md) for the project overview and
architecture diagram, and [SETUP.md](../SETUP.md) for bring-up.

## Live reference (read these to operate the NPC)

| Doc | What it covers |
|-----|----------------|
| [ARCHITECTURE.md](ARCHITECTURE.md) | The LLM → MCP → backend → RCON → mod chain, the layer-by-layer breakdown, and how the NPC stays isolated from your own player. |
| [FACTORY_SCHEMA.md](FACTORY_SCHEMA.md) | Tile-exact layout notation (glyphs for ore/drills/belts/inserters), placement validity rules, drill drop-tile table, inserter pickup/drop geometry, entity footprints. The agent's planning reference. Served to Claude Desktop on demand via the `npc_schema` tool / `factorio_schema` prompt. |
| [MULTI_NPC.md](MULTI_NPC.md) | Multi-agent architecture: one server + one backend + one MCP process per agent window, each NPC keyed by name. How a session binds an NPC name. |
| [SAVES.md](SAVES.md) | Save-file lifecycle: default/auto/named saves, launch rules, quarantine folders, recovery procedures. |

## Design / history (record of decisions; not operating instructions)

| Doc | What it covers |
|-----|----------------|
| [PERCEPTION_PLAN.md](PERCEPTION_PLAN.md) | Root-cause analysis of early perception failures and the fix plan. Phase 1–2 (`npc_find`, `npc_text_map`) have shipped. |
| [../mod/npc_mcp/PLAN.md](../mod/npc_mcp/PLAN.md) | Implementation plan for the Factorio-side mod (state, on_tick dispatcher, remote interface). |

## The operator skill (single source of truth)

The Factorio operator playbook lives in **`CLAUDE.md`** at the repo root.
The same content is mirrored to three other discovery locations
(`AGENTS.md`, `.claude/skills/factorio-npc/SKILL.md`, and the
`.claude-plugin/.../SKILL.md`) so different agent runtimes can find it,
and is loaded by the MCP server at startup for its `instructions` field.

Edit `CLAUDE.md` only, then run
[`scripts/sync-skill.ps1`](../scripts/sync-skill.ps1) to mirror it.
Run `scripts/sync-skill.ps1 -Check` to verify the copies are in sync.
