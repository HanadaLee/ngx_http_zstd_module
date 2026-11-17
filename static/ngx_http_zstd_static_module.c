
/*
 * Copyright (C) Hanada
 * Copyright (C) Alex Zhang
 * Copyright (C) Igor Sysoev
 * Copyright (C) Nginx, Inc.
 */


#include <ngx_config.h>
#include <ngx_core.h>
#include <ngx_http.h>

#if (NGX_EXPR)
#include <ngx_http_expr_module.h>
#endif


#define NGX_HTTP_ZSTD_STATIC_OFF              0
#define NGX_HTTP_ZSTD_STATIC_ON               1
#define NGX_HTTP_ZSTD_STATIC_ALWAYS           2


typedef struct {
#if (NGX_EXPR)
    ngx_array_t  *enable;
#else
    ngx_uint_t    enable;
#endif
} ngx_http_zstd_static_conf_t;


static ngx_int_t ngx_http_zstd_cache_control(ngx_http_request_t *r);
static ngx_int_t ngx_http_zstd_policy(ngx_http_request_t *r);

static ngx_int_t ngx_http_zstd_static_handler(ngx_http_request_t *r);

static ngx_int_t ngx_http_zstd_ok(ngx_http_request_t *r);
static ngx_int_t ngx_http_zstd_accept_encoding(ngx_str_t *ae);
static ngx_uint_t ngx_http_zstd_quantity(u_char *p, u_char *last);

static void *ngx_http_zstd_static_create_conf(ngx_conf_t *cf);
static char *ngx_http_zstd_static_merge_conf(ngx_conf_t *cf, void *parent,
    void *child);
static ngx_int_t ngx_http_zstd_static_init(ngx_conf_t *cf);


static ngx_conf_enum_t  ngx_http_zstd_static[] = {
    { ngx_string("off"), NGX_HTTP_ZSTD_STATIC_OFF },
    { ngx_string("on"), NGX_HTTP_ZSTD_STATIC_ON },
    { ngx_string("always"), NGX_HTTP_ZSTD_STATIC_ALWAYS },
    { ngx_null_string, 0 }
};


static ngx_command_t  ngx_http_zstd_static_commands[] = {

    { ngx_string("zstd_static"),
      NGX_HTTP_MAIN_CONF|NGX_HTTP_SRV_CONF|NGX_HTTP_LOC_CONF
#if (NGX_EXPR)
                        |NGX_HTTP_MAIN_WHEN_CONF|NGX_HTTP_SRV_WHEN_CONF
                        |NGX_HTTP_LOC_WHEN_CONF
#endif
                        |NGX_CONF_TAKE1,
#if (NGX_EXPR)
      ngx_conf_set_conditional_enum_slot,
#else
      ngx_conf_set_enum_slot,
#endif
      NGX_HTTP_LOC_CONF_OFFSET,
      offsetof(ngx_http_zstd_static_conf_t, enable),
      &ngx_http_zstd_static },

      ngx_null_command
};


static ngx_http_module_t  ngx_http_zstd_static_module_ctx = {
    NULL,                                  /* preconfiguration */
    ngx_http_zstd_static_init,             /* postconfiguration */

    NULL,                                  /* create main configuration */
    NULL,                                  /* init main configuration */

    NULL,                                  /* create server configuration */
    NULL,                                  /* merge server configuration */

    ngx_http_zstd_static_create_conf,      /* create location configuration */
    ngx_http_zstd_static_merge_conf        /* merge location configuration */
};


ngx_module_t  ngx_http_zstd_static_module = {
    NGX_MODULE_V1,
    &ngx_http_zstd_static_module_ctx,      /* module context */
    ngx_http_zstd_static_commands,         /* module directives */
    NGX_HTTP_MODULE,                       /* module type */
    NULL,                                  /* init master */
    NULL,                                  /* init module */
    NULL,                                  /* init process */
    NULL,                                  /* init thread */
    NULL,                                  /* exit thread */
    NULL,                                  /* exit process */
    NULL,                                  /* exit master */
    NGX_MODULE_V1_PADDING
};


