#!/usr/bin/env python3
"""Create compressed fixtures using the installed codec libraries."""
import ctypes as c
import ctypes.util
import gzip
import pathlib
import sys
import zlib

encoding, source, target = sys.argv[1:]
data = pathlib.Path(source).read_bytes()
if encoding == "gzip":
    result = gzip.compress(data, mtime=0)
elif encoding == "deflate":
    result = zlib.compress(data)
elif encoding == "raw":
    obj = zlib.compressobj(wbits=-15)
    result = obj.compress(data) + obj.flush()
elif encoding == "br":
    lib = c.CDLL(ctypes.util.find_library("brotlienc"))
    lib.BrotliEncoderMaxCompressedSize.argtypes = [c.c_size_t]
    lib.BrotliEncoderMaxCompressedSize.restype = c.c_size_t
    size = c.c_size_t(lib.BrotliEncoderMaxCompressedSize(len(data)))
    output = c.create_string_buffer(size.value)
    lib.BrotliEncoderCompress.argtypes = [c.c_int, c.c_int, c.c_int, c.c_size_t,
                                        c.c_void_p, c.POINTER(c.c_size_t),
                                        c.c_void_p]
    assert lib.BrotliEncoderCompress(6, 19, 0, len(data), data,
                                    c.byref(size), output)
    result = output.raw[:size.value]
elif encoding == "zstd":
    lib = c.CDLL(ctypes.util.find_library("zstd"))
    lib.ZSTD_compressBound.argtypes = [c.c_size_t]
    lib.ZSTD_compressBound.restype = c.c_size_t
    size = lib.ZSTD_compressBound(len(data))
    output = c.create_string_buffer(size)
    lib.ZSTD_compress.argtypes = [c.c_void_p, c.c_size_t, c.c_void_p,
                                 c.c_size_t, c.c_int]
    lib.ZSTD_compress.restype = c.c_size_t
    lib.ZSTD_isError.argtypes = [c.c_size_t]
    written = lib.ZSTD_compress(output, size, data, len(data), 3)
    assert not lib.ZSTD_isError(written)
    result = output.raw[:written]
else:
    raise SystemExit("unknown encoding")
pathlib.Path(target).write_bytes(result)
