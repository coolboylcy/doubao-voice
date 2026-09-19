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
  --name doggo
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

chmod 755 App/Resources/doggo

if [[ "${INCLUDE_LOCAL_ASR:-0}" == "1" ]]; then
  LOCAL_ASR_SOURCE_DIR="${LOCAL_ASR_SOURCE_DIR:-${HOME}/.voice-doggo/funasr}"
  required=(
    "bin/llama-funasr-sensevoice"
    "gguf/sensevoice-small-q8.gguf"
    "gguf/fsmn-vad.gguf"
  )
  for relative in "${required[@]}"; do
    if [[ ! -f "${LOCAL_ASR_SOURCE_DIR}/${relative}" ]]; then
      echo "缺少本地 ASR 资源：${LOCAL_ASR_SOURCE_DIR}/${relative}" >&2
      echo "请先运行 uv run doggo fetch-model" >&2
      exit 1
    fi
  done
  mkdir -p App/Resources/funasr/bin App/Resources/funasr/gguf
  cp "${LOCAL_ASR_SOURCE_DIR}/bin/llama-funasr-sensevoice" App/Resources/funasr/bin/
  cp "${LOCAL_ASR_SOURCE_DIR}/gguf/sensevoice-small-q8.gguf" App/Resources/funasr/gguf/
  cp "${LOCAL_ASR_SOURCE_DIR}/gguf/fsmn-vad.gguf" App/Resources/funasr/gguf/
  chmod 755 App/Resources/funasr/bin/llama-funasr-sensevoice
  # 必须在交给 Xcode 之前就签好。
  #
  # Xcode 打包时会给 bundle 内未签名的可执行文件补一个 ad-hoc 签名，而那发生在
  # 资源封印（sealed resources）算完之后——文件被改大了几百字节，App 本体的签名
  # 随即失效，codesign --verify 报「a sealed resource is missing or invalid」。
  #
  # 这个坑的隐蔽之处在于它只在 App/Resources/funasr 被重新拷贝时出现：平时那里
  # 残留着上一次构建签过的版本，一切正常；一旦重跑 build-helper.sh 覆盖成原始
  # 文件就翻车。
  if [[ -n "${HELPER_CODESIGN_IDENTITY:-}" ]]; then
    codesign --force --sign "${HELPER_CODESIGN_IDENTITY}" \
      --options runtime --timestamp=none \
      App/Resources/funasr/bin/llama-funasr-sensevoice
  fi
  echo "已准备离线 FunASR 资源"
else
  # 避免先构建本地版、再归档商店版时把 256 MB 离线模型误带进商店包。
  rm -rf App/Resources/funasr
fi

echo "已生成 App 内置 helper：App/Resources/doggo"
