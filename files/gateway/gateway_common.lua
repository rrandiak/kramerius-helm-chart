local cjson = require "cjson.safe"

local _M = {}

-- cjson decodes JSON null as cjson.null (truthy lightuserdata), not nil.
-- Use this to check whether a JSON field was actually set to a real value.
local function is_set(v)
  return v ~= nil and v ~= cjson.null
end

function _M.client_ip()
  return ngx.var.remote_addr or "unknown"
end

-- Escape literal for ngx.re (PCRE) after splitting out {placeholder} segments.
local function escape_pcre_literal(s)
  local r = s
  r = r:gsub("\\", "\\\\")
  r = r:gsub("%^", "\\^")
  r = r:gsub("%$", "\\$")
  r = r:gsub("%(", "\\(")
  r = r:gsub("%)", "\\)")
  r = r:gsub("%[", "\\[")
  r = r:gsub("%]", "\\]")
  r = r:gsub("%+", "\\+")
  r = r:gsub("%-", "\\-")
  r = r:gsub("%*", "\\*")
  r = r:gsub("%?", "\\?")
  r = r:gsub("%.", "\\.")
  r = r:gsub("%|", "\\|")
  r = r:gsub("%{", "\\{")
  r = r:gsub("%}", "\\}")
  return r
end

-- Catalog paths use {name} for a single path segment; in OpenResty this becomes [^/]+
function _M.template_to_regex(tmpl)
  local parts = {}
  local pos = 1
  local len = #tmpl
  while pos <= len do
    local open_brace = tmpl:find("{", pos, true)
    if not open_brace then
      table.insert(parts, escape_pcre_literal(tmpl:sub(pos)))
      break
    end
    if open_brace > pos then
      table.insert(parts, escape_pcre_literal(tmpl:sub(pos, open_brace - 1)))
    end
    local close_brace = tmpl:find("}", open_brace + 1, true)
    if not close_brace then
      ngx.log(ngx.ERR, "gateway: unclosed { in path template: ", tmpl)
      return "^$"
    end
    table.insert(parts, "[^/]+")
    pos = close_brace + 1
  end
  return "^" .. table.concat(parts) .. "$"
end

function _M.uri_matches_template(uri, tmpl)
  local re = _M.template_to_regex(tmpl)
  return ngx.re.match(uri, re, "jo") ~= nil
end

