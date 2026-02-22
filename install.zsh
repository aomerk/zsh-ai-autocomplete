#!/usr/bin/env zsh
# install.zsh — One-shot installer for zsh-ai-autocomplete
#
# Usage:
#   git clone https://github.com/aomerk/zsh-ai-autocomplete ~/.zsh/zsh-ai-autocomplete
#   zsh ~/.zsh/zsh-ai-autocomplete/install.zsh

set -e

PLUGIN_DIR="${${(%):-%x}:A:h}"
ZSHRC="${ZDOTDIR:-${HOME}}/.zshrc"
SOURCE_LINE="source \"${PLUGIN_DIR}/plugin.zsh\""

DATA_DIR="${HOME}/.local/share/zsh-ai-autocomplete"
MODELS_DIR="${HOME}/.local/share/models"
BIN_DIR="${HOME}/.local/bin"

MODEL_FILE="${MODELS_DIR}/qwen2.5-coder-1.5b-instruct-q4_k_m.gguf"
MODEL_URL="https://huggingface.co/bartowski/Qwen2.5-Coder-1.5B-Instruct-GGUF/resolve/main/Qwen2.5-Coder-1.5B-Instruct-Q4_K_M.gguf"

LLAMA_PID_FILE="${DATA_DIR}/llama-server.pid"
LLAMA_LOG_FILE="${DATA_DIR}/llama-server.log"
LLAMA_PORT=8080

mkdir -p "${DATA_DIR}" "${MODELS_DIR}" "${BIN_DIR}"

# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------
_zai_info()  { print -P "%F{cyan}[zsh-ai-autocomplete]%f $*" }
_zai_ok()    { print -P "%F{green}[zsh-ai-autocomplete]%f $*" }
_zai_warn()  { print -P "%F{yellow}[zsh-ai-autocomplete]%f WARNING: $*" }
_zai_error() { print -P "%F{red}[zsh-ai-autocomplete]%f ERROR: $*" >&2 }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
_download() {
    local url="$1" dest="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fSL --progress-bar -o "${dest}" "${url}"
    elif command -v wget >/dev/null 2>&1; then
        wget --show-progress -O "${dest}" "${url}"
    else
        _zai_error "Neither curl nor wget found."
        return 1
    fi
}

_pkg_install() {
    local pkg_arch="$1" pkg_apt="$2" pkg_dnf="$3" pkg_brew="$4" pkg_zypper="$5"
    if   command -v pacman  >/dev/null 2>&1; then sudo pacman  -S --noconfirm "${pkg_arch}"
    elif command -v apt     >/dev/null 2>&1; then sudo apt     install -y     "${pkg_apt}"
    elif command -v apt-get >/dev/null 2>&1; then sudo apt-get install -y     "${pkg_apt}"
    elif command -v dnf     >/dev/null 2>&1; then sudo dnf     install -y     "${pkg_dnf}"
    elif command -v yum     >/dev/null 2>&1; then sudo yum     install -y     "${pkg_dnf}"
    elif command -v zypper  >/dev/null 2>&1; then sudo zypper  install -y     "${pkg_zypper}"
    elif command -v brew    >/dev/null 2>&1; then brew install                "${pkg_brew}"
    else
        _zai_error "No supported package manager found. Install ${pkg_apt} manually."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# 1. Choose backend
# ---------------------------------------------------------------------------
print ""
print -P "%F{cyan}%B┌─ Choose a backend ───────────────────────────────────────┐%b%f"
print -P "%F{cyan}%B│%b%f  1) %BLocal model%b — runs on your machine, no API key needed  %F{cyan}%B│%b%f"
print -P "%F{cyan}%B│%b%f     Downloads llama-server + Qwen2.5-Coder 1.5B (~900MB)    %F{cyan}%B│%b%f"
print -P "%F{cyan}%B│%b%f                                                              %F{cyan}%B│%b%f"
print -P "%F{cyan}%B│%b%f  2) %BAnthropic API%b — faster, smarter, needs an API key      %F{cyan}%B│%b%f"
print -P "%F{cyan}%B│%b%f     Uses Claude Haiku by default                             %F{cyan}%B│%b%f"
print -P "%F{cyan}%B└──────────────────────────────────────────────────────────┘%b%f"
print ""

local backend_choice
while true; do
    printf "  Select [1/2]: "
    read -r backend_choice </dev/tty
    case "${backend_choice}" in
        1) BACKEND=local;      break ;;
        2) BACKEND=anthropic;  break ;;
        *) print "  Please enter 1 or 2." ;;
    esac
done
print ""

