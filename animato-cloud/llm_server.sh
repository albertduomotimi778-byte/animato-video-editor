#!/usr/bin/env bash
# Starts the app's own AI model on this GitHub runner — no API keys, no AI services.
#
#   llama.cpp (prebuilt CPU release, or built from source if the download fails)
#   + Gemma 4 E4B IT Q4_0 (CPU-compatible GGUF, about 4.59 GB) or E2B Q4_0 fallback (about 2.84 GB) on low-memory runners as an OpenAI-compatible server
#   on http://127.0.0.1:8080/v1. With "vision" as the first argument it also starts
#   Qwen2.5-VL-3B-Instruct + its mmproj on :8081 (looking at pictures); "vision-only"
#   starts just that one (the brain does this on first use).
#
# Everything lives in ~/animato-llm (cache that folder with actions/cache).
# Exports LOCAL_LLM_URL (and LOCAL_VLM_URL) to $GITHUB_ENV for the next steps.
set -euo pipefail
DIR="$HOME/animato-llm"
LLAMA_TAG="${LLAMA_TAG:-latest}"
# Use the stronger 4B-active-parameter Gemma 4 model when this runner has enough RAM;
# fall back to the smaller E2B on low-memory/self-hosted runners to avoid OOM.
# Use llama.cpp's Hugging Face resolver rather than hard-coded filenames. Model
# repositories frequently rename GGUF assets; -hf resolves the selected quantization
# from repository metadata and caches partial downloads safely.
if [ -n "${LLM_TEXT_REPO:-}" ]; then
  TEXT_HF="${LLM_TEXT_REPO}"
elif [ "$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)" -ge 12000 ]; then
  TEXT_HF="ggml-org/gemma-4-E4B-it-GGUF:Q4_0"
else
  TEXT_HF="ggml-org/gemma-4-E2B-it-GGUF:Q4_0"
fi
VL_HF="${LLM_VL_REPO:-ggml-org/Qwen2.5-VL-3B-Instruct-GGUF:Q4_K_M}"
CTX="${LLM_CTX:-8192}"

mkdir -p "$DIR/models" "$DIR/bin"
export LLAMA_CACHE="$DIR/models"

server_bin() { find "$DIR/bin" -type f -name llama-server -perm -u+x 2>/dev/null | head -n 1; }

if [ -z "$(server_bin)" ]; then
  echo "Installing the latest llama.cpp CPU server…"
  ok=0
  if [ "$LLAMA_TAG" = "latest" ]; then
    api=$(curl -fsSL --retry 3 https://api.github.com/repos/ggml-org/llama.cpp/releases/latest || true)
    url=$(printf '%s' "$api" | grep -o '"browser_download_url": *"[^"]*bin-ubuntu-x64\.\(tar\.gz\|zip\)"' | head -n 1 | sed 's/.*"\(https[^"]*\)"/\1/')
    if [ -n "$url" ] && curl -fsSL --retry 3 --retry-all-errors -o "$DIR/llama.pkg" "$url"; then
      case "$url" in *.zip) unzip -qo "$DIR/llama.pkg" -d "$DIR/bin" ;; *) tar -xzf "$DIR/llama.pkg" -C "$DIR/bin" ;; esac
      rm -f "$DIR/llama.pkg"; [ -n "$(server_bin)" ] && ok=1
    fi
  else
    for asset in "llama-${LLAMA_TAG}-bin-ubuntu-x64.tar.gz" "llama-${LLAMA_TAG}-bin-ubuntu-x64.zip"; do
      url="https://github.com/ggml-org/llama.cpp/releases/download/${LLAMA_TAG}/${asset}"
      if curl -fsSL --retry 3 --retry-all-errors -o "$DIR/$asset" "$url"; then
        case "$asset" in *.zip) unzip -qo "$DIR/$asset" -d "$DIR/bin" ;; *) tar -xzf "$DIR/$asset" -C "$DIR/bin" ;; esac
        rm -f "$DIR/$asset"; [ -n "$(server_bin)" ] && ok=1; break
      fi
    done
  fi
  if [ -z "$(server_bin)" ]; then
    echo "Prebuilt llama.cpp unavailable — building it (a few minutes, once)…"
    sudo apt-get install -y -qq build-essential cmake > /dev/null
    rm -rf "$DIR/src" && git clone --depth 1 https://github.com/ggml-org/llama.cpp "$DIR/src"
    cmake -S "$DIR/src" -B "$DIR/src/build" -DGGML_NATIVE=OFF -DLLAMA_CURL=OFF -DCMAKE_BUILD_TYPE=Release > /dev/null
    cmake --build "$DIR/src/build" --config Release -j "$(nproc)" --target llama-server > /dev/null
    mkdir -p "$DIR/bin/src" && cp -r "$DIR/src/build/bin/." "$DIR/bin/src/"
    rm -rf "$DIR/src"
  fi
fi
BIN="$(server_bin)"; BIN_DIR="$(dirname "$BIN")"
export LD_LIBRARY_PATH="$BIN_DIR:${LD_LIBRARY_PATH:-}"

# llama.cpp's -hf downloader handles repository metadata, quant selection, cache,
# retries and resume. Keep the cache directory stable across workflow runs.
THREADS="$(nproc)"
start() { # port args…
  local port="$1"; shift
  nohup "$BIN" --host 127.0.0.1 --port "$port" -t "$THREADS" -np 1 --cache-reuse 256 "$@" > "$DIR/server-$port.log" 2>&1 &
  local pid=$!
  for i in $(seq 1 "${LLM_START_TIMEOUT:-900}"); do
    if curl -fs "http://127.0.0.1:$port/health" > /dev/null 2>&1; then echo "AI model ready on :$port ($i s)"; return 0; fi
    sleep 1
  done
  echo "::error::the AI model did not start on :$port"; tail -n 60 "$DIR/server-$port.log"; kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; return 1
}
if [ "${1:-}" != "vision-only" ]; then
  echo "Starting CPU text model: $TEXT_HF"
  if ! start 8080 -hf "$TEXT_HF" -c "$CTX"; then
    if [ -n "${LLM_TEXT_REPO:-}" ]; then exit 1; fi
    if [[ "$TEXT_HF" == *"E4B"* ]]; then FALLBACK_HF="ggml-org/gemma-4-E2B-it-GGUF:Q4_0"; else FALLBACK_HF="ggml-org/gemma-3-1b-it-GGUF:Q4_K_M"; fi
    echo "Primary model failed. Retrying with fallback: $FALLBACK_HF"
    start 8080 -hf "$FALLBACK_HF" -c "${LLM_FALLBACK_CTX:-4096}"
  fi
  [ -n "${GITHUB_ENV:-}" ] && echo "LOCAL_LLM_URL=http://127.0.0.1:8080/v1" >> "$GITHUB_ENV"
fi

if [ "${1:-}" = "vision" ] || [ "${1:-}" = "vision-only" ]; then
  echo "Starting CPU vision model: $VL_HF"
  start 8081 -hf "$VL_HF" -c 4096
  [ -n "${GITHUB_ENV:-}" ] && echo "LOCAL_VLM_URL=http://127.0.0.1:8081/v1" >> "$GITHUB_ENV"
fi
echo "LLAMA_SERVER_BIN=$BIN" >> "${GITHUB_ENV:-/dev/null}"
