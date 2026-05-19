-- gateway_config.lua
-- Worker-local Redis config polling for gateway rate limiting.
-- Polls every RC.poll_secs; only re-reads gw:state when gw:version changes.

local common = require "gateway_common"
local RC     = require "ratelimit_config"
local redis  = require "resty.redis"
local cjson  = require "cjson.safe"
local sticky = require "sticky_balancer"

local _M = {}

local _cache        = nil   -- preprocessed config table
local _last_version = nil
local _body_cache   = {}    -- { profile_name|"" → partial 429 body (no __TITLE__) }

-- ── Redis connection ──────────────────────────────────────────────────────────

local function redis_connect()
  local r = redis:new()
  r:set_timeout(1000)
  local ok, err = r:connect(RC.redis.host, RC.redis.port)
  if not ok then
    ngx.log(ngx.WARN, "gateway_config: redis connect failed: ", err)
    return nil
  end
  if RC.redis.password and RC.redis.password ~= "" then
    local res, auth_err = r:auth(RC.redis.password)
    if not res then
      ngx.log(ngx.WARN, "gateway_config: redis auth failed: ", auth_err)
      r:close()
      return nil
    end
  end
  return r
end

-- ── preprocessing ─────────────────────────────────────────────────────────────

local function preprocess(raw)
  local cfg = {
    peak          = raw.peak,
    bans          = {},
    profiles      = raw.users or {},
    global_rules  = {},
    profile_rules = {},
  }
  -- raw.bans is a list of {target, reason, banned_at} objects from State.to_dict()
  for _, b in ipairs(raw.bans or {}) do
    table.insert(cfg.bans, b.target)
  end
  for _, r in ipairs(raw.rules or {}) do
    local lua_rule = {
      pathTemplates      = r.endpoints or {},
      windowSeconds      = r.rl_window,
      peakMaxRequests    = r.rl_peak,
      offPeakMaxRequests = r.rl_off,
      dlWindowSeconds    = r.dl_window,
      peakMaxBytes       = r.dl_peak,
      offPeakMaxBytes    = r.dl_off,
    }
    if not r.user_refs or #r.user_refs == 0 then
      table.insert(cfg.global_rules, lua_rule)
    else
      for _, uref in ipairs(r.user_refs) do
        cfg.profile_rules[uref] = cfg.profile_rules[uref] or {}
        table.insert(cfg.profile_rules[uref], lua_rule)
      end
    end
  end
  return cfg
end

-- ── polling ───────────────────────────────────────────────────────────────────

local function poll(premature)
  if premature then return end

  local r = redis_connect()
  if not r then return end

  local ver, ver_err = r:get("gw:version")
  if not ver or ver == ngx.null then
    if ver_err then
      ngx.log(ngx.WARN, "gateway_config: GET gw:version: ", ver_err)
    end
    r:close()
    return
  end

  if ver == _last_version then
    r:close()
    return
  end

  local raw_json, state_err = r:get("gw:state")
  r:close()

  if not raw_json or raw_json == ngx.null then
    if state_err then
      ngx.log(ngx.WARN, "gateway_config: GET gw:state: ", state_err)
    end
    return
  end

  local ok, state = pcall(cjson.decode, raw_json)
  if not ok or type(state) ~= "table" then
    ngx.log(ngx.WARN, "gateway_config: JSON decode failed")
    return
  end

  _last_version = ver
  _cache        = preprocess(state)
  _body_cache   = {}
end

function _M.init()
  ngx.timer.at(0, poll)
  ngx.timer.every(RC.poll_secs, poll)

  -- Load balancer: register backends and start DNS refresh.
  -- Always active (required for headless services); session_affinity.enabled
  -- controls whether selection uses sticky hashing or round-robin.
  local sa = RC.session_affinity or {}
  for _, b in ipairs(sa.backends or {}) do
    sticky.add_backend(b.name, b.dns_name, b.port, b.fallback)
  end
  sticky.init(sa.enabled ~= false, sa.refresh_interval)
end

-- ── public API ────────────────────────────────────────────────────────────────

-- Returns the current preprocessed config, or nil if not yet loaded.
-- Callers must handle nil (fail open — do not rate limit).
function _M.get()
  return _cache
end

-- Returns (rule, match_token) for path and profile, or (nil, nil).
-- Tries per-profile rules first, then global rules.
function _M.find_rule(path, profile_name)
  if not _cache then return nil, nil end
  if profile_name and _cache.profile_rules[profile_name] then
    local rule, tok = common.pick_rule(path, _cache.profile_rules[profile_name])
    if rule then return rule, tok end
  end
  return common.pick_rule(path, _cache.global_rules)
end

-- Returns and caches a partially-rendered 429 body (__LIMITS_BLOCK__ substituted,
-- __TITLE__ left as placeholder). Cache cleared on config change.
function _M.get_partial_429(profile_name, build_fn)
  local ck = profile_name or ""
  if not _body_cache[ck] then
    _body_cache[ck] = build_fn(_cache, profile_name)
  end
  return _body_cache[ck]
end

return _M
