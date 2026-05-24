"""HTTP wrapper around Factorio's RCON, so the MCP server never holds the
RCON password directly. Single endpoint, X-API-Key auth.

Run with:
    uvicorn backend.rcon_server:app --host 127.0.0.1 --port 8000
"""

from __future__ import annotations

import os

from dotenv import load_dotenv
from fastapi import Depends, FastAPI, HTTPException, Security
from fastapi.security.api_key import APIKeyHeader
from mcrcon import MCRcon
from pydantic import BaseModel

load_dotenv()

RCON_HOST = os.getenv("RCON_HOST", "127.0.0.1")
RCON_PORT = int(os.getenv("RCON_PORT", "27015"))
RCON_PASSWORD = os.getenv("RCON_PASSWORD", "")
API_KEY = os.getenv("API_KEY", "")

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
