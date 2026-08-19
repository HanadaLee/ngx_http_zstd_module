#!/usr/bin/env python3
from __future__ import annotations

import argparse
import concurrent.futures
import ctypes
import ctypes.util
import os
import pathlib
import random
import shutil
import socket
import socketserver
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request


SIZES = (
    0,
    1,
    1023,
    1024,
    1025,
    65535,
    131071,
    131072,
    131073,
    1024 * 1024,
)
KINDS = ('repeat', 'random')


class ZstdInBuffer(ctypes.Structure):
    _fields_ = (
        ('src', ctypes.c_void_p),
        ('size', ctypes.c_size_t),
        ('pos', ctypes.c_size_t),
    )


class ZstdOutBuffer(ctypes.Structure):
    _fields_ = (
        ('dst', ctypes.c_void_p),
        ('size', ctypes.c_size_t),
        ('pos', ctypes.c_size_t),
    )


class ZstdCodec:
    def __init__(self) -> None:
        library_name = ctypes.util.find_library('zstd')
        if not library_name:
            raise RuntimeError('libzstd is not available')

        self.lib = ctypes.CDLL(library_name)
        self.lib.ZSTD_createDStream.restype = ctypes.c_void_p
        self.lib.ZSTD_freeDStream.argtypes = (ctypes.c_void_p,)
        self.lib.ZSTD_freeDStream.restype = ctypes.c_size_t
        self.lib.ZSTD_initDStream.argtypes = (ctypes.c_void_p,)
        self.lib.ZSTD_initDStream.restype = ctypes.c_size_t
        self.lib.ZSTD_DStreamOutSize.restype = ctypes.c_size_t
        self.lib.ZSTD_decompressStream.argtypes = (
            ctypes.c_void_p,
            ctypes.POINTER(ZstdOutBuffer),
            ctypes.POINTER(ZstdInBuffer),
        )
        self.lib.ZSTD_decompressStream.restype = ctypes.c_size_t
        self.lib.ZSTD_isError.argtypes = (ctypes.c_size_t,)
        self.lib.ZSTD_isError.restype = ctypes.c_uint
        self.lib.ZSTD_getErrorName.argtypes = (ctypes.c_size_t,)
        self.lib.ZSTD_getErrorName.restype = ctypes.c_char_p
        self.lib.ZSTD_compressBound.argtypes = (ctypes.c_size_t,)
        self.lib.ZSTD_compressBound.restype = ctypes.c_size_t
        self.lib.ZSTD_compress.argtypes = (
            ctypes.c_void_p,
            ctypes.c_size_t,
            ctypes.c_void_p,
            ctypes.c_size_t,
            ctypes.c_int,
        )
        self.lib.ZSTD_compress.restype = ctypes.c_size_t

    def check(self, result: int) -> int:
        if self.lib.ZSTD_isError(result):
            message = self.lib.ZSTD_getErrorName(result).decode('utf-8')
            raise RuntimeError(f'zstd operation failed: {message}')
        return result

    def compress(self, data: bytes) -> bytes:
        source = ctypes.create_string_buffer(data)
        destination = ctypes.create_string_buffer(
            self.lib.ZSTD_compressBound(len(data))
        )
        result = self.check(
            self.lib.ZSTD_compress(
                destination,
                len(destination),
                source,
                len(data),
                1,
            )
        )
        return destination.raw[:result]

    def decompress(self, compressed: bytes) -> bytes:
        if compressed[:4] != b'\x28\xb5\x2f\xfd':
            raise RuntimeError(
                f'missing zstd frame magic: {compressed[:8].hex()}'
            )

        stream = self.lib.ZSTD_createDStream()
        if not stream:
            raise RuntimeError('ZSTD_createDStream() failed')

        try:
            self.check(self.lib.ZSTD_initDStream(stream))
            source = ctypes.create_string_buffer(compressed)
            input_buffer = ZstdInBuffer(
                ctypes.cast(source, ctypes.c_void_p), len(compressed), 0
            )
            output_size = max(1, self.lib.ZSTD_DStreamOutSize())
            decoded = bytearray()
            remaining = 1

            while input_buffer.pos < input_buffer.size or remaining != 0:
                output = ctypes.create_string_buffer(output_size)
                output_buffer = ZstdOutBuffer(
                    ctypes.cast(output, ctypes.c_void_p), output_size, 0
                )
                input_before = input_buffer.pos
                remaining = self.check(
                    self.lib.ZSTD_decompressStream(
                        stream,
                        ctypes.byref(output_buffer),
                        ctypes.byref(input_buffer),
                    )
                )
                decoded.extend(output.raw[:output_buffer.pos])

                if (
                    input_buffer.pos == input_before
                    and output_buffer.pos == 0
                    and remaining != 0
                ):
                    raise RuntimeError('zstd decoder made no progress')

            return bytes(decoded)
        finally:
            self.check(self.lib.ZSTD_freeDStream(stream))


