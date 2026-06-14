#!/usr/bin/env python3
"""
Hermes Agent Railway SaaS — Web Dashboard & Gateway Manager
===========================================================

A production-ready Starlette + uvicorn server that provides:
  - BasicAuth-protected web dashboard for managing a Hermes Agent instance
  - Gateway subprocess lifecycle management (start/stop/restart)
  - Environment-based configuration management
  - Ring-buffered gateway log viewer
  - Memory/storage statistics
  - Multi-IM pairing link management
  - Default agent auto-configuration from environment variables

Designed for single-user per-instance Railway deployments.
"""

from __future__ import annotations

import asyncio
import base64
import hashlib
import json
import os
import secrets
import signal
import subprocess
import sys
import time
import uuid
from collections import deque
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

from jinja2 import Environment, FileSystemLoader
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import HTMLResponse, JSONResponse, Response, StreamingResponse
from starlette.routing import Route

from openai import AsyncOpenAI

# ============================================================================
# Constants
# ============================================================================

HERMES_HOME = Path(os.environ.get("HERMES_HOME", "/data/.hermes"))
DATA_ROOT = Path(os.environ.get("HOME", "/data"))
CONFIG_DIR = HERMES_HOME / "config"
SESSIONS_DIR = HERMES_HOME / "sessions"
SKILLS_DIR = HERMES_HOME / "skills"
WORKSPACE_DIR = HERMES_HOME / "workspace"
PAIRING_DIR = HERMES_HOME / "pairing"
LOGS_DIR = HERMES_HOME / "logs"
DEFAULT_AGENT_CONFIG = CONFIG_DIR / "default_agent.json"
ENV_FILE = DATA_ROOT / ".env"
PAIRING_FILE = PAIRING_DIR / "pairings.json"

ADMIN_USERNAME = os.environ.get("ADMIN_USERNAME", "admin")
ADMIN_PASSWORD = os.environ.get("ADMIN_PASSWORD", "admin")
PORT = int(os.environ.get("PORT", "8080"))
GATEWAY_AUTO_START = os.environ.get("GATEWAY_AUTO_START", "true").lower() == "true"
LOG_BUFFER_SIZE = int(os.environ.get("GATEWAY_LOG_BUFFER_SIZE", "2000"))
PAIRING_LINK_TTL = int(os.environ.get("PAIRING_LINK_TTL", "86400"))

ALLOWED_ENV_KEYS = {
    "OPENROUTER_API_KEY", "OPENAI_API_KEY", "ANTHROPIC_API_KEY",
    "DEEPSEEK_API_KEY", "GOOGLE_API_KEY", "GROQ_API_KEY",
    "XAI_API_KEY", "TOGETHER_API_KEY", "MISTRAL_API_KEY",
    "COHERE_API_KEY", "PERPLEXITY_API_KEY",
    "TELEGRAM_BOT_TOKEN", "SLACK_BOT_TOKEN", "SLACK_APP_TOKEN",
    "SLACK_SIGNING_SECRET", "DISCORD_BOT_TOKEN", "DISCORD_CLIENT_ID",
    "DISCORD_CLIENT_SECRET", "WHATSAPP_TOKEN", "WHATSAPP_PHONE_NUMBER_ID",
    "WHATSAPP_BUSINESS_ACCOUNT_ID", "MSTEAMS_CLIENT_ID",
    "MSTEAMS_CLIENT_SECRET", "MSTEAMS_TENANT_ID",
    "GOOGLE_CHAT_PROJECT_ID", "MATRIX_HOMESERVER",
    "MATRIX_USERNAME", "MATRIX_ACCESS_TOKEN",
    "TWITTER_USERNAME", "TWITTER_PASSWORD", "TWITTER_EMAIL",
    "TWITTER_API_KEY", "TWITTER_API_SECRET",
    "TWITTER_ACCESS_TOKEN", "TWITTER_ACCESS_SECRET",
    "HERMES_DEFAULT_AGENT_NAME", "HERMES_DEFAULT_AGENT_SYSTEM_PROMPT",
    "HERMES_DEFAULT_AGENT_MODEL", "HERMES_DEFAULT_AGENT_TOOLS",
    "GATEWAY_LOG_BUFFER_SIZE", "PAIRING_LINK_TTL",
    "GATEWAY_AUTO_START",
}

