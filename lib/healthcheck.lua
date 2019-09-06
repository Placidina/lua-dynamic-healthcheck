local _M = {_VERSION = '0.01'}

local stream_sock = ngx.socket.tcp
local log = ngx.log
local ERR = ngx.ERR
local WARN = ngx.WARN
local DEBUG = ngx.DEBUG
local sub = string.sub
local re_find = ngx.re.find
local new_timer = ngx.timer.at
local shared = ngx.shared
local debug_mode = ngx.config.debug
local concat = table.concat
local tonumber = tonumber
local tostring = tostring
local ipairs = ipairs
local ceil = math.ceil
local spawn = ngx.thread.spawn
local wait = ngx.thread.wait
local pcall = pcall

if not ngx.config or not ngx.config.ngx_lua_version or
    ngx.config.ngx_lua_version < 9005 then error("ngx_lua 0.9.5+ required") end

local ok, dynamic = pcall(require, "ngx.dynamic")
if not ok then error("lua_dynamic_upstream module required") end

local ok, new_tab = pcall(require, "table.new")
if not ok or type(new_tab) ~= "function" then
    new_tab = function(narr, nrec) return {} end
end

local list_zones = dynamic.list_zones
local describe_zone = dynamic.describe_zone
local set_peer_down = dynamic.set_peer_down

local upstream_checker_statuses = {}

local function warn(...) log(WARN, "healthcheck: ", ...) end
local function errlog(...) log(ERR, "healthcheck: ", ...) end
local function debug(...) if debug_mode then log(DEBUG, "healthcheck: ", ...) end end

local function gen_peer_key(prefix, z, server)
    return prefix .. z .. ":" .. server
end

local function set_peer_down_globally(ctx, server, value)
    local z = ctx.zone
    local dict = ctx.dict
    local ok, err = set_peer_down(z, server, value)
    if not ok then errlog("failed to set peer down: ", err) end

    if not ctx.new_version then ctx.new_version = true end

    local key = gen_peer_key("d:", z, server)
    local ok, err = dict:set(key, value)
    if not ok then errlog("failed to set peer down state: ", err) end
end

local function peer_fail(ctx, peer)
    debug("peer ", peer.name, " was checked to be not ok")

    local z = ctx.zone
    local dict = ctx.dict

    local key = gen_peer_key("nok:", z, peer.name)
    local fails, err = dict:get(key)
    if not fails then
        if err then
            errlog("failed to get peer nok key: ", err)
            return
        end

        fails = 1

        local ok, err = dict:set(key, 1)
        if not ok then errlog("failed to set peer nok key: ", err) end
    else
        fails = fails + 1
        local ok, err = dict:incr(key, 1)
        if not ok then errlog("failed to incr peer nok key: ", err) end
    end

    if fails == 1 then
        key = gen_peer_key("ok:", z, peer.name)
        local succ, err = dict:get(key)
        if not succ or succ == 0 then
            if err then
                errlog("failed to get peer ok key: ", err)
                return
            end
        else
            local ok, err = dict:set(key, 0)
            if not ok then errlog("failed to set peer ok key: ", err) end
        end
    end

    if not peer.down and fails >= ctx.fall then
        warn("peer ", peer.name, " is turned down after ", fails, " failure(s)")
        peer.down = true
        set_peer_down_globally(ctx, peer.name, true)
    end
end

local function peer_ok(ctx, peer)
    debug("peer ", peer.name, " was checked to be ok")

    local z = ctx.zone
    local dict = ctx.dict

    local key = gen_peer_key("ok:", z, peer.name)
    local succ, err = dict:get(key)
    if not succ then
        if err then
            errlog("failed to get peer ok key: ", err)
            return
        end
        succ = 1

        local ok, err = dict:set(key, 1)
        if not ok then errlog("failed to set peer ok key: ", err) end
    else
        succ = succ + 1
        local ok, err = dict:incr(key, 1)
        if not ok then errlog("failed to incr peer ok key: ", err) end
    end

    if succ == 1 then
        key = gen_peer_key("nok:", z, peer.name)
        local fails, err = dict:get(key)
        if not fails or fails == 0 then
            if err then
                errlog("failed to get peer nok key: ", err)
                return
            end
        else
            local ok, err = dict:set(key, 0)
            if not ok then
                errlog("failed to set peer nok key: ", err)
            end
        end
    end

    if peer.down and succ >= ctx.rise then
        warn("peer ", peer.name, " is turned up after ", succ, " success(es)")
        peer.down = nil
        set_peer_down_globally(ctx, peer.name, nil)
    end
end

local function peer_error(ctx, peer, ...)
    if not peer.down then errlog(...) end
    peer_fail(ctx, peer)
end

