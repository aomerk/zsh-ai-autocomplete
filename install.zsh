#!/usr/bin/env zsh
# install.zsh — One-shot installer for zsh-ai-autocomplete
#
# Usage:
#   git clone https://github.com/aomerk/zsh-ai-autocomplete ~/.zsh/zsh-ai-autocomplete
#   zsh ~/.zsh/zsh-ai-autocomplete/install.zsh
#
# What this does:
#   1. Checks fzf is installed (must be done manually)
#   2. Installs socat (via detected package manager)
#   3. Checks python3 >= 3.8
#   4. Downloads llama-server pre-built binary from GitHub releases
#   5. Downloads the recommended GGUF model from HuggingFace (~900MB)
#   6. Starts llama-server as a background daemon
#   7. Builds the FTS5 history knowledge base from ~/.zsh_history
#   8. Sources the plugin from ~/.zshrc
#
# To use Anthropic instead of local llama-server, add to ~/.zshrc before the source line:
#   export ZAI_BACKEND=anthropic
#   export ANTHROPIC_API_KEY=sk-ant-...

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
    # Try each package manager in turn; first match wins.
    local pkg_arch="$1" pkg_apt="$2" pkg_dnf="$3" pkg_brew="$4" pkg_zypper="$5"
    if command -v pacman  >/dev/null 2>&1; then sudo pacman  -S --noconfirm "${pkg_arch}"
    elif command -v apt   >/dev/null 2>&1; then sudo apt     install -y     "${pkg_apt}"
    elif command -v apt-get >/dev/null 2>&1; then sudo apt-get install -y   "${pkg_apt}"
    elif command -v dnf   >/dev/null 2>&1; then sudo dnf     install -y     "${pkg_dnf}"
    elif command -v yum   >/dev/null 2>&1; then sudo yum     install -y     "${pkg_dnf}"
    elif command -v zypper >/dev/null 2>&1; then sudo zypper install -y     "${pkg_zypper}"
    elif command -v brew  >/dev/null 2>&1; then brew install                "${pkg_brew}"
    else
        _zai_error "No supported package manager found. Install ${pkg_apt} manually."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# 1. fzf (required — not auto-installable cleanly cross-platform)
# ---------------------------------------------------------------------------
_zai_info "Checking fzf..."
if ! command -v fzf >/dev/null 2>&1; then
    _zai_error "fzf not found."
    _zai_error "Install it from https://github.com/junegunn/fzf#installation, then re-run."
    _zai_error "  Arch:   sudo pacman -S fzf"
    _zai_error "  Debian: sudo apt install fzf"
    _zai_error "  macOS:  brew install fzf"
    exit 1
fi
_zai_ok "fzf: $(command -v fzf)"

# ---------------------------------------------------------------------------
# 2. socat
# ---------------------------------------------------------------------------
_zai_info "Checking socat..."
if ! command -v socat >/dev/null 2>&1; then
    _zai_info "Installing socat..."
    _pkg_install socat socat socat socat socat
fi
_zai_ok "socat: $(command -v socat)"

# ---------------------------------------------------------------------------
# 2. python3
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
# 3. llama-server — download pre-built binary from GitHub releases
# ---------------------------------------------------------------------------
_zai_info "Checking llama-server..."