PROVIDER_KEY_PREFIXES = [
    "OPENROUTER_API_KEY", "OPENAI_API_KEY", "ANTHROPIC_API_KEY",
    "DEEPSEEK_API_KEY", "GOOGLE_API_KEY", "GROQ_API_KEY",
    "XAI_API_KEY", "TOGETHER_API_KEY", "MISTRAL_API_KEY",
    "COHERE_API_KEY", "PERPLEXITY_API_KEY",
]

CHANNEL_KEY_PREFIXES = [
    "TELEGRAM_BOT_TOKEN", "SLACK_BOT_TOKEN", "DISCORD_BOT_TOKEN",
    "WHATSAPP_TOKEN", "MSTEAMS_CLIENT_ID", "GOOGLE_CHAT_PROJECT_ID",
    "MATRIX_HOMESERVER", "TWITTER_USERNAME",
]

# ============================================================================
# Ring Log Buffer
# ============================================================================


class RingLogBuffer:
    """Thread-safe fixed-size ring buffer for gateway log lines."""

    def __init__(self, capacity: int = 2000):
        self._buffer: deque[dict[str, Any]] = deque(maxlen=capacity)
        self._lock = asyncio.Lock()

    async def append(self, line: str, stream: str = "stdout") -> None:
        async with self._lock:
            self._buffer.append({
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "stream": stream,
                "text": line.rstrip("\n"),
            })

    async def get(self, limit: int = 200, since: int = 0) -> list[dict[str, Any]]:
        async with self._lock:
            entries = list(self._buffer)
        if since > 0:
            entries = entries[since:]
        if limit > 0:
            entries = entries[-limit:]
        return entries

    async def clear(self) -> None:
        async with self._lock:
            self._buffer.clear()

    async def count(self) -> int:
        async with self._lock:
            return len(self._buffer)


# ============================================================================
# Gateway Manager
# ============================================================================


