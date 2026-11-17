use strict;
use warnings;

use Test::More;
use Test::Nginx qw/:DEFAULT http_content/;
use Digest::SHA qw/sha256_hex/;
use JSON::PP;
use FindBin;
use lib "$FindBin::Bin/lib";
use Compression;

my $t = Test::Nginx->new()->has(qw/http/)->has_daemon('zstd');
my $plain = join '', map { "dictionary-token $_ " . sha256_hex(pack 'N', $_) . "\n" }
    (0 .. 4095);
$t->write_file('body.txt', $plain);
$t->write_file('dict', substr($plain, 0, 16384));
my $conditional = $ENV{TEST_NGINX_EXPR}
    ? 'expr fast str_eq $arg_fast 1; when fast { zstd_comp_level -1; }' : '';
my $config = <<'EOF';
%%TEST_GLOBALS%%
daemon off;
events {}
http {
    %%TEST_GLOBALS_HTTP%%
    default_type text/plain;
    zstd_dict_file %%TESTDIR%%/dict;
    __CONDITIONAL__
    zstd on;
    zstd_types *;
    zstd_min_length 0;
    zstd_comp_level 3;
    zstd_window 1k;
    zstd_buffers 2 512;
    server {
        listen 127.0.0.1:8080;
        root %%TESTDIR%%;
        location / {}
        location /fast/ {
            alias %%TESTDIR%%/;
            zstd_comp_level -1;
        }
        location /wide/ {
            alias %%TESTDIR%%/;
            zstd_window 8m;
        }
    }
}
EOF
$config =~ s/__CONDITIONAL__/$conditional/;
write_config($t, $config);
$t->run();
my @cases = (['/body.txt', 1024], ['/fast/body.txt', 1024],
    ['/wide/body.txt', 8 * 1024 * 1024], ['/body.txt', 1024]);
push @cases, ['/body.txt?fast=1', 1024] if $ENV{TEST_NGINX_EXPR};
for my $case (@cases) {
    my ($path, $limit) = @$case;
    my $response = request($path, 'zstd');
    like($response, qr/^Content-Encoding: zstd\r?$/mi, "$path compressed");
    $t->write_file('response.zst', http_content($response));
    my $dir = $t->testdir();
    is(system('zstd', '-q', '-d', '-f', '-D', "$dir/dict", "$dir/response.zst",
        '-o', "$dir/decoded"), 0, "$path dictionary decode");
    is($t->read_file('decoded'), $plain, "$path dictionary round trip");
    open my $probe, '-|', 'python3', '-B', "$FindBin::Bin/lib/zstd-frame.py",
        "$dir/response.zst" or die $!;
    my $frame = decode_json(do { local $/; <$probe> });
    close $probe;
    cmp_ok($frame->{window_size}, '<=', $limit, "$path dictionary window");
    is($frame->{content_size}, length($plain), "$path dictionary source size");
}
$t->stop();
unlike($t->read_file('error.log'), qr/\[(?:alert|emerg)\]|Sanitizer|runtime error:/,
    'no dictionary lifecycle errors');
undef $t;
done_testing();
