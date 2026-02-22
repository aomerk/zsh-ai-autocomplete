# zsh-ai-autocomplete

Type a description of what you want to do, press **Ctrl+Space**, pick a command from an fzf menu.

```
❯ fetch btc price     ← you type this
```
```
  anthropic · claude-haiku-4-5-20251001  thinking…
> curl -s "https://api.binance.com/api/v3/ticker/price?symbol=BTCUSDT"
  curl -s "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd"
  curl -s "https://min-api.cryptocompare.com/data/price?fsym=BTC&tsyms=USD"
  curl -s "https://api.kraken.com/0/public/Ticker?pair=BTCUSD"
  http GET "https://api.binance.com/api/v3/ticker/price?symbol=BTCUSDT"
  5/5 ─────────────────────────────────────────────
```

Commands stream in one-by-one as the model generates them. Press Enter to accept, Escape to cancel.

---

## Install

```zsh
git clone https://github.com/aomerk/zsh-ai-autocomplete ~/.zsh/zsh-ai-autocomplete
zsh ~/.zsh/zsh-ai-autocomplete/install.zsh
```

Then reload your shell:

```zsh
exec zsh
```

## Requirements

| Tool | Required | Notes |
|------|----------|-------|
| `python3` | Yes | >= 3.8 |
| `socat` | Yes | Installed automatically on Linux |
| `fzf` | Yes | Must be in PATH |
| `sqlite3` | Yes | Built into Python stdlib |
| LLM backend | One of the two below | |

### Backend option A — local (default)

`llama-server` is downloaded automatically from GitHub releases. A model is downloaded from HuggingFace (~900MB).

Default model: **Qwen2.5-Coder-1.5B-Instruct Q4_K_M**

```zsh
# No extra config needed — install.zsh handles everything
```

### Backend option B — Anthropic API

Much faster and higher quality. Requires an API key.

```zsh
# Add to ~/.zshrc before the source line:
export ZAI_BACKEND=anthropic
export ANTHROPIC_API_KEY=sk-ant-...
```

Default model: `claude-haiku-4-5-20251001`. Override with:

```zsh
export ZAI_ANTHROPIC_MODEL=claude-sonnet-4-6
```

---

## How it works

```
Ctrl+Space
    │
    ▼
plugin.zsh (ZLE widget)
    │  sends query over Unix socket via socat
    ▼
daemon.py (asyncio server)
    │  FTS5 keyword search against ~/.zsh_history (~10ms)
    │  builds prompt with relevant past commands as examples
    ▼
LLM backend (local llama-server or Anthropic API)
    │  streams tokens; daemon emits each complete command line immediately
    ▼
fzf picker (opens instantly, populates as commands arrive)
    │  user selects
    ▼
selected command → BUFFER
```

**Key design choices:**
- The fzf menu opens immediately — commands stream in as the model generates them
- History is searched via SQLite FTS5 (BM25 ranking) to ground suggestions in your actual workflow
- The daemon is a persistent background process — no per-keypress startup cost

---

## Configuration

All config is via environment variables set in `~/.zshrc`:

| Variable | Default | Description |
|----------|---------|-------------|
| `ZAI_BACKEND` | `local` | `local` or `anthropic` |
| `ANTHROPIC_API_KEY` | — | Required when `ZAI_BACKEND=anthropic` |
| `ZAI_ANTHROPIC_MODEL` | `claude-haiku-4-5-20251001` | Any Claude model ID |

---

## Commands

```zsh
# Rebuild history knowledge base (after a lot of new commands)
python3 ~/.zsh/zsh-ai-autocomplete/scripts/build_kb.py --rebuild

# View daemon logs
tail -f ~/.local/share/zsh-ai-autocomplete/daemon.log

# Restart the daemon
pkill -f daemon.py
# (it restarts automatically on next Ctrl+Space)
```

---

## License

MIT