class GatewayManager:
    """Manages the lifecycle of a 'hermes gateway' subprocess.

    Handles:
      - Starting the gateway subprocess with configured environment
      - Capturing stdout/stderr into a ring buffer
      - Graceful shutdown via SIGTERM with SIGKILL fallback
      - Status reporting (running, uptime, PID)
    """

    def __init__(self, log_buffer: RingLogBuffer):
        self._process: Optional[asyncio.subprocess.Process] = None
        self._log = log_buffer
        self._started_at: Optional[float] = None
        self._lock = asyncio.Lock()

    @property
    def running(self) -> bool:
        return self._process is not None and self._process.returncode is None

    @property
    def pid(self) -> Optional[int]:
        return self._process.pid if self._process else None

    @property
    def started_at(self) -> Optional[float]:
        return self._started_at

    @property
    def uptime_seconds(self) -> Optional[float]:
        if self._started_at is None:
            return None
        return time.monotonic() - self._started_at

    async def start(self) -> dict[str, Any]:
        """Start the gateway subprocess. Returns status info."""
        async with self._lock:
            if self.running:
                return {"started": False, "reason": "already_running",
                        "pid": self.pid, "uptime": self.uptime_seconds}

            await self._log.append("Starting Hermes gateway ...", "system")

            try:
                # Build environment: inherit current process env
                env = os.environ.copy()
                env["HERMES_HOME"] = str(HERMES_HOME)
                env["HOME"] = str(DATA_ROOT)

                self._process = await asyncio.create_subprocess_exec(
                    "hermes", "gateway",
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE,
                    env=env,
                    cwd=str(DATA_ROOT),
                )
                self._started_at = time.monotonic()

                # Launch log reader tasks
                asyncio.ensure_future(self._read_stream(
                    self._process.stdout, "stdout"))
                asyncio.ensure_future(self._read_stream(
                    self._process.stderr, "stderr"))
                # Monitor process exit
                asyncio.ensure_future(self._monitor_exit())

                await self._log.append(
                    f"Gateway started (PID: {self._process.pid})", "system")
                return {"started": True, "pid": self._process.pid}

            except FileNotFoundError:
                await self._log.append(
                    "ERROR: 'hermes' command not found. Is hermes-agent installed?",
                    "system")
                self._process = None
                self._started_at = None
                return {"started": False, "reason": "hermes_not_found"}
            except Exception as exc:
                await self._log.append(
                    f"ERROR: Failed to start gateway: {exc}", "system")
                self._process = None
                self._started_at = None
                return {"started": False, "reason": str(exc)}

    async def stop(self) -> dict[str, Any]:
        """Gracefully stop the gateway subprocess."""
        async with self._lock:
            if not self.running:
                return {"stopped": False, "reason": "not_running"}

            pid = self._process.pid
            await self._log.append(
                f"Stopping gateway (PID: {pid}) ...", "system")

            try:
                self._process.send_signal(signal.SIGTERM)
                try:
                    await asyncio.wait_for(self._process.wait(), timeout=15.0)
                except asyncio.TimeoutError:
                    await self._log.append(
                        "Gateway did not stop, sending SIGKILL ...", "system")
                    self._process.kill()
                    await self._process.wait()

                await self._log.append(
                    f"Gateway stopped (was PID: {pid})", "system")
            except ProcessLookupError:
                pass  # Already exited

            self._process = None
            self._started_at = None
            return {"stopped": True, "pid": pid}

    async def restart(self) -> dict[str, Any]:
        """Restart the gateway subprocess."""
        stop_result = await self.stop()
        start_result = await self.start()
        return {"stopped": stop_result, "started": start_result}

    async def _read_stream(self, stream, stream_name: str) -> None:
        """Read lines from a subprocess stream into the log buffer."""
        try:
            while True:
                line = await stream.readline()
                if not line:
                    break
                await self._log.append(line.decode("utf-8", errors="replace"),
                                       stream_name)
        except (asyncio.CancelledError, ValueError):
            pass
        except Exception as exc:
            await self._log.append(
                f"Stream reader error ({stream_name}): {exc}", "system")

    async def _monitor_exit(self) -> None:
        """Monitor the subprocess for unexpected exit."""
        if self._process is None:
            return
        try:
            exit_code = await self._process.wait()
            await self._log.append(
                f"Gateway exited with code {exit_code}", "system")
        except Exception:
            pass
        finally:
            self._process = None
            self._started_at = None

    def has_provider_config(self) -> bool:
        """Check if any LLM provider key is configured."""
        for key in PROVIDER_KEY_PREFIXES:
            if os.environ.get(key):
                return True
        return False


# ============================================================================
# Auth
# ============================================================================


def _auth_header_value() -> str:
    return "Basic " + base64.b64encode(
        f"{ADMIN_USERNAME}:{ADMIN_PASSWORD}".encode()
    ).decode()


def require_auth(request: Request) -> bool:
    """Return True if the request is authenticated."""
    expected = _auth_header_value()
    actual = request.headers.get("authorization", "")
    return actual == expected


async def auth_endpoint(request: Request) -> Response:
    """Auth wrapper — if authenticated, call the handler."""
    if request.url.path == "/health":
        return await health(request)
    if not require_auth(request):
        return Response(
            status_code=401,
            headers={"WWW-Authenticate": "Basic realm=\"Hermes\""},
            content="Unauthorized\n",
        )
    return None  # Let routing continue


# ============================================================================
# Config Helpers
# ============================================================================


