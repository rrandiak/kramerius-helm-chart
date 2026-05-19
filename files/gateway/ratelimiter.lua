-- ratelimiter.lua
-- nginx phase handlers: on_access (GCRA rate), on_header_filter (GCRA download),
-- on_body_filter (429 body swap), build_429 (response body).

local common      = require "gateway_common"
local gw_config   = require "gateway_config"
local RC          = require "ratelimit_config"

local _M = {}

-- ── helpers ───────────────────────────────────────────────────────────────────

local function is_peak_hour(peak)
  if not peak then return false end
  local h = os.date("*t").hour
  local f, t = peak.from, peak.to
  if f == t then return false end
  if f < t then return h >= f and h < t end
  return h >= f or h < t
end

local function fmt_bytes(n)
  n = tonumber(n) or 0
  if n >= 1073741824 then return string.format("%.1f GiB", n / 1073741824)
  elseif n >= 1048576 then return string.format("%.1f MiB", n / 1048576)
  elseif n >= 1024    then return string.format("%.1f KiB", n / 1024)
  else return tostring(n) .. " B" end
end

local function fmt_window(secs)
  secs = tonumber(secs) or 0
  if secs >= 3600 then return string.format("%gh",  secs / 3600)
  elseif secs >= 60 then return string.format("%gm", secs / 60)
  else return secs .. "s" end
end

local function fmt_rate(peak_req, off_req, window)
  if peak_req == off_req then
    return string.format("%d req per %s", peak_req, fmt_window(window))
  end
  return string.format("%d/%d req per %s peak/off-peak", peak_req, off_req, fmt_window(window))
end

local function fmt_dl(peak_b, off_b, window)
  if peak_b == off_b then
    return string.format("%s per %s", fmt_bytes(peak_b), fmt_window(window))
  end
  return string.format("%s/%s per %s peak/off-peak",
    fmt_bytes(peak_b), fmt_bytes(off_b), fmt_window(window))
end

