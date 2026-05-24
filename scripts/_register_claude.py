"""Merge a factorio-npc MCP server entry into Claude Desktop's config.

Called by scripts/register-claude.ps1. Kept as a standalone script so the
JSON parser/serializer is Python's (which Claude Desktop tolerates) rather
than PowerShell 5.1's ConvertTo-Json (which Claude Desktop does not).

Usage:
    python scripts/_register_claude.py <config_path> <server_name> <python_exe>
                                       <mcp_script> <api_key> <backend_url>
                                       [--force]
"""

from __future__ import annotations

import json
import shutil
import sys
from datetime import datetime
from pathlib import Path


def main(argv: list[str]) -> int:
    force = "--force" in argv
    args = [a for a in argv if a != "--force"]
    if len(args) != 7:
        print(__doc__, file=sys.stderr)
        return 2

    _, config_path, server_name, python_exe, mcp_script, api_key, backend_url = args
    cfg_path = Path(config_path)

    if not cfg_path.is_file():
        print(f"ERROR: config not found: {cfg_path}", file=sys.stderr)
        return 1

    text = cfg_path.read_text(encoding="utf-8-sig")  # tolerate BOM
    try:
        config = json.loads(text)
    except json.JSONDecodeError as exc:
        print(f"ERROR: existing config is not valid JSON: {exc}", file=sys.stderr)
        return 1

    servers = config.setdefault("mcpServers", {})
    if server_name in servers and not force:
        print(f"server '{server_name}' already present; pass --force to overwrite")
        return 0

    backup = cfg_path.with_name(
        cfg_path.name + ".bak-" + datetime.now().strftime("%Y%m%d-%H%M%S")
    )
    shutil.copy2(cfg_path, backup)
    print(f"backup: {backup}")

    servers[server_name] = {
        "command": python_exe,
        "args": [mcp_script],
        "env": {
            "API_KEY": api_key,
            "BACKEND_URL": backend_url,
        },
    }

    # Write with the same conventions Claude Desktop uses: 2-space indent,
    # UTF-8 *without* BOM, LF line endings, no \uXXXX escaping of forward
    # slashes or non-ASCII identifiers.
    out = json.dumps(config, indent=2, ensure_ascii=False)
    cfg_path.write_text(out + "\n", encoding="utf-8", newline="\n")
    print(f"wrote {cfg_path}")
    print(f"  command: {python_exe}")
    print(f"  script : {mcp_script}")
    print(f"  backend: {backend_url}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