def _read_env_file() -> dict[str, str]:
    """Read environment variables from the .env file."""
    result: dict[str, str] = {}
    if ENV_FILE.exists():
        try:
            for line in ENV_FILE.read_text().splitlines():
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                key = key.strip()
                value = value.strip().strip('"').strip("'")
                if key:
                    result[key] = value
        except Exception:
            pass
    return result


def _write_env_file(data: dict[str, str]) -> None:
    """Write environment variables to the .env file, merging with existing."""
    existing = _read_env_file()
    existing.update(data)
    ENV_FILE.parent.mkdir(parents=True, exist_ok=True)
    lines = [f"{k}={v}" for k, v in sorted(existing.items()) if v]
    ENV_FILE.write_text("\n".join(lines) + "\n")


def _redact(value: str) -> str:
    """Redact a secret value for display."""
    if not value:
        return ""
    if len(value) <= 8:
        return value[:2] + "***"
    return value[:4] + "***" + value[-4:]


def _redact_config(config: dict[str, str]) -> dict[str, str]:
    """Redact secret values in a config dictionary."""
    secret_suffixes = (
        "_API_KEY", "_BOT_TOKEN", "_CLIENT_SECRET", "_SIGNING_SECRET",
        "_ACCESS_TOKEN", "_PASSWORD", "_APP_TOKEN", "_TOKEN",
    )
    result = {}
    for k, v in config.items():
        if any(k.endswith(s) for s in secret_suffixes):
            result[k] = _redact(v)
        else:
            result[k] = v
    return result


def _get_default_agent_config() -> dict[str, Any]:
    """Read the default agent config from disk."""
    if DEFAULT_AGENT_CONFIG.exists():
        try:
            return json.loads(DEFAULT_AGENT_CONFIG.read_text())
        except json.JSONDecodeError:
            pass
    return {
        "name": os.environ.get("HERMES_DEFAULT_AGENT_NAME", "Hermes Assistant"),
        "model": os.environ.get("HERMES_DEFAULT_AGENT_MODEL", ""),
        "system_prompt": os.environ.get(
            "HERMES_DEFAULT_AGENT_SYSTEM_PROMPT", ""),
        "tools": [],
    }


# ============================================================================
# Pairing CRUD Helpers
# ============================================================================


def _load_pairings() -> list[dict[str, Any]]:
    """Load pairing records from disk."""
    if PAIRING_FILE.exists():
        try:
            return json.loads(PAIRING_FILE.read_text())
        except json.JSONDecodeError:
            pass
    return []


def _save_pairings(pairings: list[dict[str, Any]]) -> None:
    """Save pairing records to disk."""
    PAIRING_DIR.mkdir(parents=True, exist_ok=True)
    PAIRING_FILE.write_text(json.dumps(pairings, indent=2))


# ============================================================================
# Route Handlers
# ============================================================================


async def health(request: Request) -> JSONResponse:
    """Health check endpoint — no auth required."""
    return JSONResponse({
        "status": "ok",
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "version": "1.0.0",
    })


async def dashboard(request: Request) -> HTMLResponse:
    """Serve the web dashboard."""
    if not require_auth(request):
        return Response(
            status_code=401,
            headers={"WWW-Authenticate": "Basic realm=\"Hermes\""},
        )
    templates = Environment(
        loader=FileSystemLoader("/app/templates"),
        autoescape=True,
    )
    template = templates.get_template("index.html")
    return HTMLResponse(template.render())


async def get_config(request: Request) -> JSONResponse:
    """Get current configuration (keys redacted)."""
    config = _read_env_file()
    # Also include current process environment for keys not in .env file
    for key in ALLOWED_ENV_KEYS:
        if key not in config and os.environ.get(key):
            config[key] = os.environ[key]
    redacted = _redact_config(config)
    return JSONResponse({"config": redacted, "count": len(redacted)})


