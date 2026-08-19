use Test::Nginx::Socket;
use File::Basename qw(dirname);
use Cwd qw(abs_path);

use lib 'lib';

my $test_dir = abs_path(dirname(__FILE__));
$ENV{'TEST_NGINX_PERL_PATH'} = $test_dir;

my @dynamic_modules;
if (defined $ENV{'TEST_NGINX_BINARY'}) {
    my $nginx_dir = dirname($ENV{'TEST_NGINX_BINARY'});

    for my $module_name (qw(
        ngx_http_zstd_filter_module.so
        ngx_http_zstd_static_module.so
    )) {
        my $module_path = "$nginx_dir/$module_name";
        push @dynamic_modules, $module_path if -f $module_path;
    }
}

add_block_preprocessor(sub {
    my $block = shift;
    return if !@dynamic_modules;

    my $main_config = join "\n", map { "load_module $_;" } @dynamic_modules;
    $block->set_value('main_config', $main_config);
});

no_long_string();
no_shuffle();
log_level 'debug';
repeat_each(1);
plan 'no_plan';
run_tests();


__DATA__


=== TEST 1: zstd_static off serves the original file
--- config
    location /test {
        zstd_static off;
        root $TEST_NGINX_PERL_PATH/suite;
    }
--- request
GET /test
--- more_headers
Accept-Encoding: zstd
--- response_headers
!Content-Encoding
--- response_headers_like
Content-Length: \d+
--- no_error_log
[error]



=== TEST 2: zstd_static on requires Accept-Encoding
--- config
    location /test {
        zstd_static on;
        root $TEST_NGINX_PERL_PATH/suite;
    }
--- request
GET /test
--- response_headers
!Content-Encoding
--- no_error_log
[error]



=== TEST 3: unrelated encodings serve the original file
--- config
    location /test {
        zstd_static on;
        root $TEST_NGINX_PERL_PATH/suite;
    }
--- request
GET /test
--- more_headers
Accept-Encoding: gzip, br
--- response_headers
!Content-Encoding
--- no_error_log
[error]



=== TEST 4: accepted zstd serves the precompressed file
--- config
    location /test {
        zstd_static on;
        root $TEST_NGINX_PERL_PATH/suite;
    }
--- request
GET /test
--- more_headers
Accept-Encoding: zstd
--- response_headers
Content-Encoding: zstd
--- response_headers_like
Content-Length: \d+
--- response_body_like: ^\x28\xb5\x2f\xfd
--- no_error_log
[error]



=== TEST 5: mixed Accept-Encoding list serves zstd
--- config
    location /test {
        zstd_static on;
        root $TEST_NGINX_PERL_PATH/suite;
    }
--- request
GET /test
--- more_headers
Accept-Encoding: gzip, br, zstd
--- response_headers
Content-Encoding: zstd
--- response_body_like: ^\x28\xb5\x2f\xfd
--- no_error_log
[error]



=== TEST 6: q=0 rejects the precompressed file
--- config
    location /test {
        zstd_static on;
        root $TEST_NGINX_PERL_PATH/suite;
    }
--- request
GET /test
--- more_headers
Accept-Encoding: zstd;q=0
--- response_headers
!Content-Encoding
--- no_error_log
[error]



=== TEST 7: smallest positive qvalue accepts the precompressed file
--- config
    location /test {
        zstd_static on;
        root $TEST_NGINX_PERL_PATH/suite;
    }
--- request
GET /test
--- more_headers
Accept-Encoding: zstd;q=0.001
--- response_headers
Content-Encoding: zstd
--- response_body_like: ^\x28\xb5\x2f\xfd
--- no_error_log
[error]



=== TEST 8: qvalue above one rejects the precompressed file
--- config
    location /test {
        zstd_static on;
        root $TEST_NGINX_PERL_PATH/suite;
    }
--- request
GET /test
--- more_headers
Accept-Encoding: zstd;q=1.001
--- response_headers
!Content-Encoding
--- no_error_log
[error]



=== TEST 9: coding name is case-insensitive
--- config
    location /test {
        zstd_static on;
        root $TEST_NGINX_PERL_PATH/suite;
    }
--- request
GET /test
--- more_headers
Accept-Encoding: ZSTD
--- response_headers
Content-Encoding: zstd
--- no_error_log
[error]



=== TEST 10: wildcard follows official gzip parser behavior
--- config
    location /test {
        zstd_static on;
        root $TEST_NGINX_PERL_PATH/suite;
    }
--- request
GET /test
--- more_headers
Accept-Encoding: *
--- response_headers
!Content-Encoding
--- no_error_log
[error]



=== TEST 11: first explicit q=0 occurrence wins like gzip
--- config
    location /test {
        zstd_static on;
        root $TEST_NGINX_PERL_PATH/suite;
    }
--- request
GET /test
--- more_headers
Accept-Encoding: zstd;q=0, zstd
--- response_headers
!Content-Encoding
--- no_error_log
[error]



=== TEST 12: always ignores a missing Accept-Encoding header
--- config
    location /test {
        zstd_static always;
        root $TEST_NGINX_PERL_PATH/suite;
    }
--- request
GET /test
--- response_headers
Content-Encoding: zstd
--- response_body_like: ^\x28\xb5\x2f\xfd
--- no_error_log
[error]