static ngx_int_t
ngx_http_zstd_static_handler(ngx_http_request_t *r)
{
    ngx_uint_t                    enable;
    u_char                       *p;
    size_t                        root;
    ngx_str_t                     path;
    ngx_int_t                     rc;
    ngx_uint_t                    level;
    ngx_log_t                    *log;
    ngx_buf_t                    *b;
    ngx_chain_t                   out;
    ngx_table_elt_t              *h;
    ngx_open_file_info_t          of;
    ngx_http_core_loc_conf_t     *clcf;
    ngx_http_zstd_static_conf_t  *zscf;

    if (!(r->method & (NGX_HTTP_GET|NGX_HTTP_HEAD))) {
        return NGX_DECLINED;
    }

    if (r->uri.len == 0 || r->uri.data[r->uri.len - 1] == '/') {
        return NGX_DECLINED;
    }

    zscf = ngx_http_get_module_loc_conf(r, ngx_http_zstd_static_module);

#if (NGX_EXPR)
    enable = ngx_http_get_expr_enum_value(r, zscf->enable);
#else
    enable = zscf->enable;
#endif

    if (enable == NGX_HTTP_ZSTD_STATIC_OFF) {
        return NGX_DECLINED;
    }

    if (enable == NGX_HTTP_ZSTD_STATIC_ON) {
        if (ngx_http_zstd_policy(r) != NGX_OK) {
            return NGX_DECLINED;
        }

        r->gzip_vary = 1;
        rc = ngx_http_zstd_ok(r);

    } else {
        /* always */
        rc = NGX_OK;
    }

    clcf = ngx_http_get_module_loc_conf(r, ngx_http_core_module);

    if (!clcf->gzip_vary && rc != NGX_OK) {
        return NGX_DECLINED;
    }

    log = r->connection->log;

    p = ngx_http_map_uri_to_path(r, &path, &root, sizeof(".zst") - 1);
    if (p == NULL) {
        return NGX_HTTP_INTERNAL_SERVER_ERROR;
    }

    *p++ = '.';
    *p++ = 'z';
    *p++ = 's';
    *p++ = 't';
    *p = '\0';

    path.len = p - path.data;

    ngx_log_debug1(NGX_LOG_DEBUG_HTTP, log, 0,
                   "http filename: \"%s\"", path.data);

    ngx_memzero(&of, sizeof(ngx_open_file_info_t));

    of.read_ahead = clcf->read_ahead;
    of.directio = clcf->directio;
    of.valid = clcf->open_file_cache_valid;
    of.min_uses = clcf->open_file_cache_min_uses;
    of.errors = clcf->open_file_cache_errors;
    of.events = clcf->open_file_cache_events;

    if (ngx_http_set_disable_symlinks(r, clcf, &path, &of) != NGX_OK) {
        return NGX_HTTP_INTERNAL_SERVER_ERROR;
    }

    if (ngx_open_cached_file(clcf->open_file_cache, &path, &of, r->pool)
        != NGX_OK)
    {
        switch (of.err) {
        case 0:
            return NGX_HTTP_INTERNAL_SERVER_ERROR;

        case NGX_ENOENT:
        case NGX_ENOTDIR:
        case NGX_ENAMETOOLONG:

            return NGX_DECLINED;

        case NGX_EACCES:
#if (NGX_HAVE_OPENAT)
        case NGX_EMLINK:
        case NGX_ELOOP:
#endif

            level = NGX_LOG_ERR;
            break;

        default:

            level = NGX_LOG_CRIT;
            break;
        }

        ngx_log_error(level, log, of.err,
                      "%s \"%s\" failed", of.failed, path.data);

        return NGX_DECLINED;
    }

    if (enable == NGX_HTTP_ZSTD_STATIC_ON) {
        r->gzip_vary = 1;

        if (rc != NGX_OK) {
            return NGX_DECLINED;
        }
    }

    ngx_log_debug1(NGX_LOG_DEBUG_HTTP, log, 0, "http static fd: %d", of.fd);

    if (of.is_dir) {
        ngx_log_debug0(NGX_LOG_DEBUG_HTTP, log, 0, "http dir");
        return NGX_DECLINED;
    }

#if !(NGX_WIN32) /* the not regular files are probably Unix specific */

    if (!of.is_file) {
        ngx_log_error(NGX_LOG_CRIT, log, 0,
                      "\"%s\" is not a regular file", path.data);

        return NGX_HTTP_NOT_FOUND;
    }

#endif

    r->root_tested = !r->error_page;

    rc = ngx_http_discard_request_body(r);

    if (rc != NGX_OK) {
        return rc;
    }

    log->action = "sending response to client";

    r->headers_out.status = NGX_HTTP_OK;
    r->headers_out.content_length_n = of.size;
    r->headers_out.last_modified_time = of.mtime;

    if (ngx_http_set_etag(r) != NGX_OK) {
        return NGX_HTTP_INTERNAL_SERVER_ERROR;
    }

    if (ngx_http_set_content_type(r) != NGX_OK) {
        return NGX_HTTP_INTERNAL_SERVER_ERROR;
    }

    h = ngx_list_push(&r->headers_out.headers);
    if (h == NULL) {
        return NGX_HTTP_INTERNAL_SERVER_ERROR;
    }

    h->hash = 1;
#if (nginx_version >= 1023000)
    h->next = NULL;
#endif
    ngx_str_set(&h->key, "Content-Encoding");
    ngx_str_set(&h->value, "zstd");
    r->headers_out.content_encoding = h;

    r->allow_ranges = 1;

    /* we need to allocate all before the header would be sent */

    b = ngx_calloc_buf(r->pool);
    if (b == NULL) {
        return NGX_HTTP_INTERNAL_SERVER_ERROR;
    }

    b->file = ngx_pcalloc(r->pool, sizeof(ngx_file_t));
    if (b->file == NULL) {
        return NGX_HTTP_INTERNAL_SERVER_ERROR;
    }

    rc = ngx_http_send_header(r);

    if (rc == NGX_ERROR || rc > NGX_OK || r->header_only) {
        return rc;
    }

    b->file_pos = 0;
    b->file_last = of.size;

    b->in_file = b->file_last ? 1 : 0;
    b->last_buf = (r == r->main) ? 1 : 0;
    b->last_in_chain = 1;
    b->sync = (b->last_buf || b->in_file) ? 0 : 1;

    b->file->fd = of.fd;
    b->file->name = path;
    b->file->log = log;
    b->file->directio = of.is_directio;

    out.buf = b;
    out.next = NULL;

    return ngx_http_output_filter(r, &out);
}


