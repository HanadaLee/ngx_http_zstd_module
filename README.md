# Name
zstd-nginx-module - Nginx module for the [Zstandard compression](https://facebook.github.io/zstd/).

# Table of Content

* [Name](#name)
* [Status](#status)
* [Synopsis](#synopsis)
* [Installation](#installation)
* [Directives](#directives)
  * [ngx_http_zstd_filter_module](#ngx_http_zstd_filter_module)
    * [zstd_dict_file](#zstd_dict_file)
    * [zstd](#zstd)
    * [zstd_comp_level](#zstd_comp_level)
    * [zstd_min_length](#zstd_min_length)
    * [zstd_max_length](#zstd_max_length)
    * [zstd_types](#zstd_types)
    * [zstd_buffers](#zstd_buffers)
    * [zstd_bypass](#zstd_bypass)
  * [ngx_http_zstd_static_module](#ngx_http_zstd_static_module)
    * [zstd_static](#zstd_static)
* [Variables](#variables)
  * [ngx_http_zstd_filter_module](#ngx_http_zstd_filter_module)
    * [$zstd_ratio](#$zstd_ratio)
* [Author](#author)

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

To use theses modules, configure your nginx branch with `--add-module=/path/to/zstd-nginx-module`. Several points should be taken care.

* You can set environment variables `ZSTD_INC` and `ZSTD_LIB` to specify the path to `zstd.h` and the path to zstd shared library represently.
* static library will be tried prior to dynamic library, since this Nginx module uses some **advanced APIs** where static linking is recommended.
* System's zstd bundle will be linked if `ZSTD_INC` and `ZSTD_LIB` are not specified.
* Both `ngx_http_zstd_static_module` and `ngx_http_zstd_filter_module` will be configured.

# Directives

## ngx_http_zstd_filter_module

The `ngx_http_zstd_filter_module` module is a filter that compresses responses using the "zstd" method. This often helps to reduce the size of transmitted data by half or even more.

### zstd_dict_file

**Syntax:** *zstd_dict_file /path/to/dict;*  
**Default:** *-*  
**Context:** *http*  

Specifies the external dictionary.

**WARNING:** Be careful! The content-coding registration only specifies a means to signal the use of the zstd format, and does not additionally specify any mechanism for advertising/negotiating/synchronizing the use of a specific dictionary between client and server. Use the `zstd_dict_file` only if you can insure that both ends (server and client) are capable of  using the same dictionary (e.g. advertise with a HTTP header). See https://github.com/tokers/zstd-nginx-module/issues/2 for the details.

### zstd

**Syntax:** *zstd on | off;*  
**Default:** *zstd off;*  
**Context:** *http, server, location, if in location*

Enables or disables zstd compression for response.

### zstd_comp_level

**Syntax:** *zstd_comp_level level;*  
**Default:** *zstd_comp_level 1;*  
**Context:** *http, server, location*

Sets a zstd compression level of a response. Acceptable values are in the range from 1 to `ZSTD_maxCLevel()`.

### zstd_min_length

**Syntax:** *zstd_min_length length;*  
**Default:** *zstd_min_length 20;*  
**Context:** *http, server, location*

Sets the minimum length of a response that will be compressed by zstd. The length is determined only from the "Content-Length" response header field.

### zstd_max_length

**Syntax:** *zstd_max_length length;*  
**Default:** *zstd_max_length 0;*  
**Context:** *http, server, location*

Sets the maximum length of a response that will be compressed by zstd. The length is determined only from the "Content-Length" response header field. A value of 0 means no upper limit.

### zstd_types

**Syntax:** *zstd_types mime-type ...;*  
**Default:** *zstd_types text/html;*  
**Context:** *http, server, location*

Enables ztd of responses for the specified MIME types in addition to "text/html". The special value "*" matches any MIME type.

### zstd_buffers

**Syntax:** *zstd_buffers number size;*  
**Default:** *zstd_buffers 32 4k | 16 8k;*  
**Context:** *http, server, location*

Sets the number and size of buffers used to compress a response. By default, the buffer size is equal to one memory page. This is either 4K or 8K, depending on a platform.

### zstd_bypass

**Syntax:** *zstd_bypass string ...;*  
**Default:** *—*  
**Context:** *http, server, location*

Defines conditions under which the response will be compressed by zstd. If at least one value of the string parameters is not empty and is not equal to “0” then the response will not be compressed by zstd.

## ngx_http_zstd_static_module

The `ngx_http_zstd_static_module` module allows sending precompressed files with the ".zst" filename extension instead of regular files.

### zstd_static

**Syntax:**	*zstd_static on | off | always;*  
**Default:** *zstd_static off;*  
**Context:** *http, server, location*  

Enables ("on") or disables ("off") checking the existence of precompressed files. The following directives are also taken into account: gzip_vary.

With the "always" value, "zsted" file is used in all cases, without checking if the client supports it.


# Variables

## ngx_http_zstd_filter_module

### $zstd_ratio

Achieved compression ratio, computed as the ratio between the original and compressed response sizes.

# Author

Alex Zhang (张超) zchao1995@gmail, UPYUN Inc.

# License

This Nginx module is licensed under [BSD 2-Clause License](LICENSE).
