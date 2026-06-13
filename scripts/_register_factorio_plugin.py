"""Register the factorio-npc plugin in the local Claude Code marketplace registry."""
import json
import os
import shutil
import time
from pathlib import Path

home = Path(os.path.expanduser("~"))
marketplace = home / ".claude" / "plugins" / "marketplaces" / "claude-plugins-official" / ".claude-plugin" / "marketplace.json"

# Backup
bak = marketplace.with_suffix(f".json.bak-{time.strftime('%Y%m%d-%H%M%S')}")
shutil.copy(marketplace, bak)
print("backup:", bak)

with marketplace.open("r", encoding="utf-8") as f:
    data = json.load(f)

names = [p["name"] for p in data["plugins"]]
entry = {
    "name": "factorio-npc",
    "description": "Factorio NPC operator skill for the factorio-npc MCP server. Use when the user asks to play Factorio, run a Botty/NPC turn, build a factory, mine ore, place drills/belts/inserters, or call any npc_* tool. Provides the per-turn loop, smart placement helpers, tile-exact layout schema notation, and verified burner-tier primitives.",
    "author": {"name": "coles"},
    "category": "gaming",
    "source": "./plugins/factorio-npc",
}

if "factorio-npc" in names:
    # replace existing
    for i, p in enumerate(data["plugins"]):
        if p["name"] == "factorio-npc":
            data["plugins"][i] = entry
            print("replaced existing entry at index", i)
            break
else:
    data["plugins"].append(entry)
    print("appended new entry, new count:", len(data["plugins"]))

with marketplace.open("w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)

print("done. factorio-npc registered.")