static ngx_int_t
ngx_http_zstd_ok(ngx_http_request_t *r)
{
    ngx_table_elt_t  *ae;

    if (r != r->main) {
        return NGX_DECLINED;
    }

    ae = r->headers_in.accept_encoding;
    if (ae == NULL) {
        return NGX_DECLINED;
    }

    if (ae->value.len < sizeof("zstd") - 1) {
        return NGX_DECLINED;
    }

    if (ngx_memcmp(ae->value.data, "zstd,", 5) != 0
        && ngx_http_zstd_accept_encoding(&ae->value) != NGX_OK)
    {
        return NGX_DECLINED;
    }

    return NGX_OK;
}


/*
 * a copy of ngx_http_gzip_accept_encoding, for zstd content encoding
 */

static ngx_int_t
ngx_http_zstd_accept_encoding(ngx_str_t *ae)
{
    u_char  *p, *start, *last;

    start = ae->data;
    last = start + ae->len;

    for ( ;; ) {
        p = ngx_strcasestrn(start, "zstd", 4 - 1);
        if (p == NULL) {
            return NGX_DECLINED;
        }

        if (p == start || (*(p - 1) == ',' || *(p - 1) == ' ')) {
            break;
        }

        start = p + 4;
    }

    p += 4;

    while (p < last) {
        switch (*p++) {
        case ',':
            return NGX_OK;
        case ';':
            goto quantity;
        case ' ':
            continue;
        default:
            return NGX_DECLINED;
        }
    }

    return NGX_OK;

quantity:

    while (p < last) {
        switch (*p++) {
        case 'q':
        case 'Q':
            goto equal;
        case ' ':
            continue;
        default:
            return NGX_DECLINED;
        }
    }

    return NGX_OK;

equal:

    if (p + 2 > last || *p++ != '=') {
        return NGX_DECLINED;
    }

    if (ngx_http_zstd_quantity(p, last) == 0) {
        return NGX_DECLINED;
    }

    return NGX_OK;
}


