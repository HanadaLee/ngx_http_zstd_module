#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Nginx;
use FindBin;
use lib "$FindBin::Bin/lib";
use Compression;

my $t = Test::Nginx->new()->has(qw/http/);
my $plain = 'compression policy response ' x 256;
$t->write_file('body.txt', $plain);
write_config($t, <<'EOF');
%%TEST_GLOBALS%%
daemon off;
events {}
http {
    %%TEST_GLOBALS_HTTP%%
    default_type text/plain;
    gzip off;
    zstd on;
    zstd_types *;
    zstd_min_length 0;

    server {
        listen 127.0.0.1:8080;
        root %%TESTDIR%%;
        location /plain/ {
            alias %%TESTDIR%%/;
            add_header Cache-Control public;
        }
        location /blocked/ {
            alias %%TESTDIR%%/;
            add_header Cache-Control 'public, no-transform';
        }
        location /mixed/ {
            alias %%TESTDIR%%/;
            add_header Cache-Control 'public, No-TrAnSfOrM';
        }
        location /duplicate/ {
            alias %%TESTDIR%%/;
            add_header Cache-Control public;
            add_header Cache-Control no-transform;
        }
        location /quoted/ {
            alias %%TESTDIR%%/;
            add_header Cache-Control 'extension="a, no-transform, b"';
        }
        location /quoted_then_blocked/ {
            alias %%TESTDIR%%/;
            add_header Cache-Control 'extension="a, b", no-transform';
        }
        location /prefix/ {
            alias %%TESTDIR%%/;
            add_header Cache-Control no-transform-extension;
        }
        location /argument/ {
            alias %%TESTDIR%%/;
            add_header Cache-Control no-transform=1;
        }
        location /multi {
            return 207 '<multistatus>one two three</multistatus>';
        }
    }
}
EOF
$t->run();

for my $encoding (encodings()) {
    for my $location (qw/plain quoted prefix/) {
        check_response($t, request("/$location/body.txt", $encoding),
            $encoding, $plain, "$encoding $location remains compressible");
    }
    for my $location (qw/blocked mixed duplicate quoted_then_blocked argument/) {
        check_response($t, request("/$location/body.txt", $encoding),
            undef, $plain, "$encoding $location no-transform");
    }

    my $response = request('/multi', $encoding);
    like($response, qr/^HTTP\/1\.1 207 /, "$encoding multi-status response");
    like($response, qr/^Content-Encoding: \Q$encoding\E\r?$/mi,
        "$encoding multi-status encoding");
    is(decoded($t, $response, '<multistatus>one two three</multistatus>'),
        '<multistatus>one two three</multistatus>',
        "$encoding multi-status round trip");
}

$t->stop();
unlike($t->read_file('error.log'), qr/\[(?:alert|emerg)\]|Sanitizer|runtime error:/,
    'no compression policy errors');
undef $t;
done_testing();
