-- sticky_balancer.lua
-- Client-IP-based sticky routing with failover across kramerius pods.
-- Resolves headless service DNS to discover pod IPs, picks a backend using
-- consistent hashing on the real client IP (from X-Forwarded-For), and
-- retries the next pod in the ring when a connection fails.
--
-- Used in two places:
--   init_worker_by_lua  → init() registers backends and starts DNS refresh
--   balancer_by_lua     → balance() selects a peer for each connection attempt

local _M = {}

local resolver = require "resty.dns.resolver"

-- per-backend state: { dns_name, port, pods = {"10.0.0.1", ...}, fallback_host }
local _backends = {}
local _enabled = false
local _refresh_interval = 5
local _nameservers = nil

-- ── helpers ──────────────────────────────────────────────────────────────────

local function get_nameservers()
    local f = io.open("/etc/resolv.conf", "r")
    if not f then return { "10.96.0.10" } end
    local ns = {}
    for line in f:lines() do
        local ip = line:match("^nameserver%s+(%S+)")
        if ip then table.insert(ns, ip) end
    end
    f:close()
    return #ns > 0 and ns or { "10.96.0.10" }
end

local function parse_host_port(url)
    local host, port = url:match("^https?://([^:/]+):(%d+)")
    if host then return host, tonumber(port) end
    host = url:match("^https?://([^:/]+)")
    return host or "127.0.0.1", 8080
end

local function resolve_a_records(dns_name)
    local r, err = resolver:new{
        nameservers = _nameservers,
        retrans = 2,
        timeout = 2000,
    }
    if not r then
        ngx.log(ngx.WARN, "sticky_balancer: resolver init failed: ", err)
        return nil
    end

    local answers, err2 = r:query(dns_name, { qtype = 1 })  -- TYPE_A
    if not answers or answers.errcode then
        ngx.log(ngx.WARN, "sticky_balancer: DNS query failed for ",
            dns_name, ": ", err2 or (answers and answers.errstr) or "unknown")
        return nil
    end

    local ips = {}
    for _, ans in ipairs(answers) do
        if ans.type == 1 then
            table.insert(ips, ans.address)
        end
    end
    table.sort(ips)  -- stable ordering for consistent hashing
    return ips
end

local function refresh(premature)
    if premature then return end
    for _, b in pairs(_backends) do
        local new_pods = resolve_a_records(b.dns_name)
        if new_pods and #new_pods > 0 then
            b.pods = new_pods
        end
    end
end

-- ── public API ───────────────────────────────────────────────────────────────

--- Register a backend for load balancing.
-- @param name      short key, e.g. "public" or "curator"
-- @param dns_name  headless service FQDN
-- @param port      container port (e.g. 8080)
-- @param fallback  full URL to use when DNS fails (e.g. "http://kramerius-public.ns:8080")
function _M.add_backend(name, dns_name, port, fallback)
    local fb_host, fb_port = parse_host_port(fallback or ("http://" .. dns_name .. ":" .. port))
    _backends[name] = {
        dns_name      = dns_name,
        port          = port,
        pods          = {},
        fallback_host = fb_host,
        fallback_port = fb_port,
    }
end

--- Start periodic DNS refresh. Call from init_worker_by_lua.
-- @param enabled          true = sticky hash, false = round-robin
-- @param refresh_interval seconds between DNS re-resolves
function _M.init(enabled, refresh_interval)
    _enabled = enabled
    _refresh_interval = refresh_interval or 5
    _nameservers = get_nameservers()
    ngx.timer.at(0, refresh)
    ngx.timer.every(_refresh_interval, refresh)
end

--- Balancer entry point — called from balancer_by_lua_block on each
--- connection attempt (initial + retries via proxy_next_upstream).
---
--- Reads from ngx.ctx:
---   sticky_backend    "public" or "curator" (set by ratelimiter.on_access)
---   sticky_client_ip  real client IP (set by ratelimiter.on_access)
function _M.balance()
    local balancer = require "ngx.balancer"
    local ctx = ngx.ctx

    local backend_name = ctx.sticky_backend or "public"
    local b = _backends[backend_name]

    if not b or not b.pods or #b.pods == 0 then
        -- No pods discovered; fall back to service hostname
        local ok, err = balancer.set_current_peer(
            b and b.fallback_host or "127.0.0.1",
            b and b.fallback_port or 8080)
        if not ok then
            ngx.log(ngx.ERR, "sticky_balancer: fallback set_current_peer failed: ", err)
        end
        return
    end

    -- Detect first try vs retry (proxy_next_upstream triggered)
    local state = balancer.get_last_failure()
    if not state then
        -- First attempt: allow retrying all remaining pods
        ctx.balancer_try = 1
        if #b.pods > 1 then
            balancer.set_more_tries(#b.pods - 1)
        end
    else
        -- Retry: advance to the next pod in the ring
        ctx.balancer_try = (ctx.balancer_try or 1) + 1
    end

    local idx
    if _enabled and ctx.sticky_client_ip then
        -- Sticky: consistent hash with linear probe on retry
        local base = ngx.crc32_long(ctx.sticky_client_ip) % #b.pods
        idx = (base + ctx.balancer_try - 1) % #b.pods + 1
    else
        -- Round-robin when sticky is disabled
        if not ctx.rr_base then
            ctx.rr_base = ngx.shared.rate_misc:incr(
                "sb:rr:" .. backend_name, 1, 0)
        end
        idx = ((ctx.rr_base - 1) + ctx.balancer_try - 1) % #b.pods + 1
    end

    local ok, err = balancer.set_current_peer(b.pods[idx], b.port)
    if not ok then
        ngx.log(ngx.ERR, "sticky_balancer: set_current_peer failed: ", err)
    end
end

return _M
