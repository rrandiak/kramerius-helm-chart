-- body_filter: store small responses in lua_shared_dict when gateway_mem_cache ctx is set.
local cjson = require "cjson.safe"

local function filter()
  local ctx = ngx.ctx.gateway_mem_cache
  if not ctx or not ctx.rule then
    return
  end

  local st = ngx.status or 0
  if st ~= 200 then
    ngx.ctx.gateway_mem_cache = nil
    ngx.ctx.gateway_mem_body_accum = nil
    return
  end

  local rule = ctx.rule
  local min_hits = rule.minHits or 2
  if (ctx.hits or 0) < min_hits then
    return
  end

  local cfg = require "cache_config"
  local max_b = (cfg.memory or {}).maxEntryBytes or 2097152

  local chunk, eof = ngx.arg[1], ngx.arg[2]
  if ngx.ctx.gateway_mem_body_accum == nil then
    ngx.ctx.gateway_mem_body_accum = {}
  end
  if chunk and #chunk > 0 then
    table.insert(ngx.ctx.gateway_mem_body_accum, chunk)
  end
  if not eof then
    return
  end

  local parts = ngx.ctx.gateway_mem_body_accum
  local body = table.concat(parts)
  if #body > max_b then
    ngx.ctx.gateway_mem_cache = nil
    ngx.ctx.gateway_mem_body_accum = nil
    return
  end

  local dmem = ngx.shared.gateway_cache_mem
  if not dmem then
    ngx.ctx.gateway_mem_cache = nil
    ngx.ctx.gateway_mem_body_accum = nil
    return
  end

  local hop = {}
  for k, v in pairs(ngx.header) do
    if type(k) == "string" and type(v) == "string" then
      local lk = k:lower()
      if lk ~= "connection" and lk ~= "transfer-encoding" and lk ~= "content-length" then
        hop[k] = v
      end
    end
  end

  local doc = {
    status = st,
    headers = hop,
    body = body,
  }
  local ttl = rule.ttl or 60
  local ok, err = dmem:set(ctx.key, cjson.encode(doc), ttl)
  if not ok then
    ngx.log(ngx.WARN, "gateway_cache_mem:set failed: ", err or "unknown")
  end
  ngx.ctx.gateway_mem_cache = nil
  ngx.ctx.gateway_mem_body_accum = nil
end

return { filter = filter }