async def update_config(request: Request) -> JSONResponse:
    """Update a single configuration value."""
    try:
        body = await request.json()
        key = body.get("key", "").strip()
        value = body.get("value", "").strip()
        if not key:
            return JSONResponse({"error": "key is required"}, status_code=400)
        if key not in ALLOWED_ENV_KEYS:
            return JSONResponse(
                {"error": f"key '{key}' is not allowed"}, status_code=400)

        # Set in current process
        os.environ[key] = value
        # Persist to .env file
        _write_env_file({key: value})

        return JSONResponse({
            "updated": True,
            "key": key,
            "value": _redact(value) if any(
                key.endswith(s) for s in (
                    "_API_KEY", "_BOT_TOKEN", "_CLIENT_SECRET", "_TOKEN",
                    "_PASSWORD", "_APP_TOKEN", "_SIGNING_SECRET",
                )
            ) else value,
        })
    except json.JSONDecodeError:
        return JSONResponse({"error": "invalid JSON"}, status_code=400)


async def bulk_config(request: Request) -> JSONResponse:
    """Bulk-update multiple configuration values at once.

    Accepts a JSON object of key-value pairs. This endpoint is designed
    for Railway API injection — a single POST sets all user config.
    """
    try:
        body = await request.json()
        if not isinstance(body, dict):
            return JSONResponse(
                {"error": "expected JSON object"}, status_code=400)

        updated: list[str] = []
        rejected: list[str] = []
        write_data: dict[str, str] = {}

        for key, value in body.items():
            key = str(key).strip()
            value = str(value).strip() if value is not None else ""

            if not key:
                continue
            if key not in ALLOWED_ENV_KEYS:
                rejected.append(key)
                continue

            os.environ[key] = value
            write_data[key] = value
            updated.append(key)

        if write_data:
            _write_env_file(write_data)

        return JSONResponse({
            "updated": updated,
            "rejected": rejected,
            "count": len(updated),
        })
    except json.JSONDecodeError:
        return JSONResponse({"error": "invalid JSON"}, status_code=400)


async def get_status(request: Request) -> JSONResponse:
    """Get gateway and configuration status."""
    providers = {}
    for key in PROVIDER_KEY_PREFIXES:
        val = os.environ.get(key)
        providers[key.replace("_API_KEY", "")] = {
            "configured": bool(val),
            "redacted": _redact(val) if val else None,
        }

    channels = {}
    for key in CHANNEL_KEY_PREFIXES:
        val = os.environ.get(key)
        channels[key] = {
            "configured": bool(val),
            "redacted": _redact(val) if val else None,
        }

    default_agent = _get_default_agent_config()

    return JSONResponse({
        "gateway": {
            "running": app.state.gateway.running,
            "pid": app.state.gateway.pid,
            "uptime_seconds": (
                app.state.gateway.uptime_seconds
                if app.state.gateway.running else None
            ),
            "auto_start": GATEWAY_AUTO_START,
        },
        "providers": providers,
        "channels": channels,
        "default_agent": {
            "name": default_agent.get("name"),
            "model": default_agent.get("model"),
            "configured": bool(default_agent.get("system_prompt")),
        },
        "log_count": await app.state.logs.count(),
    })


async def get_logs(request: Request) -> JSONResponse:
    """Get gateway logs from the ring buffer.

    Query params: limit (default 200), since (timestamp offset)
    """
    try:
        limit = int(request.query_params.get("limit", "200"))
        since = int(request.query_params.get("since", "0"))
    except ValueError:
        limit, since = 200, 0

    limit = max(1, min(limit, 2000))
    since = max(0, since)

    entries = await app.state.logs.get(limit=limit, since=since)
    return JSONResponse({
        "entries": entries,
        "count": len(entries),
        "total": await app.state.logs.count(),
    })


async def gateway_start(request: Request) -> JSONResponse:
    """Start the gateway subprocess."""
    result = await app.state.gateway.start()
    status_code = 200 if result.get("started") else 409
    return JSONResponse(result, status_code=status_code)


