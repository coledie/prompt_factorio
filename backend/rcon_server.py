"""HTTP wrapper around Factorio's RCON, so the MCP server never holds the
RCON password directly. Two endpoints:

  POST /execute_command     — pipe raw Lua / RCON through to Factorio.
  GET  /screenshot/{name}   — serve PNGs the mod wrote to script-output/botty/.

Run with:
    uvicorn backend.rcon_server:app --host 127.0.0.1 --port 8000
"""

from __future__ import annotations

import os
from pathlib import Path

from dotenv import load_dotenv
from fastapi import Depends, FastAPI, HTTPException, Security
from fastapi.responses import FileResponse
from fastapi.security.api_key import APIKeyHeader
from mcrcon import MCRcon
from pydantic import BaseModel

load_dotenv()

RCON_HOST = os.getenv("RCON_HOST", "127.0.0.1")
RCON_PORT = int(os.getenv("RCON_PORT", "27015"))
RCON_PASSWORD = os.getenv("RCON_PASSWORD", "")
API_KEY = os.getenv("API_KEY", "")

# Where Factorio's `game.take_screenshot{path="botty/foo.png"}` lands.
# This is <write-data>/script-output/, which start-factorio-server.ps1
# points at .factorio-server/ relative to the repo root.
REPO_ROOT = Path(__file__).resolve().parents[1]
SCREENSHOT_DIR = REPO_ROOT / ".factorio-server" / "script-output" / "botty"

if not RCON_PASSWORD:
    raise SystemExit("RCON_PASSWORD env var is required")
if not API_KEY:
    raise SystemExit("API_KEY env var is required")

app = FastAPI(title="factorio_npc_mcp backend")
_api_key_header = APIKeyHeader(name="X-API-Key")


async def _require_api_key(api_key: str = Security(_api_key_header)) -> str:
    if api_key != API_KEY:
        raise HTTPException(status_code=403, detail="invalid API key")
    return api_key


class CommandRequest(BaseModel):
    command: str


@app.get("/")
def root() -> dict:
    return {"ok": True, "service": "factorio_npc_mcp backend"}


@app.post("/execute_command")
def execute_command(req: CommandRequest, _: str = Depends(_require_api_key)) -> dict:
    try:
        with MCRcon(RCON_HOST, RCON_PASSWORD, port=RCON_PORT) as mcr:
            response = mcr.command(req.command)
        return {"result": response}
    except Exception as exc:  # noqa: BLE001 - surface details to the caller
        raise HTTPException(status_code=500, detail=f"rcon error: {exc}") from exc


@app.get("/screenshot/{name}")
def screenshot(name: str) -> FileResponse:
    # Strict path containment: only serve files directly under SCREENSHOT_DIR.
    safe = SCREENSHOT_DIR / name
    try:
        safe = safe.resolve(strict=True)
    except FileNotFoundError:
        raise HTTPException(status_code=404, detail="screenshot not found")
    if SCREENSHOT_DIR.resolve() not in safe.parents:
        raise HTTPException(status_code=400, detail="path traversal blocked")
    return FileResponse(safe, media_type="image/png")
