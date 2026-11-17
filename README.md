# Name
zstd-nginx-module - Nginx module for the [Zstandard compression](https://facebook.github.io/zstd/).

# Table of Contents

- [Name](#name)
- [Table of Contents](#table-of-contents)
- [Status](#status)
- [Synopsis](#synopsis)
- [Installation](#installation)
- [Directives](#directives)
  - [ngx\_http\_zstd\_filter\_module](#ngx_http_zstd_filter_module)
    - [zstd\_dict\_file](#zstd_dict_file)
    - [zstd](#zstd)
    - [zstd\_comp\_level](#zstd_comp_level)
    - [zstd\_min\_length](#zstd_min_length)
    - [zstd\_max\_length](#zstd_max_length)
    - [zstd\_types](#zstd_types)
    - [zstd\_buffers](#zstd_buffers)
    - [zstd\_bypass](#zstd_bypass)
    - [zstd_postpone](#zstd_postpone)
    - [zstd_no_buffer](#zstd_no_buffer)
    - [zstd_http_version](#zstd_http_version)
    - [zstd_proxied](#zstd_proxied)
    - [zstd_disable](#zstd_disable)
    - [zstd_window](#zstd_window)
    - [zstd_target_block_size](#zstd_target_block_size)
  - [ngx\_http\_zstd\_static\_module](#ngx_http_zstd_static_module)
    - [zstd\_static](#zstd_static)
- [Variables](#variables)
  - [ngx\_http\_zstd\_filter\_module](#ngx_http_zstd_filter_module-1)
    - [$zstd\_ratio](#zstd_ratio)
- [Author](#author)
- [License](#license)

# Status

This Nginx module is currently considered experimental. Issues and PRs are welcome if you encounter any problems.

# Synopsis

```nginx

# specify the dictionary
zstd_dict_file /path/to/dict;

server {
    listen 127.0.0.1:8080;
    server_name localhost;

    location / {
        # enable zstd compression
        zstd on;
        zstd_min_length 256; # no less than 256 bytes
        zstd_comp_level 3; # set the level to 3

        proxy_pass http://foo.com;
    }
}

server {
    listen 127.0.0.1:8081;
    server_name localhost;

    location / {
        zstd_static on;
        root html;
    }
}
```

# Installation

To use theses modules, configure your nginx branch with `--add-module=/path/to/zstd-nginx-module`. Several points should be taken care of.

* Zstandard 1.4.0 or later is required for `ZSTD_compressStream2()`.
* You can set environment variables `ZSTD_INC` and `ZSTD_LIB` to specify the path to `zstd.h` and the path to zstd shared library respectively.
* System's zstd bundle will be linked if `ZSTD_INC` and `ZSTD_LIB` are not specified.
* Both `ngx_http_zstd_static_module` and `ngx_http_zstd_filter_module` will be configured.

# Directives

## ngx_http_zstd_filter_module

The `ngx_http_zstd_filter_module` module is a filter that compresses responses using the _"zstd"_ method. This often helps to reduce the size of transmitted data by half or even more.

### zstd_dict_file

**Syntax:** *zstd_dict_file /path/to/dict;*  
**Default:** *-*  
**Context:** *http*  

Specifies the external dictionary.

**WARNING:** Be careful! The content-coding registration only specifies a means to signal the use of the zstd format, and does not additionally specify any mechanism for advertising/negotiating/synchronizing the use of a specific dictionary between client and server. Use the `zstd_dict_file` only if you can insure that both ends _(server and client)_ are capable of using the same dictionary (e.g. advertise with a HTTP header). See https://github.com/tokers/zstd-nginx-module/issues/2 for the details.

### zstd

**Syntax:** *zstd on | off;*  
**Default:** *zstd off;*  
**Context:** *http, server, location, if in location, when*

Enables or disables zstd compression for response.

### zstd_comp_level

**Syntax:** *zstd_comp_level level;*  
**Default:** *zstd_comp_level 1;*  
**Context:** *http, server, location, when*

Sets a zstd compression level of a response. Acceptable values are in the
range from `ZSTD_minCLevel()` to `ZSTD_maxCLevel()`, excluding `0`. Negative levels, including `-1`, are supported.

### zstd_min_length

**Syntax:** *zstd_min_length length;*  
**Default:** *zstd_min_length 20;*  
**Context:** *http, server, location, when*

Sets the minimum length of a response that will be compressed by zstd. The length is determined only from the `Content-Length` response header field.

### zstd_max_length

**Syntax:** *zstd_max_length length;*  
**Default:** *zstd_max_length 0;*  
**Context:** *http, server, location, when*

Sets the maximum length of a response that will be compressed by zstd. The length is determined only from the "Content-Length" response header field. A value of 0 means no upper limit.

### zstd_types

**Syntax:** *zstd_types mime-type ...;*  
**Default:** *zstd_types text/html;*  
**Context:** *http, server, location*

Enables zstd of responses for the specified MIME types in addition to `text/html`. The special value `*` matches any MIME type.

### zstd_buffers

**Syntax:** *zstd_buffers number size;*  
**Default:** *zstd_buffers 32 4k | 16 8k;*  
**Context:** *http, server, location*

Sets the number and size of buffers used to compress a response. By default the buffer size is equal to one memory page. This is either 4K or 8K, depending on a platform.

### zstd_bypass

**Syntax:** *zstd_bypass string ...;*  
**Default:** *—*  
**Context:** *http, server, location*

Defines conditions under which the response will be compressed by zstd. If at least one value of the string parameters is not empty and is not equal to “0” then the response will not be compressed by zstd.

### zstd_postpone

**Syntax:** `zstd_postpone size;`\
**Default:** `zstd_postpone 0;`\
**Context:** `http`, `server`, `location`

Postpones encoder initialization until the specified amount of input has been buffered. A flush or the end of the response starts compression earlier.

### zstd_no_buffer

**Syntax:** `zstd_no_buffer on | off;`\
**Default:** `zstd_no_buffer off;`\
**Context:** `http`, `server`, `location`

Passes partially filled output buffers downstream when the currently available input has been consumed. This does not force an encoder flush.

### zstd_http_version

**Syntax:** `zstd_http_version 1.0 | 1.1;`\
**Default:** `zstd_http_version 1.1;`\
**Context:** `http`, `server`, `location`

Alias of [gzip_http_version](https://nginx.org/en/docs/http/ngx_http_gzip_module.html#gzip_http_version).

### zstd_proxied

**Syntax:** `zstd_proxied off | expired | no-cache | no-store | private | no_last_modified | no_etag | auth | any ...;`\
**Default:** `zstd_proxied off;`\
**Context:** `http`, `server`, `location`

Alias of [gzip_proxied](https://nginx.org/en/docs/http/ngx_http_gzip_module.html#gzip_proxied).

### zstd_disable

**Syntax:** `zstd_disable regex ...;`\
**Default:** —\
**Context:** `http`, `server`, `location`

Alias of [gzip_disable](https://nginx.org/en/docs/http/ngx_http_gzip_module.html#gzip_disable).

### zstd_window

**Syntax:** `zstd_window size;`\
**Default:** `zstd_window 512k;`\
**Context:** `http`, `server`, `location`

Sets the Zstd window size, a power of two from `1k` to `8m`.

### zstd_target_block_size

**Syntax:** `zstd_target_block_size size;`\
**Default:** `zstd_target_block_size 0;`\
**Context:** `http`, `server`, `location`

Sets the target compressed block size. This is an approximate target, independent of the output buffer size. The value `0` uses the library default.

Available with libzstd 1.5.6 or later.

## ngx_http_zstd_static_module

The `ngx_http_zstd_static_module` module allows sending precompressed files with the `.zst` filename extension instead of regular files.

### zstd_static

**Syntax:**	*zstd_static on | off | always;*  
**Default:** *zstd_static off;*  
**Context:** *http, server, location, when*

Enables ("on") or disables ("off") checking the existence of precompressed files. The following directives are also taken into account: `zstd_http_version`, `zstd_proxied`, `zstd_disable`, and `gzip_vary`.

With the _"always"_ value, "zstd" file is used in all cases, without checking if the client supports it.


# Variables

## ngx_http_zstd_filter_module

### $zstd_ratio

Achieved compression ratio, computed as the ratio between the original and compressed response sizes.

# Author

Alex Zhang (张超) zchao1995@gmail.com, UPYUN Inc.
Hanada im@hanada.info

# License

This Nginx module is licensed under [BSD 2-Clause License](LICENSE).


# Compatibility

Dynamic compression applies to main requests with status 200, 207, 403, or 404. HEAD responses and responses with an existing nonempty `Content-Encoding` are passed through. `Cache-Control: no-transform` prevents dynamic compression.

The core `gzip_http_version`, `gzip_proxied`, and `gzip_disable` settings also apply. Their defaults restrict compression to HTTP/1.1 or later and disable it for requests with a `Via` header. The `zstd_*` aliases configure the same core settings.

Directives whose context includes `when` support [ngx_expr_module](https://github.com/HanadaLee/ngx_expr_module). The module also builds on unpatched nginx without expr support.

# Testing

`util/run-tests.sh` runs the existing suite and the regressions under `t/parity/`. The latter use [nginx-tests](https://github.com/nginx/nginx-tests) and cover proxy buffering on and off, slow clients, cancellation, streaming, HTTP/2 and HTTP/3, static files, and conditional configuration. Set `TEST_NGINX_BINARY` and `PERL5LIB` to run `prove -v t/parity/*.t` directly.

Set `TEST_NGINX_ZSTD_TARGET_BLOCK_SIZE=1` when built with libzstd 1.5.6 or later. `util/run-tests.sh` detects this automatically.
