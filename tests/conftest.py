import shutil
import tempfile
from pathlib import Path

import pytest


@pytest.fixture
def sock_dir():
    """短路径临时目录。

    pytest 的 tmp_path 会把测试名嵌进路径，动辄上百字节，而 macOS 的
    AF_UNIX 路径上限是 104 字节，直接用会 OSError。真实部署路径
    ~/.doubao-voice/ctl.sock 只有 40 字节，不受影响。
    """
    path = Path(tempfile.mkdtemp(prefix="dbv", dir="/tmp"))
    yield path
    shutil.rmtree(path, ignore_errors=True)