local function check_peer(ctx, peer)
    local ok
    local name = peer.name
    local statuses = ctx.statuses
    local req = ctx.http_req

    local sock, err = stream_sock()
    if not sock then
        errlog("failed to create stream socket: ", err)
        return
    end

    sock:settimeout(ctx.timeout)

    if peer.host then
        ok, err = sock:connect(peer.host, peer.port)
    else
        ok, err = sock:connect(name)
    end
    if not ok then
        if not peer.down then
            errlog("failed to connect to ", name, ": ", err)
        end
        return peer_fail(ctx, peer)
    end

    local bytes, err = sock:send(req)
    if not bytes then
        return peer_error(ctx, peer, "failed to send request to ", name, ": ",
                          err)
    end

    local status_line, err = sock:receive()
    if not status_line then
        peer_error(ctx, peer, "failed to receive status line from ", name, ": ",
                   err)
        if err == "timeout" then sock:close() end
        return
    end

    if statuses then
        local from, to, err = re_find(status_line, [[^HTTP/\d+\.\d+\s+(\d+)]],
                                      "joi", nil, 1)
        if err then errlog("failed to parse status line: ", err) end

        if not from then
            peer_error(ctx, peer, "bad status line from ", name, ": ",
                       status_line)
            sock:close()
            return
        end

        local status = tonumber(sub(status_line, from, to))
        if not statuses[status] then
            peer_error(ctx, peer, "bad status code from ", name, ": ", status)
            sock:close()
            return
        end
    end

    peer_ok(ctx, peer)
    sock:close()
end

local function check_peer_range(ctx, from, to, peers)
    for i = from, to do check_peer(ctx, peers[i]) end
end

local function check_peers(ctx, peers)
    local n = #peers
    if n == 0 then return end

    local concur = ctx.concurrency
    if concur <= 1 then
        for i = 1, n do check_peer(ctx, peers[i]) end
    else
        local threads
        local nthr

        if n <= concur then
            nthr = n - 1
            threads = new_tab(nthr, 0)
            for i = 1, nthr do
                threads[i] = spawn(check_peer, ctx, peers[i])
            end
            check_peer(ctx, peers[n])

        else
            local group_size = ceil(n / concur)
            nthr = ceil(n / group_size) - 1

            threads = new_tab(nthr, 0)
            local from = 1
            local rest = n
            for i = 1, nthr do
                local to
                if rest >= group_size then
                    rest = rest - group_size
                    to = from + group_size - 1
                else
                    rest = 0
                    to = from + rest - 1
                end

                threads[i] = spawn(check_peer_range, ctx, from, to, peers)
                from = from + group_size
                if rest == 0 then break end
            end
            if rest > 0 then
                local to = from + rest - 1
                check_peer_range(ctx, from, to, peers)
            end
        end

        if nthr and nthr > 0 then
            for i = 1, nthr do
                local t = threads[i]
                if t then wait(t) end
            end
        end
    end
end

local function upgrade_peers_version(ctx, peers)
    local dict = ctx.dict
    local z = ctx.zone
    local n = #peers

    for i = 1, n do
        local peer = peers[i]
        local key = gen_peer_key("d:", z, peer.name)
        local down = false
        local res, err = dict:get(key)

        if not res then
            if err then
                errlog("failed to get peer down state: ", err)
            end
        else
            down = true
        end

        if (peer.down and not down) or (not peer.down and down) then
            local ok, err = set_peer_down(z, peer.name, down)
            if not ok then
                errlog("failed to set peer down: ", err)
            else
                peer.down = down
            end
        end
    end
end

local function check_peers_updates(ctx)
    local dict = ctx.dict
    local z = ctx.zone
    local key = "v:" .. z
    local ver, err = dict:get(key)

    if not ver then
        if err then
            errlog("failed to get peers version: ", err)
            return
        end

        if ctx.version > 0 then ctx.new_version = true end

    elseif ctx.version < ver then
        upgrade_peers_version(ctx, ctx.peers)
        ctx.version = ver
    end
end

local function get_lock(ctx)
    local dict = ctx.dict
    local key = "l:" .. ctx.zone

    local ok, err = dict:add(key, true, ctx.interval - 0.001)
    if not ok then
        if err == "exists" then return nil end
        errlog("failed to add key \"", key, "\": ", err)
        return nil
    end

    return true
end

local function do_check(ctx)
    debug("healthcheck: run a check cycle")

    check_peers_updates(ctx)

    if get_lock(ctx) then check_peers(ctx, ctx.peers) end

    if ctx.new_version then
        local key = "v:" .. ctx.zone
        local dict = ctx.dict

        if debug_mode then
            debug("publishing peers version ", ctx.version + 1)
        end

        dict:add(key, 0)
        local new_ver, err = dict:incr(key, 1)
        if not new_ver then
            errlog("failed to publish new peers version: ", err)
        end

        ctx.version = new_ver
        ctx.new_version = nil
    end
end

local function update_upstream_checker_status(zone, success)
    local cnt = upstream_checker_statuses[zone]
    if not cnt then cnt = 0 end

    if success then
        cnt = cnt + 1
    else
        cnt = cnt - 1
    end

    upstream_checker_statuses[zone] = cnt
end

