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

my $t = Test::Nginx->new()->has(qw/http/);
my $plain = join '', map { sprintf "%08x zstd window %c\n", $_, $_ % 251 }
    (0 .. 65535);
$t->write_file('body.txt', $plain);
my $block_plain = join '', map {
    '{"id":' . $_ . ',"value":"' . sha256_hex(pack 'N', $_) . '"}' . "\n"
} (0 .. 16383);
$t->write_file('block.json', $block_plain);
my $block_config = $ENV{TEST_NGINX_ZSTD_TARGET_BLOCK_SIZE} ? <<'EOF' : '';
        location /block/ {
            alias %%TESTDIR%%/;
            zstd_target_block_size 4k;
        }
        location /library/ {
            alias %%TESTDIR%%/;
            zstd_target_block_size 0;
        }
EOF
my $config = <<'EOF';
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

    zstd_buffers 2 256;
    output_buffers 1 8k;
    server {
        listen 127.0.0.1:8080;
        root %%TESTDIR%%;
        location / {}
        location /small/ {
            alias %%TESTDIR%%/;
            zstd_window 1k;
        }
        location /wide/ {
            alias %%TESTDIR%%/;
            zstd_window 8m;
        }
        location /negative/ {
            alias %%TESTDIR%%/;
            zstd_comp_level -1;
        }
        location /high/ {
            alias %%TESTDIR%%/;
            zstd_window 8m;
            zstd_comp_level 20;
        }
__BLOCK_CONFIG__
    }
}
EOF
$config =~ s/__BLOCK_CONFIG__/$block_config/;
write_config($t, $config);
$t->run();

my @requests = (
    ['/', 512 * 1024],
    ['/small/', 1024],
    ['/wide/', 8 * 1024 * 1024],
    ['/negative/', 512 * 1024],
    ['/high/', 8 * 1024 * 1024],
    ['/', 512 * 1024],
);
push @requests, ['/block/', 512 * 1024], ['/library/', 512 * 1024],
    ['/', 512 * 1024] if $ENV{TEST_NGINX_ZSTD_TARGET_BLOCK_SIZE};

for my $case (@requests) {
    my ($path, $window) = @$case;
    my $response = request($path . 'body.txt', 'zstd');
    check_response($t, $response, 'zstd', $plain, "zstd $path");
    $t->write_file('frame.zst', http_content($response));
    open my $probe, '-|', 'python3', '-B', "$FindBin::Bin/lib/zstd-frame.py",
        $t->testdir() . '/frame.zst' or die $!;
    my $json = do { local $/; <$probe> };
    close $probe;
    is($?, 0, 'libzstd accepts frame header');
    my $frame = decode_json($json);
    is($frame->{content_size}, length($plain), "$path exact content size");
    cmp_ok($frame->{window_size}, '<=', $window, "$path window limit");
}

if ($ENV{TEST_NGINX_ZSTD_TARGET_BLOCK_SIZE}) {
    my %bodies;
    for my $path ('/', '/block/', '/library/', '/') {
        my $response = request($path . 'block.json', 'zstd');
        check_response($t, $response, 'zstd', $block_plain,
            "zstd $path target block size");
        my $body = http_content($response);
        if (exists $bodies{$path}) {
            is($body, $bodies{$path}, 'default block size is restored between requests');
        }
        $bodies{$path} = $body;
    }
    isnt($bodies{'/block/'}, $bodies{'/library/'},
        'target block size changes the encoded stream');
    is($bodies{'/'}, $bodies{'/library/'},
        'default block size uses the library default');
}

$t->stop();
my $log = $t->read_file('error.log');
like($log, qr/zstd context reused/, 'completed contexts are reused');
like($log, qr/zstd context freed: \d{8,}/,
    'large workspaces are not retained');
unlike($log, qr/\[(?:alert|emerg)\]|Sanitizer|runtime error:/,
    'no zstd lifecycle errors');
undef $t;
done_testing();
