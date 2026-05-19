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

-- ── username resolution ──────────────────────────────────────────────────────

local function fetch_username(token, url)
  local sock = ngx.socket.tcp()
  sock:settimeout(1000)
  local host, path = url:match("^http://([^/]+)(/.+)$")
  if not host then sock:close(); return nil end
  local h, p_str = host:match("^(.+):(%d+)$")
  h = h or host
  local port = tonumber(p_str) or 80
  local ok = sock:connect(h, port)
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

-- Resolves the username from the Bearer token in the current request.
-- Returns a string username, or nil if not authenticated / resolution disabled.
-- cache_ttl: seconds to cache result in rate_misc shared dict (0 = no cache).
-- url: Kramerius user API endpoint, e.g. http://kramerius-public.NS.svc.../user
function _M.resolve_username(cache_ttl, url)
  local auth = ngx.var.http_authorization
  if not auth then return nil end
  local token = auth:match("^[Bb]earer%s+(.+)$")
  if not token then return nil end

  local cache_key = "usr:" .. ngx.md5(token)
  local cached = ngx.shared.rate_misc:get(cache_key)
  if cached ~= nil then
    return cached ~= "" and cached or nil
  end

  local username = fetch_username(token, url) or ""
  if cache_ttl and cache_ttl > 0 then
    ngx.shared.rate_misc:set(cache_key, username, cache_ttl)
  end
  return username ~= "" and username or nil
end

return _M
