"""豆包流式 ASR 的二进制帧编解码。

纯函数模块：不涉及网络、音频、配置。这是整条链路上最容易静默出错的一环
——位运算或序列号写错不会抛异常，只会识别不出任何东西，所以单独成层并
用 round-trip 测试覆盖每一种组合。

协议来源：火山引擎官方文档 docs.volcengine.com/docs/6561/1354869

帧布局：
    header(4B) [+ sequence(4B, int32 be)] [+ error_code(4B, uint32 be)]
    + size(4B, uint32 be) + payload

    sequence 仅在 flags 含序列号时存在；error_code 仅在 message_type 为
    ERROR_RESPONSE 时存在。
"""

from __future__ import annotations

import gzip
import struct
from dataclasses import dataclass

PROTOCOL_VERSION = 0b0001
HEADER_SIZE_WORDS = 0b0001  # 单位为 4 字节，故 header 共 4 字节

# message type
FULL_CLIENT_REQUEST = 0x1
AUDIO_ONLY_REQUEST = 0x2
FULL_SERVER_RESPONSE = 0x9
ERROR_RESPONSE = 0xF

# message type specific flags
NO_SEQUENCE = 0x0
POS_SEQUENCE = 0x1
NEG_SEQUENCE = 0x2  # 末包标识，不携带序列号
NEG_WITH_SEQUENCE = 0x3  # 负序列号，同时表示末包

# serialization
NO_SERIALIZATION = 0x0
JSON_SERIALIZATION = 0x1

# compression
NO_COMPRESSION = 0x0
GZIP_COMPRESSION = 0x1

_FLAGS_WITH_SEQUENCE = frozenset({POS_SEQUENCE, NEG_WITH_SEQUENCE})


@dataclass(frozen=True)
class Header:
    protocol_version: int
    header_size_words: int
    message_type: int
    flags: int
    serialization: int
    compression: int


@dataclass(frozen=True)
class Frame:
    message_type: int
    flags: int
    sequence: int | None
    error_code: int | None
    payload: bytes


def build_header(
    message_type: int,
    flags: int,
    serialization: int = JSON_SERIALIZATION,
    compression: int = GZIP_COMPRESSION,
) -> bytes:
    return bytes(
        [
            (PROTOCOL_VERSION << 4) | HEADER_SIZE_WORDS,
            (message_type << 4) | flags,
            (serialization << 4) | compression,
            0x00,
        ]
    )


def parse_header(data: bytes) -> Header:
    if len(data) < 4:
        raise ValueError(f"header 至少 4 字节，实际收到 {len(data)}")
    return Header(
        protocol_version=data[0] >> 4,
        header_size_words=data[0] & 0x0F,
        message_type=data[1] >> 4,
        flags=data[1] & 0x0F,
        serialization=data[2] >> 4,
        compression=data[2] & 0x0F,
    )


def build_frame(
    message_type: int,
    flags: int,
    payload: bytes,
    *,
    sequence: int | None = None,
    serialization: int = JSON_SERIALIZATION,
    compression: int = GZIP_COMPRESSION,
) -> bytes:
    needs_seq = flags in _FLAGS_WITH_SEQUENCE
    if needs_seq and sequence is None:
        raise ValueError(f"flags={flags:#x} 要求提供 sequence")
    if not needs_seq and sequence is not None:
        raise ValueError(f"flags={flags:#x} 不接受 sequence")

    out = build_header(message_type, flags, serialization, compression)
    if needs_seq:
        out += struct.pack(">i", sequence)
    if compression == GZIP_COMPRESSION:
        payload = gzip.compress(payload)
    return out + struct.pack(">I", len(payload)) + payload


def parse_frame(data: bytes) -> Frame:
    header = parse_header(data)
    offset = header.header_size_words * 4

    sequence = None
    if header.flags in _FLAGS_WITH_SEQUENCE:
        (sequence,) = struct.unpack_from(">i", data, offset)
        offset += 4

    error_code = None
    if header.message_type == ERROR_RESPONSE:
        (error_code,) = struct.unpack_from(">I", data, offset)
        offset += 4

    (size,) = struct.unpack_from(">I", data, offset)
    offset += 4
    payload = data[offset : offset + size]
    if len(payload) != size:
        raise ValueError(f"payload 声明 {size} 字节，实际只有 {len(payload)} 字节")
    if header.compression == GZIP_COMPRESSION:
        payload = gzip.decompress(payload)

    return Frame(header.message_type, header.flags, sequence, error_code, payload)