-- Returns rule, match_token (string for rate-limit key; template matched or legacy prefix/suffix).
function _M.pick_rule(uri, rules)
  if not rules then return nil, nil end
  for _, rule in ipairs(rules) do
    if rule.pathTemplates ~= nil then
      if #rule.pathTemplates == 0 then
        -- catch-all for this rule (same semantics as empty endpoint list in docs)
        return rule, "*"
      end
      for _, tmpl in ipairs(rule.pathTemplates) do
        if _M.uri_matches_template(uri, tmpl) then
          return rule, tmpl
        end
      end
    elseif rule.pathPrefix then
      local prefix = rule.pathPrefix or "/"
      if string.sub(uri, 1, #prefix) == prefix then
        local suffix = rule.pathSuffix
        if not suffix or suffix == "" or string.sub(uri, -#suffix) == suffix then
          return rule, prefix .. (suffix or "")
        end
      end
    end
  end
  return nil, nil
end

function _M.ep_token(prefix)
  return ngx.md5(prefix):sub(1, 16)
end

local function ip_to_int(ip)
  local o1, o2, o3, o4 = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not o1 then return nil end
  return tonumber(o1) * 16777216 + tonumber(o2) * 65536 + tonumber(o3) * 256 + tonumber(o4)
end

function _M.ip_in_cidrs(ip, cidrs)
  if not cidrs or #cidrs == 0 then return false end
  local ip_int = ip_to_int(ip)
  if not ip_int then return false end
  for _, entry in ipairs(cidrs) do
    local net, mask_len = entry:match("^(.+)/(%d+)$")
    if net then
      local net_int = ip_to_int(net)
      local bits = tonumber(mask_len)
      if net_int and bits >= 0 and bits <= 32 then
        local shift = 2 ^ (32 - bits)
        if math.floor(ip_int / shift) == math.floor(net_int / shift) then
          return true
        end
      end
    else
      if ip == entry then return true end
    end
  end
  return false
end

-- ── CDK reader IP ────────────────────────────────────────────────────────────
-- Kramerius CDK forwards each reader's address in CDK-TOKEN-PARAMETERS as …|header_ip_address=<ip>|….
-- Only a connection from trustedProxyCidrs may speak for another address; from anywhere else the
-- header is ignored, or any client could claim a fresh rate-limit identity on every request.
-- The underscore spelling of the header is never seen: nginx drops it (underscores_in_headers off).

local function is_ip_literal(s)
  local o1, o2, o3, o4 = s:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if o1 then
    return tonumber(o1) <= 255 and tonumber(o2) <= 255
       and tonumber(o3) <= 255 and tonumber(o4) <= 255
  end
  return #s <= 45 and s:find(":", 1, true) ~= nil and s:match("^[%x:]+$") ~= nil
end

-- Returns the reader IP from the CDK header, or nil when the source is untrusted or the value
-- is missing or not a literal address.
function _M.cdk_reader_ip(req_ip, trusted_cidrs)
  if not _M.ip_in_cidrs(req_ip, trusted_cidrs) then return nil end
  local value = ngx.req.get_headers()["cdk-token-parameters"]
  if type(value) == "table" then value = value[1] end
  if type(value) ~= "string" then return nil end
  local ip = value:match("header_ip_address=([^|]*)")
  if not ip then return nil end
  ip = ip:match("^%s*([^,]*)")
  ip = ip and ip:match("^(.-)%s*$")
  if not ip or not is_ip_literal(ip) then return nil end
  return ip
end

-- ── profile matching ─────────────────────────────────────────────────────────

local function profile_matches(p, req_ip, req_username)
  -- degenerate profile with no identifiers matches nothing
  if not is_set(p.ip) and not is_set(p.username) and not next(p.headers or {}) then
    return false
  end
  if is_set(p.ip) and not _M.ip_in_cidrs(req_ip, { p.ip }) then
    return false
  end
  if is_set(p.username) and p.username ~= req_username then
    return false
  end
  for k, v in pairs(p.headers or {}) do
    -- nginx header variable: lowercase, hyphens → underscores
    if ngx.var["http_" .. k:lower():gsub("-", "_")] ~= v then
      return false
    end
  end
  return true
end

-- Returns the name of the first matching profile, or nil.
function _M.match_profile(profiles, req_ip, req_username)
  for _, p in ipairs(profiles or {}) do
    if profile_matches(p, req_ip, req_username) then
      return p.name
    end
  end
  return nil
end

-- ── DNS ──────────────────────────────────────────────────────────────────────
-- Resolved explicitly instead of handing connect() a hostname. Cosocket name resolution is bounded
-- by nginx's resolver_timeout (30s by default) and *not* by tcpsock:settimeout(), which covers only
-- connect/send/receive — so a DNS failure stalled the entire request for 30s, silently, because
-- lua_socket_log_errors was off. Resolving here keeps the timeout ours and hands connect() a
-- literal IP. This is the same approach sticky_balancer already takes for backend pods.

local _nameservers

local function nameservers()
  if _nameservers then return _nameservers end
  local ns = {}
  local f = io.open("/etc/resolv.conf", "r")
  if f then
    for line in f:lines() do
      local ip = line:match("^nameserver%s+(%S+)")
      if ip then table.insert(ns, ip) end
    end
    f:close()
  end
  _nameservers = #ns > 0 and ns or { "10.96.0.10" }
  return _nameservers
end

--- Resolve a hostname to an IPv4 address, cached in rate_misc. Returns nil on failure.
local function resolve_host(host, timeout_ms, retrans, cache_secs)
  if host:match("^%d+%.%d+%.%d+%.%d+$") then return host end

  local cache_key = "dns:" .. host
  local cached = ngx.shared.rate_misc:get(cache_key)
  if cached then return cached end

  local resolver = require "resty.dns.resolver"
  local r, err = resolver:new{
    nameservers = nameservers(),
    retrans     = retrans,
    timeout     = timeout_ms,
  }
  if not r then
    ngx.log(ngx.WARN, "resolve_host: resolver init failed for ", host, ": ", err)
    return nil
  end

  local answers, qerr = r:query(host, { qtype = 1 })  -- TYPE_A
  if not answers or answers.errcode then
    ngx.log(ngx.WARN, "resolve_host: query failed for ", host, ": ",
      qerr or (answers and answers.errstr) or "unknown")
    return nil
  end

  for _, ans in ipairs(answers) do
    if ans.type == 1 then
      if cache_secs > 0 then
        ngx.shared.rate_misc:set(cache_key, ans.address, cache_secs)
      end
      return ans.address
    end
  end
  ngx.log(ngx.WARN, "resolve_host: no A record for ", host)
  return nil
end

--- Public wrapper with defaults, for any cosocket that would otherwise connect by hostname.
function _M.resolve_host(host, timeout_ms, retrans, cache_secs)
  return resolve_host(host, timeout_ms or 3000, retrans or 2, cache_secs or 30)
end

-- ── username resolution ──────────────────────────────────────────────────────

local function fetch_username(token, url, tm)
  local host, path = url:match("^http://([^/]+)(/.+)$")
  if not host then return nil end
  local h, p_str = host:match("^(.+):(%d+)$")
  h = h or host
  local port = tonumber(p_str) or 80

  -- Host header keeps the name; only connect() gets the address.
  local addr = resolve_host(h, tm.dns_timeout_ms, tm.dns_retrans, tm.dns_cache_secs)
  if not addr then return nil end

  local sock = ngx.socket.tcp()
  sock:settimeout(tm.socket_timeout_ms)
  local ok = sock:connect(addr, port)
  if not ok then sock:close(); return nil end
  local req = "GET " .. path .. " HTTP/1.0\r\n"
           .. "Host: " .. h .. "\r\n"
           .. "Authorization: Bearer " .. token .. "\r\n"
           .. "Connection: close\r\n\r\n"
  if not sock:send(req) then sock:close(); return nil end
  -- skip HTTP response headers
  while true do
    local line = sock:receive("*l")
    if not line or line == "" or line == "\r" then break end
  end
  local body = sock:receive("*a")
  sock:close()
  if not body or body == "" then return nil end
  local cjson = require "cjson.safe"
  local ok2, data = pcall(cjson.decode, body)
  if not ok2 or type(data) ~= "table" then return nil end
  return data.uid
end

-- Worst case per cache miss is dns_timeout_ms * dns_retrans, then the socket timeout per
-- connect/send/receive. Failures cache "" for cache_ttl, so a miss cannot repeat every request.
local DEFAULT_TIMEOUTS = {
  dns_timeout_ms    = 3000,
  dns_retrans       = 2,
  dns_cache_secs    = 30,
  socket_timeout_ms = 3000,
}

-- Resolves the username from the Bearer token in the current request.
-- Returns a string username, or nil if not authenticated / resolution disabled.
-- cache_ttl: seconds to cache result in rate_misc shared dict (0 = no cache).
-- url: Kramerius user API endpoint, e.g. http://kramerius-public.NS.svc.../user
-- timeouts: optional overrides for DEFAULT_TIMEOUTS.
function _M.resolve_username(cache_ttl, url, timeouts)
  local auth = ngx.var.http_authorization
  if not auth then return nil end
  local token = auth:match("^[Bb]earer%s+(.+)$")
  if not token then return nil end

  local cache_key = "usr:" .. ngx.md5(token)
  local cached = ngx.shared.rate_misc:get(cache_key)
  if cached ~= nil then
    return cached ~= "" and cached or nil
  end

  local tm = {}
  for k, v in pairs(DEFAULT_TIMEOUTS) do
    tm[k] = (timeouts and timeouts[k]) or v
  end

  local username = fetch_username(token, url, tm) or ""
  if cache_ttl and cache_ttl > 0 then
    ngx.shared.rate_misc:set(cache_key, username, cache_ttl)
  end
  return username ~= "" and username or nil
end

return _M
