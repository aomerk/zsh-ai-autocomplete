#!/usr/bin/env python3
"""
daemon.py — asyncio Unix socket server for ZSH AI command finder.

Receives a natural-language query, retrieves relevant history via FTS5,
streams llama.cpp completions, and emits complete command lines to the
client one-by-one as they are generated.
"""

import asyncio
import http.client
import json
import logging
import os
import signal
import sqlite3
import threading
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Callable

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
DATA_DIR = Path.home() / ".local/share/zsh-ai-autocomplete"
SOCK_PATH = DATA_DIR / "daemon.sock"
PID_PATH  = DATA_DIR / "daemon.pid"
LOG_PATH  = DATA_DIR / "daemon.log"
DB_PATH   = DATA_DIR / "history.db"

LLAMA_HOST = "127.0.0.1"
LLAMA_PORT = 8080

# CPU inference on a 1.5B Q4 model: ~11 tok/s.
# Give each command line up to 30s before giving up.
LLM_TIMEOUT = 30.0

# ---------------------------------------------------------------------------
# Backend config  (read once at startup from environment)
# ---------------------------------------------------------------------------
# ZAI_BACKEND=local (default) — uses local llama-server
# ZAI_BACKEND=anthropic      — uses Anthropic API (requires ANTHROPIC_API_KEY)
BACKEND          = os.environ.get("ZAI_BACKEND", "local").lower()
ANTHROPIC_API_KEY = os.environ.get("ANTHROPIC_API_KEY", "")
ANTHROPIC_MODEL  = os.environ.get("ZAI_ANTHROPIC_MODEL", "claude-haiku-4-5-20251001")

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
DATA_DIR.mkdir(parents=True, exist_ok=True)
logging.basicConfig(
    filename=str(LOG_PATH),
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# FTS5 retrieval (runs in thread executor)
# ---------------------------------------------------------------------------
_db_con: sqlite3.Connection | None = None
_executor = ThreadPoolExecutor(max_workers=2)


def _get_db() -> sqlite3.Connection:
    global _db_con
    if _db_con is None:
        if not DB_PATH.exists():
            raise FileNotFoundError(f"Knowledge base not found: {DB_PATH}")
        _db_con = sqlite3.connect(str(DB_PATH), check_same_thread=False)
        _db_con.execute("PRAGMA query_only=ON")
    return _db_con


def _fts_query_sync(query: str, top_k: int = 3) -> list[str]:
    tokens = query.strip().split()
    if not tokens:
        return []
    con = _get_db()
    prefix = tokens[-1] + "*"
    prior  = tokens[:-1]
    fts_expr = " ".join(prior + [prefix]) if prior else prefix
    try:
        cur = con.execute(
            "SELECT cmd FROM commands WHERE commands MATCH ? ORDER BY rank LIMIT ?",
            (fts_expr, top_k),
        )
        rows = [r[0] for r in cur.fetchall()]
        if rows:
            return rows
    except sqlite3.OperationalError:
        pass
    escaped = query.replace("%", r"\%").replace("_", r"\_")
    try:
        cur = con.execute(
            "SELECT cmd FROM commands WHERE cmd LIKE ? ESCAPE '\\' LIMIT ?",
            (escaped + "%", top_k),
        )
        return [r[0] for r in cur.fetchall()]
    except sqlite3.OperationalError:
        return []


async def fts_query(query: str) -> list[str]:
    loop = asyncio.get_running_loop()
    return await loop.run_in_executor(_executor, _fts_query_sync, query)


# ---------------------------------------------------------------------------
# Prompt
# ---------------------------------------------------------------------------
_FEW_SHOT = """\
Request: find large files
Commands:
find . -type f -size +100M
du -ah . | sort -rh | head -20
ls -lhS | head -20
ncdu
du -sh /*

Request: kill process on port 8080
Commands:
fuser -k 8080/tcp
kill $(lsof -t -i:8080)
pkill -f ':8080'
ss -tlnp | grep 8080
lsof -i tcp:8080

Request: fetch eth price
Commands:
curl -s "https://api.binance.com/api/v3/ticker/price?symbol=ETHUSDT"
curl -s "https://api.coingecko.com/api/v3/simple/price?ids=ethereum&vs_currencies=usd"
curl -s "https://min-api.cryptocompare.com/data/price?fsym=ETH&tsyms=USD"
curl -s "https://api.kraken.com/0/public/Ticker?pair=ETHUSD"
http GET "https://api.binance.com/api/v3/ticker/price?symbol=ETHUSDT"
"""


def _build_prompt(query: str, examples: list[str]) -> str:
    ex_block = "\n".join(f"$ {e}" for e in examples)
    history = f"User history:\n{ex_block}\n\n" if ex_block else ""
    return (
        "Generate 5 different shell commands for each request. "
        "Each command must use a different tool or approach. "
        "Output only valid bash/zsh commands that run directly in a terminal. "
        "Always quote URLs and strings containing special characters (?, &, =, spaces). "
        "One command per line, no numbering, no explanations, no markdown.\n\n"
        + _FEW_SHOT
        + history
        + f"Request: {query}\nCommands:\n"
    )


# ---------------------------------------------------------------------------
# LLM streaming (runs in thread executor)
# ---------------------------------------------------------------------------
_http_conn: http.client.HTTPConnection | None = None


def _get_http() -> http.client.HTTPConnection:
    global _http_conn
    if _http_conn is None:
        _http_conn = http.client.HTTPConnection(LLAMA_HOST, LLAMA_PORT, timeout=LLM_TIMEOUT)
    return _http_conn


def _reset_http() -> None:
    global _http_conn
    try:
        if _http_conn:
            _http_conn.close()
    except Exception:
        pass
    _http_conn = None


def _clean_line(line: str) -> str | None:
    """Strip shell prompt prefix and markdown artifacts. Returns None if invalid."""
    line = line.strip().lstrip("$").strip(" `")
    if not line:
        return None
    if line.startswith("#") or line.startswith("```"):
        return None
    # Skip single-char or pure-punctuation lines
    if len(line) <= 2 and not line[0:1].isalpha():
        return None
    # Drop lines with unbalanced quotes (likely truncated)
    if line.count('"') % 2 != 0 or line.count("'") % 2 != 0:
        return None
    return line


def _llm_stream(
    prompt: str,
    emit: Callable[[str], None],
    stop: threading.Event,
) -> None:
    """Stream command lines from llama.cpp, calling emit() for each complete line.
    Runs synchronously in a thread; uses stop event for early termination."""
    payload = json.dumps({
        "prompt": prompt,
        "temperature": 0.7,
        "n_predict": 250,
        "stop": ["Request:", "Past commands:"],
        "stream": True,
        "cache_prompt": True,
    }).encode()
    headers = {
        "Content-Type": "application/json",
        "Content-Length": str(len(payload)),
    }

    buf  = ""
    seen: set[str] = set()
    count = 0

    try:
        for attempt in range(2):
            try:
                conn = _get_http()
                conn.request("POST", "/completion", body=payload, headers=headers)
                resp = conn.getresponse()
                break
            except (http.client.HTTPException, OSError) as e:
                log.warning("LLM connect attempt %d failed: %s", attempt + 1, e)
                _reset_http()
                if attempt == 1:
                    return

        while count < 5 and not stop.is_set():
            raw = resp.readline()
            if not raw:
                break
            raw = raw.decode("utf-8", errors="replace").strip()
            if not raw.startswith("data: "):
                continue
            try:
                data = json.loads(raw[6:])
            except json.JSONDecodeError:
                continue

            buf += data.get("content", "")

            # Emit each complete newline-terminated line immediately
            while "\n" in buf and count < 5:
                line, buf = buf.split("\n", 1)
                cleaned = _clean_line(line)
                if cleaned and cleaned not in seen:
                    seen.add(cleaned)
                    emit(cleaned)
                    count += 1
                    log.info("Emitted command %d: %r", count, cleaned)

            if data.get("stop"):
                break

        # Flush any remaining partial line on stop token
        if buf.strip() and count < 5 and not stop.is_set():
            cleaned = _clean_line(buf)
            if cleaned and cleaned not in seen:
                emit(cleaned)
                log.info("Emitted final command: %r", cleaned)

    except Exception as e:
        log.error("LLM stream error: %s", e)
        _reset_http()


# ---------------------------------------------------------------------------
# Anthropic backend
# ---------------------------------------------------------------------------
_anthropic_conn: http.client.HTTPSConnection | None = None


def _get_anthropic_conn() -> http.client.HTTPSConnection:
    global _anthropic_conn
    if _anthropic_conn is None:
        _anthropic_conn = http.client.HTTPSConnection(
            "api.anthropic.com", timeout=LLM_TIMEOUT
        )
    return _anthropic_conn


def _reset_anthropic_conn() -> None:
    global _anthropic_conn
    try:
        if _anthropic_conn:
            _anthropic_conn.close()
    except Exception:
        pass
    _anthropic_conn = None


def _build_anthropic_messages(query: str, examples: list[str]) -> tuple[str, list[dict]]:
    system = (
        "You generate shell commands from natural language descriptions. "
        "Output exactly 5 different commands, one per line. "
        "Each must use a different tool or approach. "
        "Valid bash/zsh only. No numbering, no explanations, no markdown. "
        "Always quote URLs and arguments containing special characters (?, &, =, spaces)."
    )
    history = "\n".join(f"$ {e}" for e in examples)
    user_content = (f"Relevant past commands for context:\n{history}\n\n" if examples else "")
    user_content += f"Request: {query}\nCommands:"
    return system, [{"role": "user", "content": user_content}]


def _llm_stream_anthropic(
    query: str,
    examples: list[str],
    emit: Callable[[str], None],
    stop: threading.Event,
) -> None:
    """Stream command lines from Anthropic API, calling emit() for each complete line."""
    system, messages = _build_anthropic_messages(query, examples)
    payload = json.dumps({
        "model": ANTHROPIC_MODEL,
        "max_tokens": 250,
        "system": system,
        "messages": messages,
        "stream": True,
    }).encode()
    headers = {
        "Content-Type": "application/json",
        "Content-Length": str(len(payload)),
        "x-api-key": ANTHROPIC_API_KEY,
        "anthropic-version": "2023-06-01",
    }

    buf  = ""
    seen: set[str] = set()
    count = 0
    input_tokens = 0
    output_tokens = 0

    try:
        for attempt in range(2):
            try:
                conn = _get_anthropic_conn()
                conn.request("POST", "/v1/messages", body=payload, headers=headers)
                resp = conn.getresponse()
                if resp.status != 200:
                    body = resp.read(512).decode(errors="replace")
                    log.error("Anthropic API error %d: %s", resp.status, body)
                    _reset_anthropic_conn()
                    return
                break
            except (http.client.HTTPException, OSError) as e:
                log.warning("Anthropic connect attempt %d failed: %s", attempt + 1, e)
                _reset_anthropic_conn()
                if attempt == 1:
                    return

        while count < 5 and not stop.is_set():
            raw = resp.readline()
            if not raw:
                break
            raw = raw.decode("utf-8", errors="replace").strip()
            if not raw.startswith("data: "):
                continue
            data_str = raw[6:]
            if data_str == "[DONE]":
                break
            try:
                data = json.loads(data_str)
            except json.JSONDecodeError:
                continue

            t = data.get("type")
            if t == "message_start":
                usage = data.get("message", {}).get("usage", {})
                input_tokens = usage.get("input_tokens", 0)
            elif t == "content_block_delta":
                delta = data.get("delta", {})
                if delta.get("type") == "text_delta":
                    buf += delta.get("text", "")
            elif t == "message_delta":
                usage = data.get("usage", {})
                output_tokens = usage.get("output_tokens", 0)
            elif t == "message_stop":
                break

            while "\n" in buf and count < 5:
                line, buf = buf.split("\n", 1)
                cleaned = _clean_line(line)
                if cleaned and cleaned not in seen:
                    seen.add(cleaned)
                    emit(cleaned)
                    count += 1
                    log.info("Emitted command %d (anthropic): %r", count, cleaned)

        # Flush any trailing partial line
        if buf.strip() and count < 5 and not stop.is_set():
            cleaned = _clean_line(buf)
            if cleaned and cleaned not in seen:
                emit(cleaned)
                log.info("Emitted final command (anthropic): %r", cleaned)

        log.info("Anthropic usage — input: %d tokens, output: %d tokens, model: %s",
                 input_tokens, output_tokens, ANTHROPIC_MODEL)

    except Exception as e:
        log.error("Anthropic stream error: %s", e)
        _reset_anthropic_conn()


# ---------------------------------------------------------------------------
# Client handler
# ---------------------------------------------------------------------------
_current_task: asyncio.Task | None = None


async def handle_client(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    global _current_task

    # Cancel any in-flight request
    if _current_task is not None and not _current_task.done():
        _current_task.cancel()
        try:
            await _current_task
        except asyncio.CancelledError:
            pass

    task = asyncio.create_task(_serve(reader, writer))
    _current_task = task
    try:
        await task
    except asyncio.CancelledError:
        pass


async def _serve(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    try:
        try:
            line = await asyncio.wait_for(reader.readline(), timeout=0.05)
        except asyncio.TimeoutError:
            log.warning("Client read timed out")
            return

        query = line.decode("utf-8", errors="replace").rstrip("\n").strip()
        if not query:
            return

        log.info("Query: %r (backend: %s)", query, BACKEND)
        examples = await fts_query(query)
        log.info("FTS5 examples: %r", examples)

        # Bridge: thread calls emit() → asyncio queue → writer
        loop = asyncio.get_running_loop()
        queue: asyncio.Queue[str | None] = asyncio.Queue()
        stop  = threading.Event()

        def emit(cmd: str) -> None:
            loop.call_soon_threadsafe(queue.put_nowait, cmd)

        if BACKEND == "anthropic" and ANTHROPIC_API_KEY:
            def produce() -> None:
                try:
                    _llm_stream_anthropic(query, examples, emit, stop)
                finally:
                    loop.call_soon_threadsafe(queue.put_nowait, None)
        else:
            prompt = _build_prompt(query, examples)
            def produce() -> None:
                try:
                    _llm_stream(prompt, emit, stop)
                finally:
                    loop.call_soon_threadsafe(queue.put_nowait, None)

        future = loop.run_in_executor(_executor, produce)

        try:
            while True:
                try:
                    item = await asyncio.wait_for(queue.get(), timeout=LLM_TIMEOUT)
                except asyncio.TimeoutError:
                    log.warning("Timed out waiting for next command from LLM")
                    break
                if item is None:
                    break
                writer.write((item + "\n").encode())
                await writer.drain()
        except asyncio.CancelledError:
            stop.set()
            raise
        finally:
            stop.set()
            try:
                writer.write_eof()
            except Exception:
                pass
            await asyncio.shield(future)

    except asyncio.CancelledError:
        raise
    except Exception as e:
        log.error("Error serving client: %s", e)
    finally:
        try:
            writer.close()
        except Exception:
            pass


# ---------------------------------------------------------------------------
# Server lifecycle
# ---------------------------------------------------------------------------
async def run_server() -> None:
    if SOCK_PATH.exists():
        SOCK_PATH.unlink()

    server = await asyncio.start_unix_server(handle_client, path=str(SOCK_PATH))
    log.info("Daemon started on %s", SOCK_PATH)

    loop = asyncio.get_running_loop()
    stop_event = asyncio.Event()

    def _shutdown(sig_name: str) -> None:
        log.info("Received %s, shutting down", sig_name)
        server.close()
        stop_event.set()

    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, _shutdown, sig.name)

    async with server:
        await stop_event.wait()


def main() -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    PID_PATH.write_text(str(os.getpid()))
    log.info("PID %d written to %s", os.getpid(), PID_PATH)
    if BACKEND == "anthropic" and not ANTHROPIC_API_KEY:
        log.error("ZAI_BACKEND=anthropic but ANTHROPIC_API_KEY is not set — falling back to local")
    elif BACKEND == "anthropic":
        log.info("Using Anthropic backend, model=%s", ANTHROPIC_MODEL)
    else:
        log.info("Using local llama-server backend at %s:%d", LLAMA_HOST, LLAMA_PORT)

    try:
        asyncio.run(run_server())
    finally:
        for p in (SOCK_PATH, PID_PATH):
            try:
                p.unlink(missing_ok=True)
            except Exception:
                pass
        log.info("Daemon exited cleanly")


if __name__ == "__main__":
    main()
