use Test::Nginx::Socket;
use File::Basename qw(dirname);
use Cwd qw(abs_path);

use lib 'lib';

my $test_dir = abs_path(dirname(__FILE__));
$ENV{'TEST_NGINX_PERL_PATH'} = $test_dir;

my $nginx_binary = $ENV{'TEST_NGINX_BINARY'} || 'nginx';
my $nginx_build = qx{$nginx_binary -V 2>&1};
$ENV{'TEST_NGINX_HAVE_SUB_FILTER'} =
    $nginx_build =~ /--with-http_sub_module(?:\s|$)/ ? 1 : 0;

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


=== TEST 1: disabled filter never compresses
--- config
    location = /t {
        zstd off;
        default_type text/plain;
        return 200 "0123456789abcdef";
    }
--- request
GET /t
--- more_headers
Accept-Encoding: zstd
--- response_headers
!Content-Encoding
Content-Length: 16
--- response_body: 0123456789abcdef
--- no_error_log
[error]



=== TEST 2: enabled filter requires Accept-Encoding
--- config
    location = /t {
        zstd on;
        zstd_min_length 1;
        zstd_types text/plain;
        default_type text/plain;
        return 200 "0123456789abcdef";
    }
--- request
GET /t
--- response_headers
!Content-Encoding
Content-Length: 16
--- response_body: 0123456789abcdef
--- no_error_log
[error]



=== TEST 3: exact zstd token enables compression
--- config
    location = /t {
        zstd on;
        zstd_min_length 1;
        zstd_types text/plain;
        default_type text/plain;
        return 200 "0123456789abcdef";
    }
--- request
GET /t
--- more_headers
Accept-Encoding: zstd
--- response_headers
Content-Encoding: zstd
!Content-Length
--- response_body_like: ^\x28\xb5\x2f\xfd
--- no_error_log
[error]



=== TEST 4: zstd token in a mixed list enables compression
--- config
    location = /t {
        zstd on;
        zstd_min_length 1;
        zstd_types text/plain;
        default_type text/plain;
        return 200 "0123456789abcdef";
    }
--- request
GET /t
--- more_headers
Accept-Encoding: gzip, br, zstd
--- response_headers
Content-Encoding: zstd
--- response_body_like: ^\x28\xb5\x2f\xfd
--- no_error_log
[error]



=== TEST 5: unrelated encodings leave the response unchanged
--- config
    location = /t {
        zstd on;
        zstd_min_length 1;
        zstd_types text/plain;
        default_type text/plain;
        return 200 "0123456789abcdef";
    }
--- request
GET /t
--- more_headers
Accept-Encoding: gzip, br
--- response_headers
!Content-Encoding
Content-Length: 16
--- response_body: 0123456789abcdef
--- no_error_log
[error]



=== TEST 6: q=0 rejects zstd
--- config
    location = /t {
        zstd on;
        zstd_min_length 1;
        zstd_types text/plain;
        default_type text/plain;
        return 200 "0123456789abcdef";
    }
--- request
GET /t
--- more_headers
Accept-Encoding: zstd;q=0
--- response_headers
!Content-Encoding
--- response_body: 0123456789abcdef
--- no_error_log
[error]



=== TEST 7: q=0.000 rejects zstd
--- config
    location = /t {
        zstd on;
        zstd_min_length 1;
        zstd_types text/plain;
        default_type text/plain;
        return 200 "0123456789abcdef";
    }
--- request
GET /t
--- more_headers
Accept-Encoding: zstd;q=0.000
--- response_headers
!Content-Encoding
--- no_error_log
[error]



=== TEST 8: smallest accepted positive qvalue
--- config
    location = /t {
        zstd on;
        zstd_min_length 1;
        zstd_types text/plain;
        default_type text/plain;
        return 200 "0123456789abcdef";
    }
--- request
GET /t
--- more_headers
Accept-Encoding: zstd;q=0.001
--- response_headers
Content-Encoding: zstd
--- response_body_like: ^\x28\xb5\x2f\xfd
--- no_error_log
[error]