def make_payload(kind: str, size: int) -> bytes:
    prefix = f'{kind}:{size}:'.encode('ascii')
    if kind == 'repeat':
        return (prefix + b'abcdefghijklmnopqrstuvwxyz0123456789' * (size // 36 + 1))[:size]

    randomizer = random.Random(size ^ 0x5A17D00D)
    return randomizer.randbytes(size)


class FixtureHandler(socketserver.BaseRequestHandler):
    fixtures: dict[tuple[str, int], bytes] = {}

    def handle(self) -> None:
        request = bytearray()
        while b'\r\n\r\n' not in request and len(request) < 65536:
            chunk = self.request.recv(4096)
            if not chunk:
                return
            request.extend(chunk)

        try:
            request_line = bytes(request).split(b'\r\n', 1)[0]
            target = request_line.split(b' ', 2)[1]
            name = target.split(b'?', 1)[0].removeprefix(b'/payload/')
            kind, size_text = name.rsplit(b'-', 1)
            key = (kind.decode('ascii'), int(size_text))
            payload = self.fixtures[key]
        except (IndexError, KeyError, UnicodeDecodeError, ValueError):
            self.request.sendall(
                b'HTTP/1.1 404 Not Found\r\n'
                b'Content-Length: 0\r\n'
                b'Connection: close\r\n\r\n'
            )
            return

        response = bytearray(
            b'HTTP/1.1 200 OK\r\n'
            b'Content-Type: application/octet-stream\r\n'
            + f'Content-Length: {len(payload)}\r\n'.encode('ascii')
            + b'Connection: close\r\n\r\n'
        )
        response.extend(payload)
        self.request.sendall(response)


class ThreadingServer(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True


def free_port() -> int:
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        return probe.getsockname()[1]


def wait_for_port(port: int, timeout: float = 10.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(('127.0.0.1', port), timeout=0.2):
                return
        except OSError:
            time.sleep(0.05)
    raise RuntimeError(f'nginx did not listen on 127.0.0.1:{port}')


def detect_modules(nginx_binary: pathlib.Path) -> list[pathlib.Path]:
    modules = []
    for name in (
        'ngx_http_perl_module.so',
        'ngx_http_zstd_filter_module.so',
        'ngx_http_zstd_static_module.so',
    ):
        candidate = nginx_binary.parent / name
        if candidate.exists():
            modules.append(candidate)
    return modules


def supports_http2(nginx_binary: pathlib.Path) -> bool:
    result = subprocess.run(
        [str(nginx_binary), '-V'],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    return '--with-http_v2_module' in result.stdout


def supports_perl(nginx_binary: pathlib.Path) -> bool:
    result = subprocess.run(
        [str(nginx_binary), '-V'],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    return '--with-http_perl_module' in result.stdout


def find_perl_module_paths(
    nginx_binary: pathlib.Path,
) -> list[pathlib.Path]:
    blib = nginx_binary.parent / 'src/http/modules/perl/blib'
    paths = [blib / 'lib', blib / 'arch']
    return paths if all(path.is_dir() for path in paths) else []


def find_http2_curl() -> str | None:
    curl = shutil.which('curl')
    if curl is None:
        return None

    result = subprocess.run(
        [curl, '-V'],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    return curl if 'HTTP2' in result.stdout else None


def write_config(
    path: pathlib.Path,
    prefix: pathlib.Path,
    fixture_root: pathlib.Path,
    listen_port: int,
    http2_port: int | None,
    perl_enabled: bool,
    perl_module_paths: list[pathlib.Path],
    backend_socket: pathlib.Path,
    modules: list[pathlib.Path],
) -> None:
    load_modules = ''.join(f'load_module {module};\n' for module in modules)
    http2_listen = (
        f'        listen 127.0.0.1:{http2_port} http2;\n'
        if http2_port is not None
        else ''
    )
    perl_location = '''
        location = /flush {
            zstd on;
            zstd_min_length 0;
            zstd_types *;
            perl 'sub {
                my $r = shift;
                $r->send_http_header("text/html");
                return OK if $r->header_only;
                $r->print("DA");
                $r->flush();
                $r->flush();
                $r->print("TA");
                return OK;
            }';
        }
''' if perl_enabled else ''
    perl_modules = ''.join(
        f'    perl_modules {module_path};\n'
        for module_path in perl_module_paths
    )
    path.write_text(
        f'''{load_modules}worker_processes 1;
 error_log {prefix / "error.log"} info;
pid {prefix / "nginx.pid"};

events {{
    worker_connections 256;
}}

http {{
    access_log off;
    default_type application/octet-stream;
    sendfile off;
{perl_modules}

    charset_map B A {{
        58 59;
    }}

    server {{
        listen 127.0.0.1:{listen_port};
{http2_listen}        server_name localhost;

        location /known/ {{
            alias {fixture_root}/;
            zstd on;
            zstd_min_length 0;
            zstd_types *;
            zstd_buffers 2 1k;
        }}

        location /transformed/ {{
            alias {fixture_root}/;
            ssi on;
            ssi_types *;
            zstd on;
            zstd_min_length 0;
            zstd_types *;
            zstd_buffers 2 1k;
        }}

        location /ssi/ {{
            alias {fixture_root}/ssi/;
            ssi on;
            ssi_types *;
            zstd on;
            zstd_min_length 0;
            zstd_types *;
            zstd_buffers 2 1k;
        }}

        location /static-recode/ {{
            alias {fixture_root}/;
            zstd_static on;
            default_type text/html;
            charset A;
            source_charset B;
        }}

        location /static-charset/ {{
            alias {fixture_root}/;
            zstd_static on;
            default_type text/html;
            charset A;
            source_charset A;
        }}
{perl_location}

        location /buffered/ {{
            proxy_pass http://unix:{backend_socket}:/payload/;
            proxy_set_header Connection close;
            zstd on;
            zstd_min_length 0;
            zstd_types *;
            zstd_buffers 2 1k;
        }}

        location /streamed/ {{
            proxy_pass http://unix:{backend_socket}:/payload/;
            proxy_set_header Connection close;
            proxy_buffering off;
            zstd on;
            zstd_min_length 0;
            zstd_types *;
            zstd_buffers 2 1k;
        }}
    }}
}}
''',
        encoding='utf-8',
    )


def fetch(
    port: int, path: str, accept_encoding: str | None
) -> tuple[bytes, dict[str, str]]:
    headers = {'Connection': 'close', 'User-Agent': 'zstd-roundtrip-test'}
    if accept_encoding is not None:
        headers['Accept-Encoding'] = accept_encoding

    request = urllib.request.Request(
        f'http://127.0.0.1:{port}{path}', headers=headers
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            body = response.read()
            response_headers = {
                name.lower(): value.strip()
                for name, value in response.headers.items()
            }
    except (OSError, urllib.error.URLError) as error:
        raise RuntimeError(f'{path}: request failed: {error}') from error
    return body, response_headers


def fetch_http2(
    curl: str,
    port: int,
    path: str,
    accept_encoding: str | None,
) -> tuple[bytes, dict[str, str]]:
    with tempfile.TemporaryDirectory(prefix='ngx-zstd-curl-') as temp:
        output = pathlib.Path(temp) / 'body'
        header_output = pathlib.Path(temp) / 'headers'
        command = [
            curl,
            '--silent',
            '--show-error',
            '--http2-prior-knowledge',
            '--raw',
            '--output', str(output),
            '--dump-header', str(header_output),
            '--header', 'Connection:',
        ]
        if accept_encoding is not None:
            command.extend(['--header', f'Accept-Encoding: {accept_encoding}'])
        command.append(f'http://127.0.0.1:{port}{path}')

        result = subprocess.run(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
            timeout=20,
        )
        if result.returncode != 0:
            raise RuntimeError(
                f'{path}: HTTP/2 request failed: {result.stdout.strip()}'
            )

        blocks = [
            block
            for block in header_output.read_bytes().split(b'\r\n\r\n')
            if block.startswith(b'HTTP/')
        ]
        if not blocks:
            raise RuntimeError(f'{path}: HTTP/2 response had no headers')

        response_headers = {}
        for line in blocks[-1].split(b'\r\n')[1:]:
            if b':' not in line:
                continue
            name, value = line.split(b':', 1)
            response_headers[name.decode('ascii').lower()] = (
                value.decode('latin1').strip()
            )

        return output.read_bytes(), response_headers


def validate(
    codec: ZstdCodec,
    port: int,
    path: str,
    expected: bytes,
    accept_zstd: bool,
    expected_content_type: str | None = None,
    http2_curl: str | None = None,
) -> None:
    accept_encoding = 'zstd' if accept_zstd else None
    if http2_curl is None:
        body, headers = fetch(port, path, accept_encoding)
    else:
        body, headers = fetch_http2(
            http2_curl, port, path, accept_encoding
        )

    encoding = headers.get('content-encoding', '').lower()
    if accept_zstd:
        if encoding != 'zstd':
            raise RuntimeError(f'{path}: expected zstd, got {encoding!r}')
        actual = codec.decompress(body)
    else:
        if encoding:
            raise RuntimeError(f'{path}: expected identity, got {encoding!r}')
        actual = body

    if expected_content_type is not None:
        content_type = headers.get('content-type', '')
        if content_type != expected_content_type:
            raise RuntimeError(
                f'{path}: got Content-Type {content_type!r}, '
                f'expected {expected_content_type!r}'
            )

    if actual != expected:
        raise RuntimeError(
            f'{path}: body mismatch, got {len(actual)}, expected {len(expected)}'
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument('--nginx-binary', required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    nginx_binary = pathlib.Path(args.nginx_binary).resolve()
    if not nginx_binary.exists():
        raise FileNotFoundError(nginx_binary)

    codec = ZstdCodec()
    fixtures = {
        (kind, size): make_payload(kind, size)
        for kind in KINDS
        for size in SIZES
    }
    FixtureHandler.fixtures = fixtures

    listen_port = free_port()
    http2_curl = (
        find_http2_curl() if supports_http2(nginx_binary) else None
    )
    http2_port = free_port() if http2_curl is not None else None
    perl_enabled = supports_perl(nginx_binary)
    perl_module_paths = find_perl_module_paths(nginx_binary)
    backend_temp = tempfile.TemporaryDirectory(prefix='ngx-zstd-backend-')
    backend_socket = pathlib.Path(backend_temp.name) / 'backend.sock'
    backend = ThreadingServer(str(backend_socket), FixtureHandler)
    backend_thread = threading.Thread(target=backend.serve_forever, daemon=True)
    backend_thread.start()

    os.umask(0o022)
    try:
        with tempfile.TemporaryDirectory(prefix='ngx-zstd-roundtrip-') as temp:
            os.chmod(temp, 0o755)
            prefix = pathlib.Path(temp)
            fixture_root = prefix / 'fixtures'
            fixture_root.mkdir()

            for (kind, size), payload in fixtures.items():
                (fixture_root / f'{kind}-{size}').write_bytes(payload)

            ssi_root = fixture_root / 'ssi'
            ssi_root.mkdir()
            ssi_cases = {
                f'include-{size}': fixtures[('repeat', size)]
                for size in (1023, 1024, 1025)
            }
            for name in ssi_cases:
                size = int(name.rsplit('-', 1)[1])
                (ssi_root / name).write_text(
                    f'<!--# include virtual="/known/repeat-{size}" -->',
                    encoding='ascii',
                )

            ssi_cases['empty-subrequests'] = b'DATA'
            (ssi_root / 'empty-subrequests').write_text(
                'DA<!--# include virtual="/known/repeat-0" -->'
                '<!--# include virtual="/known/repeat-0" -->TA',
                encoding='ascii',
            )

            charset_source = b'X' * 99
            (fixture_root / 'charset').write_bytes(charset_source)
            (fixture_root / 'charset.zst').write_bytes(
                codec.compress(charset_source)
            )

            config = prefix / 'nginx.conf'
            write_config(
                config,
                prefix,
                fixture_root,
                listen_port,
                http2_port,
                perl_enabled,
                perl_module_paths,
                backend_socket,
                detect_modules(nginx_binary),
            )

            process = subprocess.Popen(
                [
                    str(nginx_binary),
                    '-p', str(prefix),
                    '-c', str(config),
                    '-g', 'daemon off; master_process off;',
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
            )

            failure = None
            try:
                wait_for_port(listen_port)
                checked = 0
                for mode in ('known', 'transformed', 'buffered', 'streamed'):
                    for (kind, size), payload in fixtures.items():
                        if mode in ('buffered', 'streamed') and size > 65535:
                            continue
                        suffix = f'{kind}-{size}'
                        path = f'/{mode}/{suffix}'
                        validate(codec, listen_port, path, payload, True)
                        validate(codec, listen_port, path, payload, False)
                        checked += 2

                for name, payload in ssi_cases.items():
                    path = f'/ssi/{name}'
                    validate(codec, listen_port, path, payload, True)
                    validate(codec, listen_port, path, payload, False)
                    checked += 2

                validate(
                    codec,
                    listen_port,
                    '/static-recode/charset',
                    charset_source,
                    True,
                    'text/html',
                )
                validate(
                    codec,
                    listen_port,
                    '/static-recode/charset',
                    b'Y' * 99,
                    False,
                    'text/html; charset=A',
                )
                validate(
                    codec,
                    listen_port,
                    '/static-charset/charset',
                    charset_source,
                    True,
                    'text/html; charset=A',
                )
                validate(
                    codec,
                    listen_port,
                    '/static-charset/charset',
                    charset_source,
                    False,
                    'text/html; charset=A',
                )
                checked += 4

                if perl_enabled:
                    validate(codec, listen_port, '/flush', b'DATA', True)
                    validate(codec, listen_port, '/flush', b'DATA', False)
                    checked += 2

                if http2_port is not None and http2_curl is not None:
                    h2_path = '/transformed/random-131073'
                    h2_body = fixtures[('random', 131073)]
                    validate(
                        codec,
                        http2_port,
                        h2_path,
                        h2_body,
                        True,
                        http2_curl=http2_curl,
                    )
                    validate(
                        codec,
                        http2_port,
                        h2_path,
                        h2_body,
                        False,
                        http2_curl=http2_curl,
                    )
                    checked += 2

                concurrent_path = '/transformed/random-131073'
                concurrent_body = fixtures[('random', 131073)]
                with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                    futures = [
                        pool.submit(
                            validate,
                            codec,
                            listen_port,
                            concurrent_path,
                            concurrent_body,
                            True,
                        )
                        for _ in range(16)
                    ]
                    for future in futures:
                        future.result()
                    checked += len(futures)

                error_log = (prefix / 'error.log').read_text(
                    encoding='utf-8', errors='replace'
                )
                for forbidden in (
                    'zero size buf',
                    'ZSTD_compressStream2() failed',
                    'ZSTD_freeCStream() failed',
                ):
                    if forbidden in error_log:
                        raise RuntimeError(f'nginx logged {forbidden!r}')

                print(f'OK: {checked} byte-exact round-trip checks passed')
            except Exception as error:
                failure = error
                raise
            finally:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=10)

                if process.returncode not in (0, -15):
                    output = process.stdout.read() if process.stdout else ''
                    raise RuntimeError(f'nginx exited with {process.returncode}: {output}')

                if failure is not None:
                    error_log = prefix / 'error.log'
                    if error_log.exists():
                        print(error_log.read_text(
                            encoding='utf-8', errors='replace'
                        ))
    finally:
        backend.shutdown()
        backend.server_close()
        backend_temp.cleanup()

    return 0


if __name__ == '__main__':
    raise SystemExit(main())
