#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Nginx;
use FindBin;
use lib "$FindBin::Bin/lib";
use Compression;

plan skip_all => 'OpenResty is not enabled' unless $ENV{TEST_NGINX_OPENRESTY};

my $t = Test::Nginx->new()->has(qw/http/);
my $plain = 'Lua streaming response ' x 2048;
my $large = 'Lua streaming response ' x 262144;
write_config($t, <<'EOF');
%%TEST_GLOBALS%%
daemon off;
error_log %%TESTDIR%%/error.log debug;
events {}
http {
    %%TEST_GLOBALS_HTTP%%
    default_type text/plain;
    gzip off;
    zstd on;
    zstd_types *;
    zstd_min_length 0;
    zstd_http_version 1.0;

    zstd_buffers 2 32;
    server {
        listen 127.0.0.1:8080;
        location /stream {
            content_by_lua_block {
                ngx.flush(true)
                for i = 1, 8 do
                    ngx.print(string.rep("Lua streaming response ", 256))
                    ngx.flush(true)
                    ngx.flush(true)
                end
            }
        }
        location /body {
            content_by_lua_block {
                ngx.print(string.rep("Lua streaming response ", 2048))
            }
            body_filter_by_lua_block {
                ngx.arg[1] = string.gsub(ngx.arg[1], "Lua", "LUA")
            }
        }
        location /empty {
            content_by_lua_block {
                ngx.flush(true)
                ngx.flush(true)
            }
        }
        location /small {
            zstd_buffers 1 1;
            content_by_lua_block {
                ngx.print("small")
                ngx.flush(true)
                ngx.print(" buffer")
            }
        }
        location /large {
            content_by_lua_block {
                ngx.print(string.rep("Lua streaming response ", 262144))
                ngx.flush(true)
            }
        }
    }
}
EOF
$t->run();

for my $encoding (encodings()) {
    check_response($t, request('/stream', $encoding), $encoding, $plain,
        "$encoding Lua repeated flush");
    check_response($t, request('/body', $encoding), $encoding,
        $plain =~ s/Lua/LUA/gr, "$encoding after Lua body filter");
    check_response($t, request('/empty', $encoding), $encoding, '',
        "$encoding empty flush");
    check_response($t, request('/small', $encoding), $encoding, 'small buffer',
        "$encoding one-byte output buffer");
    check_response($t, request('/large', $encoding), $encoding, $large,
        "$encoding large Lua response");
}

$t->stop();
like($t->read_file('error.log'), qr/zstd filter yield/,
    'Lua compression yields');
unlike($t->read_file('error.log'), qr/\[(?:alert|emerg)\]|Sanitizer|runtime error:/,
    'no Lua filter lifecycle errors');
undef $t;
done_testing();
