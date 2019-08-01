# lua-dynamic-healthcheck

`lua-dynamic-healthcheck` - Health-checker for Nginx dynamic upstream servers.

* [Requirements](#requirements)
* [Status](#status)
* [Synopsis](#synopsis)
* [Description](#description)
* [Methods](#methods)
  * [spawn_checker](#spawn_checker)
  * [status_page](#status_page)
  * [details_page](#details_page)
* [Multiple Upstreams](#multiple-upstreams)
* [Installation](#installation)
* [About](#about)
* [See Also](#see-also)

## Requirements

* Requires the [`lua-dynamic-module`](Placidina/lua-dynamic-module) module.
* Requires the `lua-nginx-module` or `OpenResty`.

## Status

This library is production ready.

## Synopsis

```sh
http {
    lua_package_path "/path/to/lua-dynamic-healthcheck/lib/?.lua;;";

    upstream foo {
        zone dynamic_foo 32k;

        server 127.0.0.1:8030;
        server 127.0.0.1:8031;
        server 127.0.0.1:8080 backup;
    }

    # the size depends on the number of servers in upstream {}:
    lua_shared_dict healthcheck 1m;
    lua_socket_log_errors off;

    init_worker_by_lua_block {
        local hc = require "healthcheck"

        local ok, err = hc.spawn_checker{
            shm = "healthcheck",  -- defined by "lua_shared_dict"
            zone = "dynamic_foo", -- defined by "upstream zone"
            type = "http",

            http_req = "GET /status HTTP/1.0\r\nHost: foo.com\r\n\r\n",
                    -- raw HTTP request for checking

            interval = 2000,  -- run the check cycle every 2 sec
            timeout = 1000,   -- 1 sec is the timeout for network operations
            fall = 3,  -- # of successive failures before turning a peer down
            rise = 2,  -- # of successive successes before turning a peer up
            valid_statuses = {200, 302},  -- a list valid HTTP status code
            concurrency = 10,  -- concurrency level for test requests
        }

        if not ok then
            ngx.log(ngx.ERR, "failed to spawn health checker: ", err)
            return
        end

        -- Just call hc.spawn_checker() for more times here if you have
        -- more upstream groups to monitor. One call for one upstream group.
        -- They can all share the same shm zone without conflicts but they
        -- need a bigger shm zone for obvious reasons.
    }

    server {
        ...

        location = /status {
            access_log off;

            default_type text/plain;
            content_by_lua_block {
                local hc = require "healthcheck"
                local query = ngx.req.get_uri_args()

                ngx.print(hc.status_page(query["zone"]))
            }
        }

        location = /status/details {
            access_log off;
            allow 127.0.0.1;
            deny all;

            default_type text/plain;
            content_by_lua_block {
                local hc = require "healthcheck"
                ngx.print(hc.details_page())
            }
        }
    }
}
```

## Description

This library performs healthcheck for server peers defined in NGINX upstream groups specified by names.

## Methods

### spawn_checker

**syntax:** `ok, err = healthcheck.spawn_checker(options)`
**context:** _init_worker_by_lua*_

Spawns background timer-based "light threads" to perform periodic healthchecks on the specified NGINX upstream group with the specified shm storage.

The healthchecker does not need any client traffic to function. The checks are performed actively and periodically.

This method call is asynchronous and returns immediately.

Returns true on success, or nil and a string describing an error otherwise.

### status_page

**syntax:** `str = healthcheck.status_page()`
**context:** _any_

Generates a status page report for all peers in the upstreams defined in the current NGINX server.

**output:**

All or partial peers in upstream ok:
_Status Code: `200`_

```sh
Upstream zone dynamic_foo is up
```

All peers in upstream not ok:
_Status Code: `503`_

```sh
Upstream zone dynamic_foo is down
```

### details_page

**syntax:** `str = healthcheck.details_page()`
**context:** _any_

Generates a detailed status report for all the upstreams defined in the current NGINX server.

Output is

```sh
Upstream zone dynamic_foo
        server 127.0.0.1:8030 weight=1 max_fails=1 fail_timeout=10 DOWN

Upstream zone dynamic_baar
        server 127.0.0.1:8035 weight=1 max_fails=1 fail_timeout=10 UP

```

## Multiple Upstreams

One can perform healthchecks on multiple `upstream` groups by calling the [spawn_checker](#spawn_checker) method multiple times in the `init_worker_by_lua*` handler. For example:

```sh
upstream foo {
    ...
}

upstream bar {
    ...
}

lua_shared_dict healthcheck 1m;
lua_socket_log_errors off;

init_worker_by_lua_block {
    local hc = require "healthcheck"

    local ok, err = hc.spawn_checker{
        shm = "healthcheck",
        upstream = "foo",
        ...
    }

    ...

    ok, err = hc.spawn_checker{
        shm = "healthcheck",
        upstream = "bar",
        ...
    }
}
```

Different upstreams' healthcheckers use different keys (by always prefixing the keys with the upstream name), so sharing a single `lua_shared_dict` among multiple checkers should not have any issues at all. But you need to compensate the size of the shared dict for multiple users (i.e., multiple checkers). If you have many upstreams (thousands or even more), then it is more optimal to use separate shm zones for each (group) of the upstreams.

## Installation

You need to compile both the `ngx_lua` and `lua_dynamic_upstream` modules into your Nginx.

The latest git master branch of `ngx_lua` is required.

You need to configure the lua_package_path directive to add the path of your lua-resty-upstream-healthcheck source tree to ngx_lua's Lua module search path, as in

```sh
# nginx.conf
http {
    lua_package_path "/path/to/lua-dynamic-healthcheck/lib/?.lua;;";
    ...
}
```

## About

This library meets the needs of the [lua-resty-upstream-healthcheck](https://github.com/openresty/lua-resty-upstream-healthcheck) to work for [lua-dynamic-upstream](https://github.com/Placidina/lua-dynamic-upstream) module.

## See Also

* the ngx_lua module: https://github.com/openresty/lua-nginx-module
* the lua_dynamic_upstream module: https://github.com/Placidina/lua-dynamic-upstream
* OpenResty: http://openresty.org