local preprocess_peers
preprocess_peers = function(peers)
    local n = #peers
    for i = 1, n do
        local p = peers[i]
        local name = p.name

        if name then
            local from, to, err = re_find(name, [[^(.*):\d+$]], "jo", nil, 1)
            if from then
                p.host = sub(name, 1, to)
                p.port = tonumber(sub(name, to + 2))
            end
        end
    end

    return peers
end

local check
check = function(premature, ctx)
    if premature then return end

    local ok, err = pcall(do_check, ctx)
    if not ok then errlog("failed to run healthcheck cycle: ", err) end

    local peers, err = describe_zone(ctx.zone)
    if not peers then
        errlog("failed to describe zone: ", err)
    else
        ctx.peers = preprocess_peers(peers)
    end

    local ok, err = new_timer(ctx.interval, check, ctx)
    if not ok then
        if err ~= "process exiting" then
            errlog("failed to create timer: ", err)
        end

        update_upstream_checker_status(ctx.zone, false)
        return
    end
end

local function gen_peers_status_info(peers, bits, idx)
    local npeers = #peers
    for i = 1, npeers do
        local peer = peers[i]

        bits[idx] = "\n        "
        bits[idx + 1] = "server " .. peer.name
        bits[idx + 2] = " weight=" .. peer.weight
        bits[idx + 3] = " max_fails=" .. peer.max_fails
        bits[idx + 4] = " fail_timeout=" .. peer.fail_timeout

        if peer.down then
            bits[idx + 5] = " DOWN\n"
        else
            bits[idx + 5] = " UP\n"
        end

        idx = idx + 6
    end

    return idx
end

function _M.spawn_checker(opts)
    local typ = opts.type
    if not typ then return nil, "\"type\" option required" end

    if typ ~= "http" then
        return nil, "only \"http\" type is supported right now"
    end

    local http_req = opts.http_req
    if not http_req then return nil, "\"http_req\" option required" end

    local timeout = opts.timeout
    if not timeout then timeout = 1000 end

    local interval = opts.interval
    if not interval then
        interval = 1

    else
        interval = interval / 1000
        if interval < 0.002 then interval = 0.002 end
    end

    local valid_statuses = opts.valid_statuses
    local statuses
    if valid_statuses then
        statuses = new_tab(0, #valid_statuses)
        for _, status in ipairs(valid_statuses) do
            statuses[status] = true
        end
    end

    local concur = opts.concurrency
    if not concur then concur = 1 end

    local fall = opts.fall
    if not fall then fall = 5 end

    local rise = opts.rise
    if not rise then rise = 2 end

    local shm = opts.shm
    if not shm then return nil, "\"shm\" option required" end

    local dict = shared[shm]
    if not dict then return nil, "shm \"" .. tostring(shm) .. "\" not found" end

    local z = opts.zone
    if not z then return nil, "no upstream zone specified" end

    local peers, err = describe_zone(z)
    if not peers then return nil, "failed to describe zone: " .. err end

    local ctx = {
        zone = z,
        peers = preprocess_peers(peers),
        http_req = http_req,
        timeout = timeout,
        interval = interval,
        dict = dict,
        fall = fall,
        rise = rise,
        statuses = statuses,
        version = 0,
        concurrency = concur
    }

    local ok, err = new_timer(0, check, ctx)
    if not ok then return nil, "failed to create timer: " .. err end

    update_upstream_checker_status(z, true)
    return true
end

function _M.status_page(z)
    local peers, err = describe_zone(z)
    if not peers then
        ngx.status = ngx.HTTP_SERVICE_UNAVAILABLE
        ngx.say("failed to describe zone: " .. err)
        ngx.exit(ngx.HTTP_SERVICE_UNAVAILABLE)
        return
    end

    local down = true
    for _, peer in ipairs(peers) do if not peer.down then down = false end end

    if down then
        ngx.status = ngx.HTTP_SERVICE_UNAVAILABLE
        ngx.say("Upstream zone " .. z .. " is down")
        ngx.exit(ngx.HTTP_SERVICE_UNAVAILABLE)
    else
        ngx.say("Upstream zone " .. z .. " ok")
    end
end

function _M.details_page()
    local zones, err = list_zones()
    if not zones then return "failed to get upstream zone names: " .. err end

    local n = #zones
    local bits = new_tab(n * 20, 0)

    local idx = 1
    for i = 1, n do
        if i > 1 then
            bits[idx] = "\n"
            idx = idx + 1
        end

        local z = zones[i]

        bits[idx] = "Upstream zone "
        bits[idx + 1] = z
        idx = idx + 2

        local ncheckers = upstream_checker_statuses[z]
        if not ncheckers or ncheckers == 0 then
            bits[idx] = " (NO checkers)"
            idx = idx + 1
        end

        local peers, err = describe_zone(z)
        if not peers then
            return "failed to describe zone " .. z .. ": " .. err
        end

        idx = gen_peers_status_info(peers, bits, idx)
    end

    return concat(bits)
end

return _M