=== TEST 9: maximum accepted qvalue
--- config
    location = /t {
        zstd on;
        zstd_min_length 1;
        zstd_types text/plain;
        default_type text/plain;
        return 200 "0123456789abcdef";
    }
--- request
GET /t
--- more_headers
Accept-Encoding: zstd;q=1.000
--- response_headers
Content-Encoding: zstd
--- no_error_log
[error]



=== TEST 10: qvalue above one is rejected
--- config
    location = /t {
        zstd on;
        zstd_min_length 1;
        zstd_types text/plain;
        default_type text/plain;
        return 200 "0123456789abcdef";
    }
--- request
GET /t
--- more_headers
Accept-Encoding: zstd;q=1.001
--- response_headers
!Content-Encoding
--- no_error_log
[error]



=== TEST 11: qvalue with four fractional digits is rejected
--- config
    location = /t {
        zstd on;
        zstd_min_length 1;
        zstd_types text/plain;
        default_type text/plain;
        return 200 "0123456789abcdef";
    }
--- request
GET /t
--- more_headers
Accept-Encoding: zstd;q=0.0001
--- response_headers
!Content-Encoding
--- no_error_log
[error]



=== TEST 12: coding name and q parameter are case-insensitive
--- config
    location = /t {
        zstd on;
        zstd_min_length 1;
        zstd_types text/plain;
        default_type text/plain;
        return 200 "0123456789abcdef";
    }
--- request
GET /t
--- more_headers
Accept-Encoding: ZsTd;Q=0.5
--- response_headers
Content-Encoding: zstd
--- no_error_log
[error]



=== TEST 13: embedded substring does not hide a later token
--- config
    location = /t {
        zstd on;
        zstd_min_length 1;
        zstd_types text/plain;
        default_type text/plain;
        return 200 "0123456789abcdef";
    }
--- request
GET /t
--- more_headers
Accept-Encoding: notzstd, zstd
--- response_headers
Content-Encoding: zstd
--- no_error_log
[error]



=== TEST 14: wildcard follows official gzip parser behavior
--- config
    location = /t {
        zstd on;
        zstd_min_length 1;
        zstd_types text/plain;
        default_type text/plain;
        return 200 "0123456789abcdef";
    }
--- request
GET /t
--- more_headers
Accept-Encoding: *
--- response_headers
!Content-Encoding
--- no_error_log
[error]



=== TEST 15: first explicit q=0 occurrence wins like gzip
--- config
    location = /t {
        zstd on;
        zstd_min_length 1;
        zstd_types text/plain;
        default_type text/plain;
        return 200 "0123456789abcdef";
    }
--- request
GET /t
--- more_headers
Accept-Encoding: zstd;q=0, zstd
--- response_headers
!Content-Encoding
--- no_error_log
[error]



=== TEST 16: malformed q parameter is rejected
--- config
    location = /t {
        zstd on;
        zstd_min_length 1;
        zstd_types text/plain;
        default_type text/plain;
        return 200 "0123456789abcdef";
    }
--- request
GET /t
--- more_headers
Accept-Encoding: zstd;q
--- response_headers
!Content-Encoding
--- no_error_log
[error]



=== TEST 17: minimum length excludes a shorter known body
--- config
    location = /t {
        zstd on;
        zstd_min_length 17;
        zstd_types text/plain;
        default_type text/plain;
        return 200 "0123456789abcdef";
    }
--- request
GET /t
--- more_headers
Accept-Encoding: zstd
--- response_headers
!Content-Encoding
Content-Length: 16
--- no_error_log
[error]



=== TEST 18: minimum length is inclusive
--- config
    location = /t {
        zstd on;
        zstd_min_length 16;
        zstd_types text/plain;
        default_type text/plain;
        return 200 "0123456789abcdef";
    }
--- request
GET /t
--- more_headers
Accept-Encoding: zstd
--- response_headers
Content-Encoding: zstd
--- no_error_log
[error]