if ! command -v llama-server >/dev/null 2>&1; then
    _zai_info "llama-server not found. Downloading pre-built binary from GitHub..."

    # Detect OS and architecture
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
            esac
            ;;
        Darwin)
            case "${arch}" in
                arm64)  asset_pattern="macos-arm64" ;;
                x86_64) asset_pattern="macos-x64"   ;;
                *)
                    _zai_error "Unsupported macOS architecture: ${arch}"
                    exit 1 ;;
            esac
            ;;
        *)
            _zai_error "Unsupported OS: ${kernel}"
            _zai_error "Build from source: https://github.com/ggerganov/llama.cpp#build"
            exit 1 ;;
    esac

    # Fetch latest release metadata and find the matching asset URL
    _zai_info "Fetching latest release info from GitHub..."
    local tmpjson asset_url
    tmpjson=$(mktemp /tmp/llama-release-XXXXXX.json)
    if ! curl -fsSL "https://api.github.com/repos/ggerganov/llama.cpp/releases/latest" -o "${tmpjson}"; then
        _zai_error "Failed to fetch llama.cpp release info from GitHub (rate limited or no network)."
        rm -f "${tmpjson}"
        exit 1
    fi
    if [[ ! -s "${tmpjson}" ]]; then
        _zai_error "GitHub returned an empty response. Check your network connection."
        rm -f "${tmpjson}"
        exit 1
    fi
    # python3 reads script from heredoc (stdin); JSON is passed via file path arg
    asset_url=$(python3 - "${asset_pattern}" "${tmpjson}" <<'PYEOF'
import sys, json
pattern, json_path = sys.argv[1], sys.argv[2]
with open(json_path) as f:
    data = json.load(f)
assets = data.get("assets", [])
skip = ("cuda", "vulkan", "metal", "opencl", "rocm", "sycl", "hip")
candidates = [a for a in assets if pattern in a["name"]
              and not any(x in a["name"] for x in skip)
              and (a["name"].endswith(".tar.gz") or a["name"].endswith(".zip"))]
print(candidates[0]["browser_download_url"] if candidates else "", end="")
PYEOF
)
    rm -f "${tmpjson}"

    if [[ -z "${asset_url}" ]]; then
        _zai_error "Could not find a ${asset_pattern} asset in the latest llama.cpp release."
        _zai_error "Check https://github.com/ggerganov/llama.cpp/releases and install llama-server manually."
        exit 1
    fi

    _zai_info "Downloading: ${asset_url}"
    local tmparc llama_lib_dir="${HOME}/.local/share/llama.cpp"
    tmparc=$(mktemp /tmp/llama-XXXXXX)
    _download "${asset_url}" "${tmparc}"

    # Extract everything into ~/.local/share/llama.cpp/
    # (the binary links against bundled .so files that must stay alongside it)
    mkdir -p "${llama_lib_dir}"
    if [[ "${asset_url}" == *.tar.gz ]]; then
        tar -xzf "${tmparc}" --strip-components=1 -C "${llama_lib_dir}"
    else
        unzip -q "${tmparc}" -d "${llama_lib_dir}"
    fi
    rm -f "${tmparc}"

    if [[ ! -x "${llama_lib_dir}/llama-server" ]]; then
        _zai_error "llama-server binary not found after extraction."
        exit 1
    fi

    # Write a wrapper script that sets LD_LIBRARY_PATH before exec
    cat > "${BIN_DIR}/llama-server" <<WRAPPER
#!/usr/bin/env sh
exec env LD_LIBRARY_PATH="${llama_lib_dir}\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}" \\
    "${llama_lib_dir}/llama-server" "\$@"
WRAPPER
    chmod +x "${BIN_DIR}/llama-server"

    # Ensure ~/.local/bin is in PATH for this session
    export PATH="${BIN_DIR}:${PATH}"
fi

_zai_ok "llama-server: $(command -v llama-server)"

# ---------------------------------------------------------------------------
# 4. Download model
# ---------------------------------------------------------------------------
_zai_info "Checking model..."

if [[ -f "${MODEL_FILE}" ]]; then
    _zai_ok "Model already present: ${MODEL_FILE}"
else
    _zai_info "Downloading Qwen2.5-Coder-1.5B-Instruct Q4_K_M (~900MB)..."
    _download "${MODEL_URL}" "${MODEL_FILE}"
    _zai_ok "Model saved to ${MODEL_FILE}"
fi

# ---------------------------------------------------------------------------
# 5. Start llama-server
# ---------------------------------------------------------------------------
_zai_info "Starting llama-server on port ${LLAMA_PORT}..."

# Stop existing instance if running
if [[ -f "${LLAMA_PID_FILE}" ]]; then
    local old_pid
    old_pid=$(<"${LLAMA_PID_FILE}")
    if [[ -n "${old_pid}" ]] && kill -0 "${old_pid}" 2>/dev/null; then
        _zai_info "Stopping existing llama-server (PID ${old_pid})..."
        kill "${old_pid}" 2>/dev/null || true
        sleep 1
    fi
    rm -f "${LLAMA_PID_FILE}"
fi

nohup llama-server \
    -m "${MODEL_FILE}" \
    -c 512 \
    --port "${LLAMA_PORT}" \
    -t 8 \
    -ngl 0 \
    --cont-batching \
    >>"${LLAMA_LOG_FILE}" 2>&1 &
local llama_pid=$!
print "${llama_pid}" > "${LLAMA_PID_FILE}"
_zai_info "llama-server started (PID ${llama_pid}). Waiting for it to be ready..."

# Wait up to 30s for llama-server to respond
local ready=0
for i in {1..60}; do
    if curl -sf "http://127.0.0.1:${LLAMA_PORT}/health" >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 0.5
done

if (( ready )); then
    _zai_ok "llama-server is ready on port ${LLAMA_PORT}."
else
    _zai_warn "llama-server did not respond within 30s. Check: ${LLAMA_LOG_FILE}"
fi

# ---------------------------------------------------------------------------
# 6. Build knowledge base
# ---------------------------------------------------------------------------
_zai_info "Building knowledge base from ~/.zsh_history..."
python3 "${PLUGIN_DIR}/scripts/build_kb.py" --rebuild
_zai_ok "Knowledge base built."

# ---------------------------------------------------------------------------
# 7. Add plugin to .zshrc (idempotent)
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
print "Then type a partial command and press Ctrl+Space."
print "Press Tab to accept a suggestion."
print ""
_zai_info "Logs:"
print "    llama-server → ${LLAMA_LOG_FILE}"
print "    daemon       → ${DATA_DIR}/daemon.log"