async def gateway_stop(request: Request) -> JSONResponse:
    """Stop the gateway subprocess."""
    result = await app.state.gateway.stop()
    status_code = 200 if result.get("stopped") else 409
    return JSONResponse(result, status_code=status_code)


async def gateway_restart(request: Request) -> JSONResponse:
    """Restart the gateway subprocess."""
    result = await app.state.gateway.restart()
    return JSONResponse(result)


async def get_memory(request: Request) -> JSONResponse:
    """Get memory/storage statistics."""
    def dir_size(path: Path) -> int:
        if not path.exists():
            return 0
        total = 0
        for f in path.rglob("*"):
            if f.is_file():
                try:
                    total += f.stat().st_size
                except OSError:
                    pass
        return total

    def file_count(path: Path) -> int:
        if not path.exists():
            return 0
        return sum(1 for f in path.rglob("*") if f.is_file())

    skills_count = file_count(SKILLS_DIR)
    sessions_count = file_count(SESSIONS_DIR)
    pairing_count = file_count(PAIRING_DIR)

    skills_size = dir_size(SKILLS_DIR)
    sessions_size = dir_size(SESSIONS_DIR)
    data_total = dir_size(HERMES_HOME)

    default_agent = _get_default_agent_config()

    return JSONResponse({
        "skills": {
            "count": skills_count,
            "size_bytes": skills_size,
        },
        "sessions": {
            "count": sessions_count,
            "size_bytes": sessions_size,
        },
        "pairings": {"count": pairing_count},
        "total_data_bytes": data_total,
        "total_data_mb": round(data_total / (1024 * 1024), 2),
        "default_agent": {
            "name": default_agent.get("name"),
            "configured": bool(default_agent.get("system_prompt")),
        },
        "directories": {
            "hermes_home": str(HERMES_HOME),
            "config": str(CONFIG_DIR),
            "sessions": str(SESSIONS_DIR),
            "skills": str(SKILLS_DIR),
            "workspace": str(WORKSPACE_DIR),
            "pairing": str(PAIRING_DIR),
        },
    })


async def list_pairings(request: Request) -> JSONResponse:
    """List all pairing records."""
    pairings = _load_pairings()
    return JSONResponse({"pairings": pairings, "count": len(pairings)})


async def create_pairing(request: Request) -> JSONResponse:
    """Create a new pairing link for an IM platform."""
    try:
        body = await request.json()
        platform = body.get("platform", "").strip().lower()
        if not platform:
            return JSONResponse(
                {"error": "platform is required"}, status_code=400)

        pairing_id = str(uuid.uuid4())[:8]
        token = secrets.token_urlsafe(32)
        created_at = datetime.now(timezone.utc).isoformat()
        expires_at = int(time.time() + PAIRING_LINK_TTL)

        record = {
            "id": pairing_id,
            "token": token,
            "platform": platform,
            "status": "pending",
            "created_at": created_at,
            "expires_at": expires_at,
            "claimed_by": None,
            "claimed_at": None,
        }

        pairings = _load_pairings()
        pairings.append(record)
        _save_pairings(pairings)

        return JSONResponse({
            "pairing": record,
            "link": f"/pair?token={token}",
        }, status_code=201)

    except json.JSONDecodeError:
        return JSONResponse({"error": "invalid JSON"}, status_code=400)


async def delete_pairing(request: Request) -> JSONResponse:
    """Delete a pairing record by ID."""
    pairing_id = request.path_params.get("pairing_id", "")
    pairings = _load_pairings()
    new_list = [p for p in pairings if p["id"] != pairing_id]
    removed = len(new_list) < len(pairings)
    _save_pairings(new_list)
    return JSONResponse({"deleted": removed})


async def clear_logs(request: Request) -> JSONResponse:
    """Clear the log buffer."""
    await app.state.logs.clear()
    return JSONResponse({"cleared": True})


