import struct

import pytest

from doubao_voice import protocol as p


def test_build_header_bit_layout():
    """byte0=版本|头长, byte1=类型|标志, byte2=序列化|压缩, byte3=保留。"""
    h = p.build_header(
        p.AUDIO_ONLY_REQUEST, p.POS_SEQUENCE, p.NO_SERIALIZATION, p.GZIP_COMPRESSION
    )
    assert h == bytes([0x11, 0x21, 0x01, 0x00])


def test_build_header_is_always_four_bytes():
    h = p.build_header(p.FULL_CLIENT_REQUEST, p.NO_SEQUENCE)
    assert len(h) == 4


def test_parse_header_roundtrips_every_combination():
    types = (
        p.FULL_CLIENT_REQUEST,
        p.AUDIO_ONLY_REQUEST,
        p.FULL_SERVER_RESPONSE,
        p.ERROR_RESPONSE,
    )
    flags = (p.NO_SEQUENCE, p.POS_SEQUENCE, p.NEG_SEQUENCE, p.NEG_WITH_SEQUENCE)
    comps = (p.NO_COMPRESSION, p.GZIP_COMPRESSION)
    for mt in types:
        for fl in flags:
            for comp in comps:
                got = p.parse_header(p.build_header(mt, fl, p.JSON_SERIALIZATION, comp))
                assert got.message_type == mt
                assert got.flags == fl
                assert got.compression == comp
                assert got.serialization == p.JSON_SERIALIZATION
                assert got.protocol_version == 1
                assert got.header_size_words == 1


def test_parse_header_rejects_short_input():
    with pytest.raises(ValueError, match="4 字节"):
        p.parse_header(b"\x11\x21")


def test_frame_roundtrip_with_positive_sequence():
    raw = p.build_frame(
        p.AUDIO_ONLY_REQUEST,
        p.POS_SEQUENCE,
        b"\x00\x01" * 10,
        sequence=7,
        serialization=p.NO_SERIALIZATION,
    )
    f = p.parse_frame(raw)
    assert f.message_type == p.AUDIO_ONLY_REQUEST
    assert f.sequence == 7
    assert f.error_code is None
    assert f.payload == b"\x00\x01" * 10


def test_frame_roundtrip_with_negative_sequence_marks_last_packet():
    raw = p.build_frame(
        p.AUDIO_ONLY_REQUEST,
        p.NEG_WITH_SEQUENCE,
        b"",
        sequence=-42,
        serialization=p.NO_SERIALIZATION,
    )
    f = p.parse_frame(raw)
    assert f.sequence == -42
    assert f.payload == b""


def test_frame_without_sequence_flag_has_no_sequence():
    raw = p.build_frame(
        p.FULL_CLIENT_REQUEST, p.NO_SEQUENCE, b"{}", compression=p.NO_COMPRESSION
    )
    assert p.parse_frame(raw).sequence is None


def test_gzip_disabled_leaves_payload_readable():
    raw = p.build_frame(
        p.FULL_CLIENT_REQUEST, p.NO_SEQUENCE, b'{"a":1}', compression=p.NO_COMPRESSION
    )
    assert b'{"a":1}' in raw


def test_gzip_enabled_actually_compresses_and_survives_roundtrip():
    raw = p.build_frame(
        p.FULL_CLIENT_REQUEST, p.NO_SEQUENCE, b'{"a":1}', compression=p.GZIP_COMPRESSION
    )
    assert b'{"a":1}' not in raw
    assert p.parse_frame(raw).payload == b'{"a":1}'


def test_error_response_carries_error_code_before_payload():
    payload = b'{"message":"boom"}'
    raw = (
        p.build_header(
            p.ERROR_RESPONSE, p.NO_SEQUENCE, p.JSON_SERIALIZATION, p.NO_COMPRESSION
        )
        + struct.pack(">I", 45000001)
        + struct.pack(">I", len(payload))
        + payload
    )
    f = p.parse_frame(raw)
    assert f.error_code == 45000001
    assert f.payload == payload


def test_sequence_required_when_flag_demands_it():
    with pytest.raises(ValueError, match="sequence"):
        p.build_frame(p.AUDIO_ONLY_REQUEST, p.POS_SEQUENCE, b"x")


def test_sequence_rejected_when_flag_forbids_it():
    with pytest.raises(ValueError, match="sequence"):
        p.build_frame(p.AUDIO_ONLY_REQUEST, p.NO_SEQUENCE, b"x", sequence=1)


def test_truncated_payload_is_rejected():
    good = p.build_frame(
        p.FULL_CLIENT_REQUEST, p.NO_SEQUENCE, b"hello", compression=p.NO_COMPRESSION
    )
    with pytest.raises(ValueError, match="payload"):
        p.parse_frame(good[:-2])