=== TEST 19: maximum length is inclusive
--- config
    location = /t {
        zstd on;
        zstd_min_length 1;
        zstd_max_length 16;
        zstd_types text/plain;
        default_type text/plain;
        return 200 "0123456789abcdef";
    }
--- request
GET /t
--- more_headers
Accept-Encoding: zstd
--- response_headers
Content-Encoding: zstd
--- no_error_log
[error]



=== TEST 20: maximum length excludes a larger known body
--- config
    location = /t {
        zstd on;
        zstd_min_length 1;
        zstd_max_length 15;
        zstd_types text/plain;
        default_type text/plain;
        return 200 "0123456789abcdef";
    }
--- request
GET /t
--- more_headers
Accept-Encoding: zstd
--- response_headers
!Content-Encoding
Content-Length: 16
--- no_error_log
[error]



=== TEST 21: listed MIME type is compressed
--- config
    location = /t {
        zstd on;
        zstd_min_length 1;
        zstd_types application/json;
        default_type application/json;
        return 200 '{"value":"0123456789"}';
    }
--- request
GET /t
--- more_headers
Accept-Encoding: zstd
--- response_headers
Content-Encoding: zstd
Content-Type: application/json
--- no_error_log
[error]



=== TEST 22: unlisted MIME type is not compressed
--- config
    location = /t {
        zstd on;
        zstd_min_length 1;
        zstd_types application/json;
        default_type text/plain;
        return 200 "0123456789abcdef";
    }
--- request
GET /t
--- more_headers
Accept-Encoding: zstd
--- response_headers
!Content-Encoding
Content-Type: text/plain
--- no_error_log
[error]



=== TEST 23: wildcard MIME type compresses binary content
--- config
    location = /t {
        zstd on;
        zstd_min_length 1;
        zstd_types *;
        default_type application/octet-stream;
        return 200 "0123456789abcdef";
    }
--- request
GET /t
--- more_headers
Accept-Encoding: zstd
--- response_headers
Content-Encoding: zstd
Content-Type: application/octet-stream
--- no_error_log
[error]



=== TEST 24: truthy bypass predicate disables compression
--- config
    location = /t {
        zstd on;
        zstd_min_length 1;
        zstd_types text/plain;
        zstd_bypass $http_x_bypass;
        default_type text/plain;
        return 200 "0123456789abcdef";
    }
--- request
GET /t
--- more_headers
Accept-Encoding: zstd
X-Bypass: 1
--- response_headers
!Content-Encoding
--- no_error_log
[error]



=== TEST 25: bypass value zero remains compressible
--- config
    location = /t {
        zstd on;
        zstd_min_length 1;
        zstd_types text/plain;
        zstd_bypass $http_x_bypass;
        default_type text/plain;
        return 200 "0123456789abcdef";
    }
--- request
GET /t
--- more_headers
Accept-Encoding: zstd
X-Bypass: 0
--- response_headers
Content-Encoding: zstd
--- no_error_log
[error]



=== TEST 26: HEAD advertises the same encoding as GET
--- config
    location = /t {
        zstd on;
        zstd_min_length 1;
        zstd_types text/plain;
        default_type text/plain;
        return 200 "0123456789abcdef";
    }
--- request
HEAD /t
--- more_headers
Accept-Encoding: zstd
--- response_headers
Content-Encoding: zstd
!Content-Length
--- response_body
--- no_error_log
[error]



=== TEST 27: status 204 is not filtered
--- config
    location = /t {
        zstd on;
        zstd_min_length 0;
        zstd_types text/plain;
        return 204;
    }
--- request
GET /t
--- more_headers
Accept-Encoding: zstd
--- error_code: 204
--- response_headers
!Content-Encoding
--- no_error_log
[error]



=== TEST 28: status 304 is not filtered
--- config
    location = /t {
        zstd on;
        zstd_min_length 0;
        zstd_types text/plain;
        return 304;
    }
--- request
GET /t
--- more_headers
Accept-Encoding: zstd
--- error_code: 304
--- response_headers
!Content-Encoding
--- no_error_log
[error]



