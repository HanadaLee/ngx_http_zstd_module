#!/usr/bin/env python3
"""Inspect a zstd frame produced by the nginx integration tests."""
import ctypes
import ctypes.util
import json
import pathlib
import sys


class FrameHeader(ctypes.Structure):
    _fields_ = [
        ("content_size", ctypes.c_ulonglong),
        ("window_size", ctypes.c_ulonglong),
        ("block_size", ctypes.c_uint),
        ("frame_type", ctypes.c_int),
        ("header_size", ctypes.c_uint),
        ("dictionary_id", ctypes.c_uint),
        ("checksum", ctypes.c_uint),
        ("reserved1", ctypes.c_uint),
        ("reserved2", ctypes.c_uint),
    ]


data = pathlib.Path(sys.argv[1]).read_bytes()
library = ctypes.CDLL(ctypes.util.find_library("zstd"))
library.ZSTD_getFrameHeader.argtypes = [
    ctypes.POINTER(FrameHeader), ctypes.c_void_p, ctypes.c_size_t
]
library.ZSTD_getFrameHeader.restype = ctypes.c_size_t
header = FrameHeader()
if library.ZSTD_getFrameHeader(ctypes.byref(header), data, len(data)) != 0:
    raise ValueError("incomplete or invalid zstd frame header")
content_size = header.content_size
if content_size == (1 << 64) - 1:
    content_size = None
print(json.dumps({"content_size": content_size,
                  "window_size": header.window_size,
                  "block_size": header.block_size}))
