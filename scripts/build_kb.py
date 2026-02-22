#!/usr/bin/env python3
"""
build_kb.py — Parse ~/.zsh_history into a SQLite FTS5 knowledge base.

Usage:
    python3 build_kb.py [--history PATH] [--db PATH] [--rebuild]
"""

import argparse
import os
import re
import sqlite3
import sys
from pathlib import Path

DEFAULT_HISTORY = Path.home() / ".zsh_history"
DEFAULT_DB = Path.home() / ".local/share/zsh-ai-autocomplete/history.db"

# Extended zsh history format: `: timestamp:elapsed;command`
_EXTENDED_RE = re.compile(r"^: \d+:\d+;(.+)$")


def parse_history(path: Path) -> list[str]:
    """Parse zsh history file, handling both plain and extended formats.

    Extended format lines may be continued with a trailing backslash across
    multiple physical lines; we join them into a single logical command.
    """
    commands: list[str] = []
    try:
        raw = path.read_bytes()
    except OSError as e:
        print(f"Error reading history file: {e}", file=sys.stderr)
        return commands

    # Decode with surrogate-escape so we don't crash on non-UTF-8 bytes
    text = raw.decode("utf-8", errors="surrogateescape")

    # Join physical continuation lines (trailing backslash)
    logical_lines: list[str] = []
    buf = ""
    for line in text.splitlines():
        if line.endswith("\\"):
            buf += line[:-1] + " "
        else:
            buf += line
            logical_lines.append(buf)
            buf = ""
    if buf:
        logical_lines.append(buf)

    for line in logical_lines:
        m = _EXTENDED_RE.match(line)
        if m:
            cmd = m.group(1).strip()
        else:
            cmd = line.strip()

        # Skip comments and very short commands
        if not cmd or cmd.startswith("#") or len(cmd) < 3:
            continue
        commands.append(cmd)

    return commands


def normalize(cmd: str) -> str:
    """Collapse runs of whitespace to a single space and strip surrogates."""
    # Remove surrogate-escaped bytes that SQLite cannot store
    cmd = cmd.encode("utf-8", errors="ignore").decode("utf-8")
    return " ".join(cmd.split())


def build_db(db_path: Path, commands: list[str]) -> None:
    """Create (or rebuild) the FTS5 database from a list of commands."""
    db_path.parent.mkdir(parents=True, exist_ok=True)

    # Remove stale DB so we start fresh on --rebuild
    if db_path.exists():
        db_path.unlink()

    con = sqlite3.connect(str(db_path))
    try:
        con.execute("PRAGMA journal_mode=WAL")
        con.execute("PRAGMA synchronous=NORMAL")
        con.execute(
            "CREATE VIRTUAL TABLE IF NOT EXISTS commands "
            "USING fts5(cmd, tokenize='porter unicode61')"
        )

        # Deduplicate while preserving order (last-seen wins position)
        seen: set[str] = set()
        unique: list[str] = []
        for cmd in commands:
            norm = normalize(cmd)
            if norm not in seen:
                seen.add(norm)
                unique.append(norm)

        con.executemany("INSERT INTO commands(cmd) VALUES (?)", [(c,) for c in unique])
        con.execute("INSERT INTO commands(commands) VALUES('optimize')")
        con.commit()
        print(
            f"Built knowledge base: {len(unique)} unique commands → {db_path}",
            file=sys.stderr,
        )
    finally:
        con.close()


def main() -> None:
    parser = argparse.ArgumentParser(description="Build ZSH AI autocomplete knowledge base")
    parser.add_argument(
        "--history",
        type=Path,
        default=DEFAULT_HISTORY,
        help=f"Path to zsh history file (default: {DEFAULT_HISTORY})",
    )
    parser.add_argument(
        "--db",
        type=Path,
        default=DEFAULT_DB,
        help=f"Path to output SQLite DB (default: {DEFAULT_DB})",
    )
    parser.add_argument(
        "--rebuild",
        action="store_true",
        help="Force rebuild even if DB already exists",
    )
    args = parser.parse_args()

    if args.db.exists() and not args.rebuild:
        print(f"DB already exists at {args.db}. Use --rebuild to overwrite.", file=sys.stderr)
        sys.exit(0)

    if not args.history.exists():
        print(f"History file not found: {args.history}", file=sys.stderr)
        sys.exit(1)

    commands = parse_history(args.history)
    if not commands:
        print("No commands parsed from history file.", file=sys.stderr)
        sys.exit(1)

    build_db(args.db, commands)


if __name__ == "__main__":
    main()