async def not_found(request: Request) -> JSONResponse:
    """404 handler."""
    return JSONResponse({"error": "not found"}, status_code=404)


# ============================================================================
# OpenAI-Compatible API (/v1)
# ============================================================================

_openai_client: Optional[AsyncOpenAI] = None


def _get_openai_client() -> AsyncOpenAI:
    """Lazy-init OpenAI client from env vars (OPENAI_API_KEY + OPENAI_BASE_URL)."""
    global _openai_client
    if _openai_client is None:
        api_key = os.environ.get("OPENAI_API_KEY", "")
        base_url = os.environ.get("OPENAI_BASE_URL", "")
        if api_key:
            _openai_client = AsyncOpenAI(api_key=api_key, base_url=base_url or None)
        else:
            # No API key configured — client will fail on use, but init doesn't crash
            _openai_client = AsyncOpenAI(
                api_key="sk-placeholder", base_url=base_url or None
            )
    return _openai_client


async def list_models(request: Request) -> JSONResponse:
    """OpenAI-compatible GET /v1/models."""
    if not require_auth(request):
        return Response(
            status_code=401,
            headers={"WWW-Authenticate": 'Basic realm="Hermes"'},
        )
    model_name = os.environ.get("HERMES_DEFAULT_AGENT_MODEL", "hermes-agent")
    return JSONResponse({
        "object": "list",
        "data": [{
            "id": model_name,
            "object": "model",
            "created": 1700000000,
            "owned_by": "hermes",
        }],
    })


async def chat_completions(request: Request) -> Response:
    """OpenAI-compatible POST /v1/chat/completions (streaming + non-streaming).

    Proxies requests to the configured LLM provider using OPENAI_API_KEY
    and OPENAI_BASE_URL from environment variables.
    """
    if not require_auth(request):
        return Response(
            status_code=401,
            headers={"WWW-Authenticate": 'Basic realm="Hermes"'},
        )

    try:
        body = await request.json()
    except json.JSONDecodeError:
        return JSONResponse({"error": "invalid JSON"}, status_code=400)

    messages = body.get("messages", [])
    model = body.get(
        "model", os.environ.get("HERMES_DEFAULT_AGENT_MODEL", "hermes-agent")
    )
    stream = body.get("stream", False)
    max_tokens = body.get("max_tokens", body.get("max_completion_tokens", None))
    temperature = body.get("temperature", None)

    client = _get_openai_client()

    if stream:
        async def event_stream():
            try:
                stream_resp = await client.chat.completions.create(
                    model=model,
                    messages=messages,
                    stream=True,
                    max_tokens=max_tokens,
                    temperature=temperature,
                )
                async for chunk in stream_resp:
                    yield f"data: {chunk.model_dump_json()}\n\n"
                yield "data: [DONE]\n\n"
            except Exception as exc:
                error_chunk = json.dumps({
                    "error": {"message": str(exc), "type": "api_error"}
                })
                yield f"data: {error_chunk}\n\n"
                yield "data: [DONE]\n\n"

        return StreamingResponse(
            event_stream(),
            media_type="text/event-stream",
            headers={
                "Cache-Control": "no-cache",
                "Connection": "keep-alive",
                "X-Accel-Buffering": "no",
            },
        )
    else:
        try:
            completion = await client.chat.completions.create(
                model=model,
                messages=messages,
                max_tokens=max_tokens,
                temperature=temperature,
            )
            return JSONResponse(completion.model_dump())
        except Exception as exc:
            return JSONResponse(
                {"error": {"message": str(exc), "type": "api_error"}},
                status_code=500,
            )


# ============================================================================
# App Factory
# ============================================================================


