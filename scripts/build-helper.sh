#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

command -v uv >/dev/null 2>&1 || {
  echo "缺少 uv" >&2
  exit 1
}

mkdir -p App/Resources build/pyinstaller
pyinstaller_args=(
  --clean
  --noconfirm
  --onefile
  --name dbvoice
  --paths src
  --hidden-import sounddevice
  --collect-all sounddevice
  --collect-all websockets
  --distpath App/Resources
  --workpath build/pyinstaller
  packaging/daemon_entry.py
)
if [[ -n "${HELPER_CODESIGN_IDENTITY:-}" ]]; then
  pyinstaller_args+=(--codesign-identity "${HELPER_CODESIGN_IDENTITY}")
fi
uv run --with pyinstaller pyinstaller "${pyinstaller_args[@]}"

chmod 755 App/Resources/dbvoice

if [[ "${INCLUDE_LOCAL_ASR:-0}" == "1" ]]; then
  LOCAL_ASR_SOURCE_DIR="${LOCAL_ASR_SOURCE_DIR:-${HOME}/.doubao-voice/funasr}"
  required=(
    "bin/llama-funasr-sensevoice"
    "gguf/sensevoice-small-q8.gguf"
    "gguf/fsmn-vad.gguf"
  )
  for relative in "${required[@]}"; do
    if [[ ! -f "${LOCAL_ASR_SOURCE_DIR}/${relative}" ]]; then
      echo "缺少本地 ASR 资源：${LOCAL_ASR_SOURCE_DIR}/${relative}" >&2
      echo "请先运行 uv run dbvoice fetch-model" >&2
      exit 1
    fi
  done
  mkdir -p App/Resources/funasr/bin App/Resources/funasr/gguf
  cp "${LOCAL_ASR_SOURCE_DIR}/bin/llama-funasr-sensevoice" App/Resources/funasr/bin/
  cp "${LOCAL_ASR_SOURCE_DIR}/gguf/sensevoice-small-q8.gguf" App/Resources/funasr/gguf/
  cp "${LOCAL_ASR_SOURCE_DIR}/gguf/fsmn-vad.gguf" App/Resources/funasr/gguf/
  chmod 755 App/Resources/funasr/bin/llama-funasr-sensevoice
  echo "已准备离线 FunASR 资源"
else
  # 避免先构建本地版、再归档商店版时把 256 MB 离线模型误带进商店包。
  rm -rf App/Resources/funasr
fi

echo "已生成 App 内置 helper：App/Resources/dbvoice"
