"""PyInstaller 的稳定入口，保留 voice_doggo 包上下文。"""

from voice_doggo.cli import main

if __name__ == "__main__":
    raise SystemExit(main())