routes = [
    Route("/", dashboard, methods=["GET"]),
    Route("/health", health, methods=["GET"]),
    Route("/api/config", get_config, methods=["GET"]),
    Route("/api/config", update_config, methods=["PUT"]),
    Route("/api/config/bulk", bulk_config, methods=["POST"]),
    Route("/api/status", get_status, methods=["GET"]),
    Route("/api/logs", get_logs, methods=["GET"]),
    Route("/api/logs/clear", clear_logs, methods=["POST"]),
    Route("/api/gateway/start", gateway_start, methods=["POST"]),
    Route("/api/gateway/stop", gateway_stop, methods=["POST"]),
    Route("/api/gateway/restart", gateway_restart, methods=["POST"]),
    Route("/api/memory", get_memory, methods=["GET"]),
    Route("/api/pairings", list_pairings, methods=["GET"]),
    Route("/api/pairings", create_pairing, methods=["POST"]),
    Route("/api/pairings/{pairing_id}", delete_pairing, methods=["DELETE"]),
    Route("/v1/models", list_models, methods=["GET"]),
    Route("/v1/chat/completions", chat_completions, methods=["POST"]),
    Route("/{path:path}", not_found, methods=["GET", "POST", "PUT", "DELETE"]),
]

app = Starlette(routes=routes)


# ============================================================================
# Startup / Shutdown
# ============================================================================


@app.on_event("startup")
async def on_startup():
    """Initialize on server start."""
    # Create required directories
    for d in [CONFIG_DIR, SESSIONS_DIR, SKILLS_DIR, WORKSPACE_DIR,
              PAIRING_DIR, LOGS_DIR]:
        d.mkdir(parents=True, exist_ok=True)

    # Initialize log buffer and gateway manager
    app.state.logs = RingLogBuffer(capacity=LOG_BUFFER_SIZE)
    app.state.gateway = GatewayManager(app.state.logs)

    await app.state.logs.append("Hermes SaaS server started", "system")
    await app.state.logs.append(
        f"HERMES_HOME={HERMES_HOME}", "system")

    # Auto-start gateway if configured
    if GATEWAY_AUTO_START and app.state.gateway.has_provider_config():
        await app.state.logs.append(
            "Auto-starting gateway (provider keys detected) ...", "system")
        result = await app.state.gateway.start()
        if result.get("started"):
            await app.state.logs.append(
                f"Gateway auto-started (PID: {result['pid']})", "system")
        else:
            await app.state.logs.append(
                f"Gateway auto-start failed: {result.get('reason')}", "system")
    else:
        await app.state.logs.append(
            "Gateway auto-start skipped (no provider keys or disabled)", "system")

    # Load default agent config
    agent = _get_default_agent_config()
    if agent.get("system_prompt"):
        await app.state.logs.append(
            f"Default agent configured: {agent.get('name', 'unnamed')}", "system")

    print(f"[server] Hermes SaaS running on port {PORT}", file=sys.stderr)


@app.on_event("shutdown")
async def on_shutdown():
    """Graceful shutdown — stop the gateway subprocess."""
    await app.state.logs.append(
        "Server shutting down, stopping gateway ...", "system")
    try:
        await app.state.gateway.stop()
    except Exception as exc:
        await app.state.logs.append(
            f"Gateway stop error during shutdown: {exc}", "system")
    await app.state.logs.append("Server stopped.", "system")
    print("[server] Hermes SaaS shut down gracefully", file=sys.stderr)


# ============================================================================
# Signal Handling (for local dev; Railway sends SIGTERM)
# ============================================================================


def _handle_signal(sig, frame):
    """Forward signals for graceful shutdown."""
    import asyncio as _asyncio
    try:
        loop = _asyncio.get_event_loop()
        loop.call_soon_threadsafe(loop.stop)
    except Exception:
        pass


signal.signal(signal.SIGTERM, _handle_signal)
signal.signal(signal.SIGINT, _handle_signal)


# ============================================================================
# Main
# ============================================================================

if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "server:app",
        host="0.0.0.0",
        port=PORT,
        log_level="info",
        access_log=True,
        timeout_keep_alive=65,
    )
