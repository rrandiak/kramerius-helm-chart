-- Response caching router (runs in access_by_lua after rate limits). See cache_config.lua (Helm-generated).
local common = require "gateway_common"
local cjson = require "cjson.safe"

local function load_cfg()
  local ok, cfg = pcall(require, "cache_config")
  if ok and type(cfg) == "table" then
    return cfg
  end
  return { enabled = false, rules = {}, methods = { "GET", "HEAD" }, memory = { maxEntryBytes = 2097152 } }
end

local cache_cfg = load_cfg()

local function method_allowed(m)
  m = m or "GET"
  for _, x in ipairs(cache_cfg.methods or { "GET", "HEAD" }) do
    if x == m then
      return true
    end
  end
  return false
end

local function cache_key()
  return ngx.var.request_method .. "\0" .. (ngx.var.host or "") .. "\0" .. (ngx.var.request_uri or "/")
end

local function cache_key_hash()
  return ngx.md5(cache_key())
end

local function try_memory_hit(rule)
  local dmem = ngx.shared.gateway_cache_mem
  local dmeta = ngx.shared.gateway_cache_mem_meta
  if not dmem or not dmeta then
    return false
  end
  local h = cache_key_hash()
  local mk = "m:" .. h
  local raw = dmem:get(mk)
  if not raw then
    return false
  end
  local doc = cjson.decode(raw)
  if not doc or not doc.body then
    return false
  end
  ngx.status = doc.status or 200
  if doc.headers then
    for hk, hv in pairs(doc.headers) do
      if type(hk) == "string" and type(hv) == "string" then
        ngx.header[hk] = hv
      end
    end
  end
  ngx.header["X-Gateway-Cache"] = "HIT-MEM"
  ngx.print(doc.body)
  ngx.exit(ngx.HTTP_OK)
end

local function schedule_memory_fetch(rule)
  local dmeta = ngx.shared.gateway_cache_mem_meta
  if not dmeta then
    return
  end
  local h = cache_key_hash()
  local mk = "m:" .. h
  local meta_raw = dmeta:get(mk)
  local meta = meta_raw and cjson.decode(meta_raw) or { hits = 0 }
  meta.hits = (meta.hits or 0) + 1
  dmeta:set(mk, cjson.encode(meta), rule.ttl or 60)

  ngx.ctx.gateway_mem_cache = {
    key = mk,
    rule = rule,
    hits = meta.hits,
  }
end

local _M = {}

function _M.on_access()
  if not cache_cfg.enabled then
    return
  end
  if ngx.req.is_internal() then
    return
  end
  if not method_allowed(ngx.var.request_method) then
    return
  end

  local uri = ngx.var.uri or "/"
  for _, rule in ipairs(cache_cfg.rules or {}) do
    local fake = { pathTemplates = rule.pathTemplates }
    local matched, _tok = common.pick_rule(uri, { fake })
    if matched then
      local ct = rule.cacheType or "proxy_cache"
      if ct == "lua_shared_dict" then
        try_memory_hit(rule)
        schedule_memory_fetch(rule)
        return
      end
      if ct == "proxy_cache" and rule.namedLocation then
        return ngx.exec(rule.namedLocation)
      end
      return
    end
  end
end

return _M