# ---------------------------------------------------------------------------
# 2. If Anthropic: get API key, write to .zshrc, done with LLM setup
# ---------------------------------------------------------------------------
if [[ "${BACKEND}" == "anthropic" ]]; then
    print -P "  Enter your Anthropic API key (starts with %Bsk-ant-%b):"
    printf "  > "
    local api_key
    read -rs api_key </dev/tty
    print ""

    if [[ -z "${api_key}" || "${api_key}" != sk-ant-* ]]; then
        _zai_error "Invalid API key. It should start with 'sk-ant-'."
        exit 1
    fi

    # Write env vars to .zshrc (idempotent)
    if grep -q "ZAI_BACKEND=anthropic" "${ZSHRC}" 2>/dev/null; then
        _zai_ok "Anthropic config already in ${ZSHRC}."
    else
        print >> "${ZSHRC}"
        print "# zsh-ai-autocomplete backend" >> "${ZSHRC}"
        print "export ZAI_BACKEND=anthropic" >> "${ZSHRC}"
        print "export ANTHROPIC_API_KEY=${api_key}" >> "${ZSHRC}"
        _zai_ok "Anthropic API key saved to ${ZSHRC}."
    fi
fi

# ---------------------------------------------------------------------------
# 3. fzf
# ---------------------------------------------------------------------------
_zai_info "Checking fzf..."
if ! command -v fzf >/dev/null 2>&1; then
    _zai_error "fzf not found. Install it then re-run:"
    _zai_error "  Arch:   sudo pacman -S fzf"
    _zai_error "  Debian: sudo apt install fzf"
    _zai_error "  macOS:  brew install fzf"
    exit 1
fi
_zai_ok "fzf: $(command -v fzf)"

# ---------------------------------------------------------------------------
# 4. socat
# ---------------------------------------------------------------------------
_zai_info "Checking socat..."
if ! command -v socat >/dev/null 2>&1; then
    _zai_info "Installing socat..."
    _pkg_install socat socat socat socat socat
fi
_zai_ok "socat: $(command -v socat)"

# ---------------------------------------------------------------------------
# 5. python3
# ---------------------------------------------------------------------------
_zai_info "Checking python3..."
if ! command -v python3 >/dev/null 2>&1; then
    _zai_error "python3 not found. Install Python >= 3.8 and re-run."
    exit 1
fi
local pyver
pyver=$(python3 -c 'import sys; print(sys.version_info[:2] >= (3,8))' 2>/dev/null)
if [[ "${pyver}" != "True" ]]; then
    _zai_error "Python >= 3.8 required."
    exit 1
fi
_zai_ok "python3: $(python3 --version)"

# ---------------------------------------------------------------------------
# 6. Local backend: download llama-server + model, start server
# ---------------------------------------------------------------------------
if [[ "${BACKEND}" == "local" ]]; then

    _zai_info "Checking llama-server..."
    if ! command -v llama-server >/dev/null 2>&1; then
        _zai_info "Downloading llama-server from GitHub releases..."

        local kernel arch asset_pattern
        kernel=$(uname -s)
        arch=$(uname -m)

        case "${kernel}" in
            Linux)
                case "${arch}" in
                    x86_64) asset_pattern="ubuntu-x64" ;;
                    *)
                        _zai_error "No pre-built llama.cpp binary for Linux ${arch}."
                        _zai_error "Build from source: https://github.com/ggerganov/llama.cpp#build"
                        exit 1 ;;
                esac ;;
            Darwin)
                case "${arch}" in
                    arm64)  asset_pattern="macos-arm64" ;;
                    x86_64) asset_pattern="macos-x64"   ;;
                    *)      _zai_error "Unsupported macOS arch: ${arch}"; exit 1 ;;
                esac ;;
            *)
                _zai_error "Unsupported OS: ${kernel}"
                exit 1 ;;
        esac

        local tmpjson
        tmpjson=$(mktemp /tmp/llama-release-XXXXXX.json)
        if ! curl -fsSL "https://api.github.com/repos/ggerganov/llama.cpp/releases/latest" -o "${tmpjson}"; then
            _zai_error "Failed to fetch llama.cpp release info (rate limited or no network)."
            rm -f "${tmpjson}"; exit 1
        fi
        [[ -s "${tmpjson}" ]] || { _zai_error "Empty response from GitHub."; rm -f "${tmpjson}"; exit 1 }

        local asset_url
        asset_url=$(python3 - "${asset_pattern}" "${tmpjson}" <<'PYEOF'
import sys, json
pattern, json_path = sys.argv[1], sys.argv[2]
with open(json_path) as f:
    data = json.load(f)
skip = ("cuda", "vulkan", "metal", "opencl", "rocm", "sycl", "hip")
candidates = [a for a in data.get("assets", [])
              if pattern in a["name"]
              and not any(x in a["name"] for x in skip)
              and (a["name"].endswith(".tar.gz") or a["name"].endswith(".zip"))]
print(candidates[0]["browser_download_url"] if candidates else "", end="")
PYEOF
)
        rm -f "${tmpjson}"

        if [[ -z "${asset_url}" ]]; then
            _zai_error "Could not find a ${asset_pattern} asset in the latest llama.cpp release."
            exit 1
        fi

        local tmparc llama_lib_dir="${HOME}/.local/share/llama.cpp"
        tmparc=$(mktemp /tmp/llama-XXXXXX)
        _zai_info "Downloading: ${asset_url}"
        _download "${asset_url}" "${tmparc}"

        mkdir -p "${llama_lib_dir}"
        if [[ "${asset_url}" == *.tar.gz ]]; then
            tar -xzf "${tmparc}" --strip-components=1 -C "${llama_lib_dir}"
        else
            unzip -q "${tmparc}" -d "${llama_lib_dir}"
        fi
        rm -f "${tmparc}"

        [[ -x "${llama_lib_dir}/llama-server" ]] || {
            _zai_error "llama-server binary not found after extraction."; exit 1
        }

        cat > "${BIN_DIR}/llama-server" <<WRAPPER