=== TEST 13: always ignores q=0
--- config
    location /test {
        zstd_static always;
        root $TEST_NGINX_PERL_PATH/suite;
    }
--- request
GET /test
--- more_headers
Accept-Encoding: zstd;q=0
--- response_headers
Content-Encoding: zstd
--- response_body_like: ^\x28\xb5\x2f\xfd
--- no_error_log
[error]



=== TEST 14: HEAD advertises the precompressed representation
--- config
    location /test {
        zstd_static on;
        root $TEST_NGINX_PERL_PATH/suite;
    }
--- request
HEAD /test
--- more_headers
Accept-Encoding: zstd
--- response_headers
Content-Encoding: zstd
--- response_headers_like
Content-Length: \d+
--- response_body
--- no_error_log
[error]



=== TEST 15: POST is declined by zstd_static
--- config
    location /test {
        zstd_static on;
        root $TEST_NGINX_PERL_PATH/suite;
    }
--- request
POST /test
--- more_headers
Accept-Encoding: zstd
--- error_code: 405
--- response_headers
!Content-Encoding
--- no_error_log
[error]



=== TEST 16: missing original and precompressed files return 404
--- config
    location /does-not-exist {
        zstd_static always;
        root $TEST_NGINX_PERL_PATH/suite;
    }
--- request
GET /does-not-exist
--- error_code: 404
--- response_headers
!Content-Encoding



=== TEST 17: missing precompressed file falls back to the original
--- config
    location /plain {
        zstd_static on;
        root $TEST_NGINX_PERL_PATH/suite;
    }
--- request
GET /plain
--- more_headers
Accept-Encoding: zstd
--- response_headers
!Content-Encoding
Content-Type: text/plain
--- response_body_like: ^plain file without a precompressed sibling\n?$
--- no_error_log
[error]



=== TEST 18: directory-style URI is not handled as a zstd file
--- config
    location /dir/ {
        zstd_static always;
        autoindex off;
        alias $TEST_NGINX_PERL_PATH/suite/;
    }
--- request
GET /dir/
--- error_code: 403
--- response_headers
!Content-Encoding



=== TEST 19: gzip_vary marks an encoded response
--- config
    gzip_vary on;
    location /test {
        zstd_static on;
        root $TEST_NGINX_PERL_PATH/suite;
    }
--- request
GET /test
--- more_headers
Accept-Encoding: zstd
--- response_headers
Content-Encoding: zstd
Vary: Accept-Encoding
--- no_error_log
[error]



=== TEST 20: gzip_vary marks identity fallback
--- config
    gzip_vary on;
    location /test {
        zstd_static on;
        root $TEST_NGINX_PERL_PATH/suite;
    }
--- request
GET /test
--- more_headers
Accept-Encoding: gzip
--- response_headers
!Content-Encoding
Vary: Accept-Encoding
--- no_error_log
[error]



=== TEST 21: always does not add Vary
--- config
    gzip_vary on;
    location /test {
        zstd_static always;
        root $TEST_NGINX_PERL_PATH/suite;
    }
--- request
GET /test
--- more_headers
Accept-Encoding: gzip
--- response_headers
Content-Encoding: zstd
!Vary
--- no_error_log
[error]



=== TEST 22: gzip-only client can use gzip fallback
--- config
    location /test {
        zstd_static on;
        gzip on;
        gzip_min_length 1;
        gzip_types text/plain;
        root $TEST_NGINX_PERL_PATH/suite;
    }
--- request
GET /test
--- more_headers
Accept-Encoding: gzip
--- response_headers
Content-Encoding: gzip
--- response_body_like: ^\x1f\x8b
--- no_error_log
[error]



=== TEST 23: byte range is served from the precompressed file
--- config
    location /test {
        zstd_static on;
        root $TEST_NGINX_PERL_PATH/suite;
    }
--- request
GET /test
--- more_headers
Accept-Encoding: zstd
Range: bytes=0-15
--- error_code: 206
--- response_headers
Content-Encoding: zstd
Content-Length: 16
--- response_headers_like
Content-Range: bytes 0-15/\d+
--- response_body_like: ^\x28\xb5\x2f\xfd
--- no_error_log
[error]



=== TEST 24: filter does not encode an already precompressed response twice
--- config
    location /test {
        zstd_static on;
        zstd on;
        zstd_min_length 1;
        zstd_types text/plain;
        root $TEST_NGINX_PERL_PATH/suite;
    }
--- request
GET /test
--- more_headers
Accept-Encoding: zstd
--- response_headers
Content-Encoding: zstd
--- raw_response_headers_unlike: Content-Encoding: zstd\r?\n(?:.*\r?\n)*Content-Encoding: zstd
--- response_body_like: ^\x28\xb5\x2f\xfd
--- no_error_log
[error]



=== TEST 25: conditional request returns no body or encoding
--- config
    if_modified_since before;
    location /test {
        zstd_static on;
        root $TEST_NGINX_PERL_PATH/suite;
    }
--- request
GET /test
--- more_headers
Accept-Encoding: zstd
If-Modified-Since: Thu, 31 Dec 2037 23:59:59 GMT
--- error_code: 304
--- response_headers
!Content-Encoding
--- response_body
--- no_error_log
[error]