/*
 * a copy of ngx_http_gzip_quantity
 */

static ngx_uint_t
ngx_http_zstd_quantity(u_char *p, u_char *last)
{
    u_char      c;
    ngx_uint_t  n, q;

    c = *p++;

    if (c != '0' && c != '1') {
        return 0;
    }

    q = (c - '0') * 100;

    if (p == last) {
        return q;
    }

    c = *p++;

    if (c == ',' || c == ' ') {
        return q;
    }

    if (c != '.') {
        return 0;
    }

    n = 0;

    while (p < last) {
        c = *p++;

        if (c == ',' || c == ' ') {
            break;
        }

        if (c >= '0' && c <= '9') {
            q += c - '0';
            n++;
            continue;
        }

        return 0;
    }

    if (q > 100 || n > 3) {
        return 0;
    }

    return q;
}


static void *
ngx_http_zstd_static_create_conf(ngx_conf_t *cf)
{
    ngx_http_zstd_static_conf_t  *conf;

    conf = ngx_palloc(cf->pool, sizeof(ngx_http_zstd_static_conf_t));
    if (conf == NULL) {
        return NULL;
    }

#if (NGX_EXPR)
    conf->enable = NGX_CONF_UNSET_PTR;
#else
    conf->enable = NGX_CONF_UNSET_UINT;
#endif

    return conf;
}


static char *
ngx_http_zstd_static_merge_conf(ngx_conf_t *cf, void *parent, void *child)
{
    ngx_http_zstd_static_conf_t *prev = parent;
    ngx_http_zstd_static_conf_t *conf = child;

#if (NGX_EXPR)
    if (ngx_conf_merge_expr_enum_value(cf, &conf->enable, prev->enable,
                                       NGX_HTTP_ZSTD_STATIC_OFF) != NGX_OK)
    {
        return NGX_CONF_ERROR;
    }
#else
    ngx_conf_merge_uint_value(conf->enable, prev->enable,
                              NGX_HTTP_ZSTD_STATIC_OFF);
#endif

    return NGX_CONF_OK;
}


static ngx_int_t
ngx_http_zstd_static_init(ngx_conf_t *cf)
{
    ngx_http_handler_pt        *h;
    ngx_http_core_main_conf_t  *cmcf;

    cmcf = ngx_http_conf_get_module_main_conf(cf, ngx_http_core_module);

    h = ngx_array_push(&cmcf->phases[NGX_HTTP_CONTENT_PHASE].handlers);
    if (h == NULL) {
        return NGX_ERROR;
    }

    *h = ngx_http_zstd_static_handler;

    return NGX_OK;
}



static ngx_int_t
ngx_http_zstd_cache_control(ngx_http_request_t *r)
{
    u_char           *p, *last, *start;
    ngx_uint_t        i, quoted;
    ngx_list_part_t  *part;
    ngx_table_elt_t  *h;

    part = &r->headers_out.headers.part;
    h = part->elts;

    for (i = 0; /* void */; i++) {
        if (i >= part->nelts) {
            if (part->next == NULL) {
                break;
            }

            part = part->next;
            h = part->elts;
            i = 0;
        }

        if (h[i].hash == 0
            || h[i].key.len != sizeof("Cache-Control") - 1
            || ngx_strncasecmp(h[i].key.data, (u_char *) "Cache-Control",
                               sizeof("Cache-Control") - 1) != 0)
        {
            continue;
        }

        p = h[i].value.data;
        last = p + h[i].value.len;

        while (p < last) {
            while (p < last && (*p == ' ' || *p == '\t' || *p == ',')) {
                p++;
            }

            start = p;

            while (p < last && *p != ' ' && *p != '\t'
                   && *p != ',' && *p != '=')
            {
                p++;
            }

            if (p - start == sizeof("no-transform") - 1
                && ngx_strncasecmp(start, (u_char *) "no-transform",
                                   sizeof("no-transform") - 1) == 0)
            {
                return NGX_DECLINED;
            }

            quoted = 0;

            while (p < last) {
                if (*p == ',' && !quoted) {
                    p++;
                    break;
                }

                if (*p == '"') {
                    quoted = !quoted;

                } else if (*p == '\\' && quoted && p + 1 < last) {
                    p++;
                }

                p++;
            }
        }
    }

    return NGX_OK;
}


