# plugin.zsh — ZSH AI Command Finder
# Type a natural language description, press Ctrl+Space, pick a command with fzf.

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
_ZAI_DIR="${HOME}/.local/share/zsh-ai-autocomplete"
_ZAI_SOCK="${_ZAI_DIR}/daemon.sock"
_ZAI_PID="${_ZAI_DIR}/daemon.pid"
_ZAI_LOG="${_ZAI_DIR}/daemon.log"
_ZAI_DB="${_ZAI_DIR}/history.db"
_ZAI_PLUGIN_DIR="${${(%):-%x}:A:h}"

# ---------------------------------------------------------------------------
# Daemon management
# ---------------------------------------------------------------------------

_zai_daemon_running() {
    [[ -f "${_ZAI_PID}" ]] || return 1
    local pid=$(<"${_ZAI_PID}")
    [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null
}

_zai_start_daemon() {
    local daemon="${_ZAI_PLUGIN_DIR}/daemon.py"
    [[ -f "${daemon}" ]] || { print -u2 "zsh-ai: daemon.py not found"; return 1 }
    mkdir -p "${_ZAI_DIR}"
    nohup python3 "${daemon}" >>"${_ZAI_LOG}" 2>&1 &!
    local i
    for i in {1..20}; do
        [[ -S "${_ZAI_SOCK}" ]] && return 0
        sleep 0.1
    done
    print -u2 "zsh-ai: daemon socket did not appear within 2s"
    return 1
}

_zai_ensure_daemon() {
    _zai_daemon_running && return 0
    _zai_start_daemon
}

# ---------------------------------------------------------------------------
# Main widget
# ---------------------------------------------------------------------------

_zai_pick() {
    setopt LOCAL_OPTIONS NO_NOTIFY NO_MONITOR

    if ! command -v fzf >/dev/null 2>&1; then
        zle -M "zsh-ai: fzf not found"; return 0
    fi
    if ! command -v socat >/dev/null 2>&1; then
        zle -M "zsh-ai: socat not found"; return 0
    fi

    _zai_ensure_daemon || return 0

    local query="${BUFFER}"
    [[ -z "${query}" ]] && return 0

    # Build a backend label for the fzf header
    local _backend_label
    if [[ "${ZAI_BACKEND:-local}" == "anthropic" && -n "${ANTHROPIC_API_KEY}" ]]; then
        _backend_label="anthropic · ${ZAI_ANTHROPIC_MODEL:-claude-haiku-4-5-20251001}"
    else
        _backend_label="local · llama-server"
    fi

    # FIFO: socat writes to it in the background; fzf reads from it immediately.
    # fzf opens its TUI right away and populates the list as lines arrive.
    local fifo
    fifo=$(mktemp -u /tmp/zai-XXXXXX)
    mkfifo "${fifo}"

    # Background: query daemon → FIFO
    (printf '%s\n' "${query}" \
        | socat -t35 -T35 - "UNIX-CONNECT:${_ZAI_SOCK}" 2>/dev/null \
        > "${fifo}") &
    local bg_pid=$!

    # fzf opens immediately; reads list from FIFO, keyboard from /dev/tty auto
    local selected
    selected=$(fzf --height=40% --reverse \
                   --prompt=" cmd> " \
                   --header="${_backend_label}  thinking…" \
                   --info=hidden \
                   --no-sort \
                   < "${fifo}")

    wait "${bg_pid}" 2>/dev/null
    rm -f "${fifo}"

    if [[ -n "${selected}" ]]; then
        BUFFER="${selected}"
        CURSOR=${#BUFFER}
    fi

    zle reset-prompt
}

zle -N _zai_pick

# Ctrl+Space
bindkey '^@' _zai_pick

# ---------------------------------------------------------------------------
# Deferred init (first precmd only)
# ---------------------------------------------------------------------------

_zai_init_done=0

_zai_precmd_init() {
    (( _zai_init_done )) && return
    _zai_init_done=1
    add-zsh-hook -d precmd _zai_precmd_init

    if [[ ! -f "${_ZAI_DB}" ]]; then
        print -u2 "zsh-ai: building knowledge base..."
        python3 "${_ZAI_PLUGIN_DIR}/scripts/build_kb.py" --rebuild
    fi

    _zai_daemon_running || _zai_start_daemon &>/dev/null &!
}

autoload -Uz add-zsh-hook
add-zsh-hook precmd _zai_precmd_init