local function fmt_rule_line(r)
  local ep = (#(r.pathTemplates or {}) == 0)
    and "(all endpoints)"
    or  table.concat(r.pathTemplates, ", ")
  return string.format("    %-45s  %s  |  %s",
    ep,
    fmt_rate(r.peakMaxRequests, r.offPeakMaxRequests, r.windowSeconds),
    fmt_dl(r.peakMaxBytes, r.offPeakMaxBytes, r.dlWindowSeconds))
end

local function build_limits_block(cfg, profile_name)
  if not cfg then return "(limits not available)" end
  local lines = { "Active limits:\n", "  All users:" }
  for _, r in ipairs(cfg.global_rules) do
    table.insert(lines, fmt_rule_line(r))
  end
  if #cfg.global_rules == 0 then
    table.insert(lines, "    (none configured)")
  end
  if profile_name and cfg.profile_rules[profile_name] then
    table.insert(lines, "")
    table.insert(lines, "  Your profile [" .. profile_name .. "]:")
    for _, r in ipairs(cfg.profile_rules[profile_name]) do
      table.insert(lines, fmt_rule_line(r))
    end
  end
  return table.concat(lines, "\n")
end

-- ── 429 body ─────────────────────────────────────────────────────────────────

local TMPL, TITLES   -- loaded lazily on first 429

local function ensure_templates_loaded()
  if TMPL then return end
  local f = io.open("/etc/nginx/errors/429.body", "r")
  TMPL = f and f:read("*a") or "__TITLE__\nToo Many Requests\n"
  if f then f:close() end

  TITLES = {}
  local f2 = io.open("/etc/nginx/errors/429.titles", "r")
  if f2 then
    for line in f2:read("*a"):gmatch("[^\n]+") do
      if #line > 0 then table.insert(TITLES, line) end
    end
    f2:close()
  end
  if #TITLES == 0 then TITLES = { "Too Many Requests" } end
end

local function build_partial_429(cfg, profile_name)
  ensure_templates_loaded()
  return TMPL:gsub("__LIMITS_BLOCK__", build_limits_block(cfg, profile_name))
end

local function build_429(cfg, profile_name)
  ensure_templates_loaded()
  local partial = gw_config.get_partial_429(profile_name, build_partial_429)
  local idx = (ngx.shared.rate_misc:incr("t429_idx", 1, 0) - 1) % #TITLES + 1
  return partial:gsub("__TITLE__", TITLES[idx])
end

-- ── GCRA ─────────────────────────────────────────────────────────────────────

local function gcra_check(dict, key, tat_now, increment, burst_gap, ttl)
  -- Returns true (allow) or false, retry_after_secs
  local tat = dict:get(key) or 0
  local now = tat_now
  if now < tat - burst_gap then
    return false, math.ceil((tat - burst_gap) - now)
  end
  dict:set(key, math.max(now, tat) + increment, ttl)
  return true
end

-- ── phase handlers ────────────────────────────────────────────────────────────

function _M.on_access()
  -- Set client IP and backend for the balancer (persists across internal redirects)
  if not ngx.ctx.sticky_client_ip then
    ngx.ctx.sticky_client_ip = common.client_ip()
  end
  local uri = ngx.var.request_uri or "/"
  local cp  = ngx.var.curator_path_prefix or ""
  ngx.ctx.sticky_backend = (#cp > 0 and uri:sub(1, #cp) == cp)
    and "curator" or "public"

  -- internal sub-requests (e.g. cache named locations): skip rate limiting
  if ngx.req.is_internal() then return end

  local cfg = gw_config.get()
  if not cfg then return end  -- config not yet loaded, fail open

  local req_ip = ngx.ctx.sticky_client_ip

  -- 1. ban check
  if common.ip_in_cidrs(req_ip, cfg.bans) then
    ngx.exit(403)
    return
  end

  -- 2. optional username resolution
  local req_username = nil
  if RC.user_resolution.enabled then
    req_username = common.resolve_username(
      RC.user_resolution.cache_ttl,
      RC.user_resolution.url
    )
  end

  -- 3. profile match → identity key
  local profile_name = common.match_profile(cfg.profiles, req_ip, req_username)
  local identity     = profile_name or req_ip
  ngx.ctx.rl_identity = identity
  ngx.ctx.rl_profile  = profile_name
  ngx.var.actor       = profile_name or ""

  -- 4. rule lookup
  local path = ngx.var.uri or "/"
  local rule, match_tok = gw_config.find_rule(path, profile_name)

  if rule then
    local is_peak = is_peak_hour(cfg.peak)
    local max_req = is_peak and rule.peakMaxRequests or rule.offPeakMaxRequests

    -- 5. GCRA rate check (fixed cost = 1 request)
    if max_req and max_req > 0 then
      local increment = rule.windowSeconds / max_req
      local burst_gap = RC.rl_burst * rule.windowSeconds
      local key       = "rl:v2:" .. identity .. ":" .. common.ep_token(match_tok)
      local ttl       = rule.windowSeconds * 2

      local allowed, retry_after = gcra_check(
        ngx.shared.gateway_rl, key, ngx.now(), increment, burst_gap, ttl)
      if not allowed then
        ngx.status = 429
        ngx.header["Content-Type"] = "text/plain; charset=utf-8"
        ngx.header["Retry-After"]  = tostring(retry_after)
        ngx.say(build_429(cfg, profile_name))
        ngx.exit(429)
        return
      end
    end

    -- 6. store download context for on_header_filter
    local max_bytes = is_peak and rule.peakMaxBytes or rule.offPeakMaxBytes
    if max_bytes and max_bytes > 0 then
      ngx.ctx.dl_key       = "dl:v2:" .. identity .. ":" .. common.ep_token(match_tok)
      ngx.ctx.dl_max       = max_bytes
      ngx.ctx.dl_window    = rule.dlWindowSeconds
      ngx.ctx.dl_burst_gap = RC.dl_burst * rule.dlWindowSeconds
    end
  end

  -- 7. upstream set by balancer_by_lua (no action needed here)

  local rc_mod = require "response_cache"
  rc_mod.on_access()
end

function _M.on_header_filter()
  if not ngx.ctx.dl_key then return end

  local cl = tonumber(ngx.var.upstream_http_content_length)
  if not cl or cl <= 0 then return end   -- no Content-Length → skip

  local byte_rate = ngx.ctx.dl_max / ngx.ctx.dl_window
  local increment = cl / byte_rate         -- seconds this download costs
  local burst_gap = ngx.ctx.dl_burst_gap
  local ttl       = ngx.ctx.dl_window * 2

  local allowed, retry_after = gcra_check(
    ngx.shared.gateway_dl, ngx.ctx.dl_key,
    ngx.now(), increment, burst_gap, ttl)

  if not allowed then
    ngx.ctx.dl_429 = true
    ngx.status     = ngx.HTTP_TOO_MANY_REQUESTS
    ngx.header["Content-Type"]   = "text/plain; charset=utf-8"
    ngx.header["Retry-After"]    = tostring(retry_after)
    ngx.header["Content-Length"] = nil
  end
end

function _M.on_body_filter()
  if not ngx.ctx.dl_429 then return end
  local cfg = gw_config.get()
  ngx.arg[1] = build_429(cfg, ngx.ctx.rl_profile)
  ngx.arg[2] = true   -- EOF
end

return _M
