#!/usr/bin/env python3
"""Decode a complete HTTP representation with the system codec libraries."""
import ctypes
import ctypes.util
import pathlib
import sys
import zlib

encoding, source, target, expected = sys.argv[1:]
data = pathlib.Path(source).read_bytes()
limit = int(expected) + 1
if encoding in ("gzip", "deflate"):
    decoder = zlib.decompressobj(31 if encoding == "gzip" else 15)
    result = decoder.decompress(data) + decoder.flush()
    if not decoder.eof or decoder.unused_data or decoder.unconsumed_tail:
        raise ValueError("incomplete stream or trailing data")
else:
    output = ctypes.create_string_buffer(limit)
    if encoding == "br":
        library = ctypes.CDLL(ctypes.util.find_library("brotlidec"))
        decode = library.BrotliDecoderDecompress
        decode.argtypes = [ctypes.c_size_t, ctypes.c_void_p,
                           ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p]
        decode.restype = ctypes.c_int
        size = ctypes.c_size_t(limit)
        if decode(len(data), data, ctypes.byref(size), output) != 1:
            raise ValueError("invalid Brotli stream")
        result = output.raw[:size.value]
    elif encoding == "zstd":
        library = ctypes.CDLL(ctypes.util.find_library("zstd"))
        decode = library.ZSTD_decompress
        decode.argtypes = [ctypes.c_void_p, ctypes.c_size_t,
                           ctypes.c_void_p, ctypes.c_size_t]
        decode.restype = ctypes.c_size_t
        library.ZSTD_isError.argtypes = [ctypes.c_size_t]
        library.ZSTD_isError.restype = ctypes.c_uint
        size = decode(output, limit, data, len(data))
        if library.ZSTD_isError(size):
            raise ValueError("invalid Zstd stream")
        result = output.raw[:size]
    else:
        raise ValueError("unknown encoding")
pathlib.Path(target).write_bytes(result)
