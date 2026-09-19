"""PyInstaller 的稳定入口，保留 doubao_voice 包上下文。"""

from doubao_voice.cli import main

if __name__ == "__main__":
    raise SystemExit(main())
