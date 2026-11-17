use strict;
use warnings;

use Test::More;
use Test::Nginx qw/:DEFAULT http_content/;
use FindBin;
use lib "$FindBin::Bin/lib";
use Compression;

my $t = Test::Nginx->new()->has(qw/http/);
my $plain = 'feature and static response ' x 4096;
$t->write_file('body.txt', $plain);
is(system('python3', '-B', "$FindBin::Bin/lib/encode.py", 'zstd',
    $t->testdir() . '/body.txt', $t->testdir() . '/body.txt.zst'), 0,
    'precompressed fixture');
my $compressed = $t->read_file('body.txt.zst');
my $conditional = $ENV{TEST_NGINX_EXPR} ? <<'EOF' : '';
    expr skip str_eq $arg_skip 1;
    expr small str_eq $arg_small 1;
    expr fast str_eq $arg_fast 1;
    when skip {
        zstd_static off;
        zstd off;
    }
    when small { zstd_max_length 1; }
    when fast { zstd_comp_level -1; }
EOF
my $config = <<'EOF';
%%TEST_GLOBALS%%
daemon off;
events {}
http {
    %%TEST_GLOBALS_HTTP%%
    gzip off;
    gzip_vary on;
    default_type text/plain;
    zstd_min_length 0;
    zstd_types *;
    __CONDITIONAL__
    zstd on;
    zstd_static on;
    zstd_comp_level 3;
    server {
        listen 127.0.0.1:8080;
        root %%TESTDIR%%;
        location / { zstd_static off; }
        location /old/ {
            zstd_static off;
            alias %%TESTDIR%%/;
            zstd_http_version 1.0;
        }
        location /via/ {
            zstd_static off;
            alias %%TESTDIR%%/;
            zstd_proxied any;
        }
        location /agent/ {
            zstd_static off;
            alias %%TESTDIR%%/;
            zstd_disable BadAgent;
        }
        location /bypass/ {
            zstd_static off;
            alias %%TESTDIR%%/;
            zstd_bypass $arg_skip;
        }
        location /static/ {
            alias %%TESTDIR%%/;
            zstd off;
        }
        location /always/ {
            alias %%TESTDIR%%/;
            zstd off;
            zstd_static always;
        }
        location /direct/ {
            zstd_static off;
            alias %%TESTDIR%%/;
            zstd_comp_level -1;
        }
    }
}
EOF
$config =~ s/__CONDITIONAL__/$conditional/;
write_config($t, $config);
$t->run();
check_response($t, request('/body.txt', 'zstd'), 'zstd', $plain,
    'dynamic compression');
check_response($t, request('/body.txt', 'zstd', '', '1.0'), undef, $plain,
    'default HTTP version restriction');
check_response($t, request('/old/body.txt', 'zstd', '', '1.0'),
    'zstd', $plain, 'HTTP version alias');
check_response($t, request('/body.txt', 'zstd', "Via: 1.1 proxy\r\n"),
    undef, $plain, 'default proxy restriction');
check_response($t, request('/via/body.txt', 'zstd', "Via: 1.1 proxy\r\n"),
    'zstd', $plain, 'proxy alias');
check_response($t, request('/agent/body.txt', 'zstd', "User-Agent: BadAgent\r\n"),
    undef, $plain, 'client restriction alias');
check_response($t, request('/bypass/body.txt?skip=1', 'zstd'),
    undef, $plain, 'bypass predicate');
my $response = request('/static/body.txt', 'zstd');
check_response($t, $response, 'zstd', $plain, 'static file');
is(http_content($response), $compressed, 'static bytes are unchanged');
check_response($t, request('/static/body.txt', 'identity'), undef, $plain,
    'static identity fallback');
check_response($t, request('/always/body.txt', 'identity'), 'zstd', $plain,
    'static always');
my ($etag) = $response =~ /^ETag: ([^\r\n]+)/mi;
like(request('/static/body.txt', 'zstd', "If-None-Match: $etag\r\n"),
    qr/^HTTP\/1.1 304 /, 'static conditional response');
$response = request('/static/body.txt', 'zstd', "Range: bytes=0-9\r\n");
like($response, qr/^HTTP\/1.1 206 /, 'encoded byte range');
is(http_content($response), substr($compressed, 0, 10), 'encoded byte range data');
if ($ENV{TEST_NGINX_EXPR}) {
    check_response($t, request('/body.txt?skip=1', 'zstd'), undef, $plain,
        'conditional dynamic disable');
    check_response($t, request('/static/body.txt?skip=1', 'zstd'), undef, $plain,
        'conditional static disable');
    check_response($t, request('/body.txt?small=1', 'zstd'), undef, $plain,
        'conditional maximum length');
    is(http_content(request('/body.txt?fast=1', 'zstd')),
        http_content(request('/direct/body.txt', 'zstd')),
        'conditional compression level matches a direct setting');
}
$t->stop();
unlike($t->read_file('error.log'), qr/\[(?:alert|emerg)\]|Sanitizer|runtime error:/,
    'no policy or static errors');
undef $t;
done_testing();
