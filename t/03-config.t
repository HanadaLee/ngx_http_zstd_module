use Test::Nginx::Socket;
use File::Basename qw(dirname);

use lib 'lib';

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
log_level 'warn';
repeat_each(1);
plan 'no_plan';
run_tests();


__DATA__


=== TEST 1: invalid zstd_static enum is rejected cleanly
--- config
    location /t {
        zstd_static maybe;
    }
--- must_die
--- error_log
invalid value "maybe"
--- no_error_log
[alert]



=== TEST 2: compression level zero is rejected
--- config
    location /t {
        zstd on;
        zstd_comp_level 0;
        return 200 "body";
    }
--- must_die
--- error_log
zstd compress level must between
--- no_error_log
[alert]



=== TEST 3: compression level above library maximum is rejected
--- config
    location /t {
        zstd on;
        zstd_comp_level 999999;
        return 200 "body";
    }
--- must_die
--- error_log
zstd compress level must between
--- no_error_log
[alert]



=== TEST 4: invalid minimum length is rejected
--- config
    location /t {
        zstd on;
        zstd_min_length invalid;
        return 200 "body";
    }
--- must_die
--- error_log
"zstd_min_length" directive invalid value
--- no_error_log
[alert]



=== TEST 5: zero buffer count is rejected
--- config
    location /t {
        zstd on;
        zstd_buffers 0 4k;
        return 200 "body";
    }
--- must_die
--- error_log
"zstd_buffers" directive invalid value
--- no_error_log
[alert]



=== TEST 6: missing dictionary file prevents startup
--- http_config
    zstd_dict_file $TEST_NGINX_SERVER_ROOT/html/does-not-exist.dict;
--- config
    location /t {
        zstd on;
        return 200 "body";
    }
--- must_die
--- error_log
does-not-exist.dict" failed
--- no_error_log
[alert]



=== TEST 7: dictionary directive is restricted to http context
--- config
    location /t {
        zstd_dict_file dictionary;
        return 200 "body";
    }
--- must_die
--- error_log
"zstd_dict_file" directive is not allowed here
--- no_error_log
[alert]



=== TEST 8: zstd_bypass requires at least one predicate
--- config
    location /t {
        zstd on;
        zstd_bypass;
        return 200 "body";
    }
--- must_die
--- error_log
invalid number of arguments in "zstd_bypass" directive
--- no_error_log
[alert]