static ngx_int_t
ngx_http_zstd_policy(ngx_http_request_t *r)
{
    time_t                     date, expires;
    ngx_uint_t                 p;
    ngx_table_elt_t           *e, *d, *cc;
    ngx_http_core_loc_conf_t  *clcf;

    static ngx_str_t  no_cache = ngx_string("no-cache");
    static ngx_str_t  no_store = ngx_string("no-store");
    static ngx_str_t  private = ngx_string("private");

    if (ngx_http_zstd_cache_control(r) != NGX_OK) {
        return NGX_DECLINED;
    }

    clcf = ngx_http_get_module_loc_conf(r, ngx_http_core_module);

    if (r->http_version < clcf->gzip_http_version
        || (r->headers_in.msie6 && clcf->gzip_disable_msie6))
    {
        return NGX_DECLINED;
    }

#if (NGX_HTTP_DEGRADATION)
    if (clcf->gzip_disable_degradation && ngx_http_degraded(r)) {
        return NGX_DECLINED;
    }

#endif

    if (r->headers_in.via == NULL) {
        goto ok;
    }

    p = clcf->gzip_proxied;

    if (p & NGX_HTTP_GZIP_PROXIED_OFF) {
        return NGX_DECLINED;
    }

    if (p & NGX_HTTP_GZIP_PROXIED_ANY) {
        goto ok;
    }

    if (r->headers_in.authorization && (p & NGX_HTTP_GZIP_PROXIED_AUTH)) {
        goto ok;
    }

    e = r->headers_out.expires;

    if (e) {
        if (!(p & NGX_HTTP_GZIP_PROXIED_EXPIRED)) {
            return NGX_DECLINED;
        }

        expires = ngx_parse_http_time(e->value.data, e->value.len);
        if (expires == NGX_ERROR) {
            return NGX_DECLINED;
        }

        d = r->headers_out.date;

        if (d) {
            date = ngx_parse_http_time(d->value.data, d->value.len);
            if (date == NGX_ERROR) {
                return NGX_DECLINED;
            }

        } else {
            date = ngx_time();
        }

        if (expires < date) {
            goto ok;
        }

        return NGX_DECLINED;
    }

    cc = r->headers_out.cache_control;

    if (cc) {
        if ((p & NGX_HTTP_GZIP_PROXIED_NO_CACHE)
            && ngx_http_parse_multi_header_lines(r, cc, &no_cache, NULL))
        {
            goto ok;
        }

        if ((p & NGX_HTTP_GZIP_PROXIED_NO_STORE)
            && ngx_http_parse_multi_header_lines(r, cc, &no_store, NULL))
        {
            goto ok;
        }

        if ((p & NGX_HTTP_GZIP_PROXIED_PRIVATE)
            && ngx_http_parse_multi_header_lines(r, cc, &private, NULL))
        {
            goto ok;
        }

        return NGX_DECLINED;
    }

    if ((p & NGX_HTTP_GZIP_PROXIED_NO_LM) && r->headers_out.last_modified) {
        return NGX_DECLINED;
    }

    if ((p & NGX_HTTP_GZIP_PROXIED_NO_ETAG) && r->headers_out.etag) {
        return NGX_DECLINED;
    }

ok:

#if (NGX_PCRE)
    if (clcf->gzip_disable && r->headers_in.user_agent
        && ngx_regex_exec_array(clcf->gzip_disable,
                                &r->headers_in.user_agent->value,
                                r->connection->log)
           != NGX_DECLINED)
    {
        return NGX_DECLINED;
    }

#endif

    return NGX_OK;
}
