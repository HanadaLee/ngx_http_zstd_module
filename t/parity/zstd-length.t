#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Nginx qw/:DEFAULT http_content/;
use JSON::PP;
use Digest::SHA qw/sha256_hex/;
use FindBin;
use lib "$FindBin::Bin/lib";
use Compression;

plan skip_all => 'requires zstd' unless grep { $_ eq 'zstd' } encodings();

my $t = Test::Nginx->new()->has(qw/http proxy sub/);
my $plain = join '', map {
    sprintf "zstd %08x %s\n", $_, sha256_hex(pack 'N', $_)
} (0 .. 8191);
my $changed = $plain;
$changed =~ s/zstd/zstandard replacement/g;
my $small = 'small source length ' x 128;
$t->write_file('stream-body', $plain);
$t->write_file('body.txt', $plain);
$t->write_file('small.txt', $small);
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

    zstd_buffers 2 512;
    server {
        listen 127.0.0.1:8080;
        root %%TESTDIR%%;
        location / {}
        location /on/ {
            proxy_pass http://127.0.0.1:8081;
            proxy_buffering on;
        }
        location /off/ {
            proxy_pass http://127.0.0.1:8081;
            proxy_buffering off;
        }
        location /postpone/ {
            proxy_pass http://127.0.0.1:8081;
            proxy_buffering off;
            zstd_postpone 64k;
        }
        location /rewrite/ {
            proxy_pass http://127.0.0.1:8081;
            proxy_buffering off;
            sub_filter_types *;
            sub_filter zstd 'zstandard replacement';
            sub_filter_once off;
        }
    }
}
EOF
$t->run_daemon(\&origin, port(8081), $t->testdir());
$t->waitforsocket('127.0.0.1:' . port(8081));
$t->run();

my $number = 0;
for my $location ('on', 'off', 'postpone') {
    for my $known (1, 0, 1) {
        my $key = 'length_' . ++$number;
        $t->write_file("release-$key", '1');
        my $response = request("/$location/?id=$key&known=$known", 'zstd');
        check_response($t, $response, 'zstd', $plain,
            "$location known=$known");
        is(content_size($response), $known ? length($plain) : undef,
            "$location known=$known frame content size");

        $response = request('/small.txt', 'zstd');
        check_response($t, $response, 'zstd', $small,
            'small response after context reuse');
        is(content_size($response), length($small),
            'context reuse replaces the previous content size');
    }
}

$t->write_file('release-rewrite', '1');
my $response = request('/rewrite/?id=rewrite&known=1', 'zstd');
check_response($t, $response, 'zstd', $changed, 'rewritten response');
is(content_size($response), undef,
    'sub_filter removes the obsolete source length');
$response = request('/body.txt', 'zstd');
check_response($t, $response, 'zstd', $plain, 'known size after rewriting');
is(content_size($response), length($plain),
    'next response restores its own content size');

$t->stop();
like($t->read_file('error.log'), qr/zstd context reused/,
    'known and unknown lengths exercise context reuse');
unlike($t->read_file('error.log'),
    qr/\[(?:alert|emerg)\]|Sanitizer|runtime error:/,
    'no length or streaming lifecycle errors');
undef $t;
done_testing();

sub content_size {
    my ($response) = @_;
    $t->write_file('frame.zst', http_content($response));
    open my $probe, '-|', 'python3', '-B', "$FindBin::Bin/lib/zstd-frame.py",
        $t->testdir() . '/frame.zst' or die $!;
    my $json = do { local $/; <$probe> };
    close $probe;
    is($?, 0, 'libzstd accepts frame header');
    return decode_json($json)->{content_size};
}

sub origin {
    my ($port, $directory) = @_;
    exec 'python3', '-B', "$FindBin::Bin/lib/origin.py", $port, $directory;
    die "origin exec: $!";
}