=== TEST 29: status 403 body can be compressed
--- config
    location = /t {
        zstd on;
        zstd_min_length 1;
        zstd_types text/plain;
        default_type text/plain;
        return 403 "forbidden body";
    }
--- request
GET /t
--- more_headers
Accept-Encoding: zstd
--- error_code: 403
--- response_headers
Content-Encoding: zstd
--- response_body_like: ^\x28\xb5\x2f\xfd
--- no_error_log
[error]



=== TEST 30: status 404 body can be compressed
--- config
    location = /t {
        zstd on;
        zstd_min_length 1;
        zstd_types text/plain;
        default_type text/plain;
        return 404 "not found body";
    }
--- request
GET /t
--- more_headers
Accept-Encoding: zstd
--- error_code: 404
--- response_headers
Content-Encoding: zstd
--- response_body_like: ^\x28\xb5\x2f\xfd
--- no_error_log
[error]



=== TEST 31: existing upstream Content-Encoding prevents double encoding
--- config
    location = /t {
        zstd on;
        zstd_min_length 1;
        zstd_types text/plain;
        proxy_pass http://127.0.0.1:$TEST_NGINX_SERVER_PORT/source;
    }
    location = /source {
        default_type text/plain;
        add_header Content-Encoding gzip;
        return 200 "already encoded";
    }
--- request
GET /t
--- more_headers
Accept-Encoding: zstd
--- response_headers
Content-Encoding: gzip
--- response_body: already encoded
--- no_error_log
[error]



=== TEST 32: empty body produces a terminal zstd frame
--- config
    location = /t {
        zstd on;
        zstd_min_length 0;
        zstd_types text/plain;
        proxy_pass http://127.0.0.1:$TEST_NGINX_SERVER_PORT/source;
    }
    location = /source {
        default_type text/plain;
        return 200 "";
    }
--- request
GET /t
--- more_headers
Accept-Encoding: zstd
--- timeout: 5
--- response_headers
Content-Encoding: zstd
--- response_body_like: ^\x28\xb5\x2f\xfd
--- no_error_log
[error]



=== TEST 33: single byte body terminates without spinning
--- config
    location = /t {
        zstd on;
        zstd_min_length 1;
        zstd_types text/plain;
        default_type text/plain;
        return 200 "x";
    }
--- request
GET /t
--- more_headers
Accept-Encoding: zstd
--- timeout: 5
--- response_headers
Content-Encoding: zstd
--- response_body_like: ^\x28\xb5\x2f\xfd
--- no_error_log
[error]



=== TEST 34: small output buffers handle a large response
--- config
    location = /t {
        zstd on;
        zstd_min_length 1;
        zstd_buffers 2 1k;
        zstd_types text/plain;
        proxy_pass http://127.0.0.1:$TEST_NGINX_SERVER_PORT/test;
    }
    location = /test {
        root $TEST_NGINX_PERL_PATH/suite;
    }
--- request
GET /t
--- more_headers
Accept-Encoding: zstd
--- timeout: 5
--- response_headers
Content-Encoding: zstd
!Content-Length
--- response_body_like: ^\x28\xb5\x2f\xfd
--- no_error_log
[error]
zero size buf



=== TEST 35: zstd and gzip filters coexist with zstd preferred by order
--- config
    location = /t {
        zstd on;
        zstd_min_length 1;
        zstd_types text/plain;
        gzip on;
        gzip_min_length 1;
        gzip_types text/plain;
        default_type text/plain;
        return 200 "0123456789abcdef0123456789abcdef";
    }
--- request
GET /t
--- more_headers
Accept-Encoding: gzip, zstd
--- response_headers
Content-Encoding: zstd
--- response_body_like: ^\x28\xb5\x2f\xfd
--- no_error_log
[error]



=== TEST 36: gzip-only client falls through to gzip
--- config
    location = /t {
        zstd on;
        zstd_min_length 1;
        zstd_types text/plain;
        gzip on;
        gzip_min_length 1;
        gzip_types text/plain;
        default_type text/plain;
        return 200 "0123456789abcdef0123456789abcdef";
    }