#!/usr/bin/env sh
exec env LD_LIBRARY_PATH="${llama_lib_dir}\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}" \\
    "${llama_lib_dir}/llama-server" "\$@"
WRAPPER
        chmod +x "${BIN_DIR}/llama-server"
        export PATH="${BIN_DIR}:${PATH}"
    fi
    _zai_ok "llama-server: $(command -v llama-server)"

    # Model
    _zai_info "Checking model..."
    if [[ -f "${MODEL_FILE}" ]]; then
        _zai_ok "Model already present: ${MODEL_FILE}"
    else
        _zai_info "Downloading Qwen2.5-Coder-1.5B Q4_K_M (~900MB)..."
        _download "${MODEL_URL}" "${MODEL_FILE}"
        _zai_ok "Model saved to ${MODEL_FILE}"
    fi

    # Start llama-server
    _zai_info "Starting llama-server on port ${LLAMA_PORT}..."
    if [[ -f "${LLAMA_PID_FILE}" ]]; then
        local old_pid=$(<"${LLAMA_PID_FILE}")
        if [[ -n "${old_pid}" ]] && kill -0 "${old_pid}" 2>/dev/null; then
            kill "${old_pid}" 2>/dev/null || true
            sleep 1
        fi
        rm -f "${LLAMA_PID_FILE}"
    fi

    nohup llama-server \
        -m "${MODEL_FILE}" \
        -c 512 --port "${LLAMA_PORT}" -t 8 -ngl 0 --cont-batching \
        >>"${LLAMA_LOG_FILE}" 2>&1 &
    local llama_pid=$!
    print "${llama_pid}" > "${LLAMA_PID_FILE}"
    _zai_info "llama-server started (PID ${llama_pid}), waiting for ready..."

    local ready=0
    for i in {1..60}; do
        curl -sf "http://127.0.0.1:${LLAMA_PORT}/health" >/dev/null 2>&1 && { ready=1; break }
        sleep 0.5
    done
    (( ready )) && _zai_ok "llama-server ready on port ${LLAMA_PORT}." \
                || _zai_warn "llama-server did not respond within 30s. Check: ${LLAMA_LOG_FILE}"
fi

# ---------------------------------------------------------------------------
# 7. Build knowledge base
# ---------------------------------------------------------------------------
_zai_info "Building knowledge base from ~/.zsh_history..."
python3 "${PLUGIN_DIR}/scripts/build_kb.py" --rebuild
_zai_ok "Knowledge base built."

# ---------------------------------------------------------------------------
# 8. Add plugin to .zshrc
# ---------------------------------------------------------------------------
if grep -qF "${SOURCE_LINE}" "${ZSHRC}" 2>/dev/null; then
    _zai_ok "Plugin already sourced in ${ZSHRC}."
else
    print >> "${ZSHRC}"
    print "# zsh-ai-autocomplete" >> "${ZSHRC}"
    print "${SOURCE_LINE}" >> "${ZSHRC}"
    _zai_ok "Added plugin to ${ZSHRC}."
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
print ""
_zai_ok "Installation complete! Reload your shell:"
print ""
print "    exec zsh"
print ""
print "Type what you want, press Ctrl+Space, pick a command."
print ""
if [[ "${BACKEND}" == "local" ]]; then
    _zai_info "Logs: ${LLAMA_LOG_FILE}"
fi
_zai_info "Logs: ${DATA_DIR}/daemon.log"