--- request
GET /t
--- more_headers
Accept-Encoding: gzip
--- response_headers
Content-Encoding: gzip
--- response_body_like: ^\x1f\x8b
--- no_error_log
[error]



=== TEST 37: gzip_vary emits Vary on encoded response
--- config
    gzip_vary on;
    location = /t {
        zstd on;
        zstd_min_length 1;
        zstd_types text/plain;
        default_type text/plain;
        return 200 "0123456789abcdef";
    }
--- request
GET /t
--- more_headers
Accept-Encoding: zstd
--- response_headers
Content-Encoding: zstd
Vary: Accept-Encoding
--- no_error_log
[error]



=== TEST 38: gzip_vary emits Vary on identity response
--- config
    gzip_vary on;
    location = /t {
        zstd on;
        zstd_min_length 1;
        zstd_types text/plain;
        default_type text/plain;
        return 200 "0123456789abcdef";
    }
--- request
GET /t
--- more_headers
Accept-Encoding: gzip
--- response_headers
!Content-Encoding
Vary: Accept-Encoding
--- no_error_log
[error]



=== TEST 39: sub_filter output is compressed after substitution
--- skip_eval: 5: !$ENV{'TEST_NGINX_HAVE_SUB_FILTER'}
--- config
    location = /t {
        zstd on;
        zstd_min_length 1;
        zstd_types text/plain;
        sub_filter_types text/plain;
        sub_filter once off;
        sub_filter original replaced;
        proxy_pass http://127.0.0.1:$TEST_NGINX_SERVER_PORT/source;
    }
    location = /source {
        default_type text/plain;
        return 200 "original original original";
    }
--- request
GET /t
--- more_headers
Accept-Encoding: zstd
--- response_headers
Content-Encoding: zstd
--- response_body_like: ^\x28\xb5\x2f\xfd
--- no_error_log
[error]
zero size buf



=== TEST 40: negative compression level is accepted
--- config
    location = /t {
        zstd on;
        zstd_comp_level -1;
        zstd_min_length 1;
        zstd_types text/plain;
        default_type text/plain;
        return 200 "0123456789abcdef";
    }
--- request
GET /t
--- more_headers
Accept-Encoding: zstd
--- response_headers
Content-Encoding: zstd
--- response_body_like: ^\x28\xb5\x2f\xfd
--- no_error_log
[error]



=== TEST 41: configured dictionary creates a valid zstd frame
--- http_config
    zstd_dict_file $TEST_NGINX_PERL_PATH/suite/test;
--- config
    location = /t {
        zstd on;
        zstd_min_length 1;
        zstd_types text/plain;
        default_type text/plain;
        return 200 "0123456789abcdef0123456789abcdef";
    }
--- request
GET /t
--- more_headers
Accept-Encoding: zstd
--- response_headers
Content-Encoding: zstd
--- response_body_like: ^\x28\xb5\x2f\xfd
--- no_error_log
[error]



=== TEST 42: partial upstream response is not compressed
--- config
    location = /t {
        zstd on;
        zstd_min_length 1;
        zstd_types text/plain;
        proxy_pass http://127.0.0.1:$TEST_NGINX_SERVER_PORT/test;
    }
    location = /test {
        root $TEST_NGINX_PERL_PATH/suite;
    }
--- request
GET /t
--- more_headers
Accept-Encoding: zstd
Range: bytes=0-15
--- error_code: 206
--- response_headers_like
Content-Range: bytes 0-15/\d+
--- response_headers
!Content-Encoding
Content-Length: 16
--- no_error_log
[error]



=== TEST 43: compressed response does not advertise byte ranges
--- config
    location = /test {
        zstd on;
        zstd_min_length 1;
        zstd_types *;
        root $TEST_NGINX_PERL_PATH/suite;
    }
--- request
GET /test
--- more_headers
Accept-Encoding: zstd
--- response_headers
Content-Encoding: zstd
!Accept-Ranges
--- response_body_like: ^\x28\xb5\x2f\xfd
--- no_error_log
[error]
