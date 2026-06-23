local M = {}

function M.deep_extend(...)
  return vim.tbl_deep_extend("force", ...)
end

function M.redact(s)
  if not s then
    return s
  end
  s = tostring(s)
  s = s:gsub("Bearer%s+[%w%._%-]+", "Bearer <redacted>")
  s = s:gsub('"access_token"%s*:%s*"[^"]+"', '"access_token":"<redacted>"')
  s = s:gsub('"refresh_token"%s*:%s*"[^"]+"', '"refresh_token":"<redacted>"')
  s = s:gsub('"id_token"%s*:%s*"[^"]+"', '"id_token":"<redacted>"')
  return s
end

function M.expand(path)
  return vim.fn.expand(path)
end

function M.read_file(path)
  local fd = io.open(path, "r")
  if not fd then
    return nil, "Could not open " .. path
  end
  local body = fd:read("*a")
  fd:close()
  return body, nil
end

function M.write_file_secure(path, body)
  local tmp = path .. ".tmp"
  local fd = io.open(tmp, "w")
  if not fd then
    return nil, "Could not open temporary file for writing"
  end

  fd:write(body)
  fd:close()

  if vim.uv and vim.uv.fs_chmod then
    pcall(vim.uv.fs_chmod, tmp, 384) -- 0600
  elseif vim.loop and vim.loop.fs_chmod then
    pcall(vim.loop.fs_chmod, tmp, 384) -- 0600
  else
    pcall(vim.fn.system, { "chmod", "600", tmp })
  end

  local ok, err = os.rename(tmp, path)
  if not ok then
    return nil, "Could not replace file: " .. tostring(err)
  end

  return true, nil
end

function M.json_decode(s)
  local ok, value = pcall(vim.json.decode, s)
  if ok then
    return value, nil
  end
  return nil, value
end

function M.json_encode(value)
  local ok, encoded = pcall(vim.json.encode, value)
  if ok then
    return encoded, nil
  end
  return nil, encoded
end

function M.system_json(cmd, opts, cb)
  if type(opts) == "function" then
    cb = opts
    opts = {}
  end

  vim.system(cmd, vim.tbl_extend("force", { text = true }, opts or {}), function(res)
    if res.code ~= 0 then
      cb(nil, M.redact((res.stderr and res.stderr ~= "") and res.stderr or res.stdout or "unknown error"), res)
      return
    end

    local data, err = M.json_decode(res.stdout)
    if not data then
      cb(nil, "Could not parse JSON response: " .. tostring(err), res)
      return
    end

    cb(data, nil, res)
  end)
end

local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64url_to_base64(input)
  local out = input:gsub("-", "+"):gsub("_", "/")
  local pad = #out % 4
  if pad == 2 then
    out = out .. "=="
  elseif pad == 3 then
    out = out .. "="
  elseif pad == 1 then
    out = out .. "==="
  end
  return out
end

local function base64_decode(data)
  data = data:gsub("[^" .. b64chars .. "=]", "")
  return (data:gsub(".", function(x)
    if x == "=" then
      return ""
    end
    local r, f = "", (b64chars:find(x, 1, true) - 1)
    for i = 6, 1, -1 do
      r = r .. (f % 2 ^ i - f % 2 ^ (i - 1) > 0 and "1" or "0")
    end
    return r
  end):gsub("%d%d%d?%d?%d?%d?%d?%d?", function(x)
    if #x ~= 8 then
      return ""
    end
    local c = 0
    for i = 1, 8 do
      c = c + (x:sub(i, i) == "1" and 2 ^ (8 - i) or 0)
    end
    return string.char(c)
  end))
end

function M.jwt_exp(token)
  if type(token) ~= "string" then
    return nil
  end

  local payload = token:match("^[^.]+%.([^.]+)%.")
  if not payload then
    return nil
  end

  local decoded = base64_decode(base64url_to_base64(payload))
  local data = M.json_decode(decoded)
  if type(data) == "table" then
    return tonumber(data.exp)
  end

  return nil
end

--- Parse an ISO-8601 timestamp string or numeric epoch → epoch seconds (UTC).
--- Returns nil if unparseable.
function M.parse_iso8601(s)
  if s == nil or s == "" then
    return nil
  end
  local n = tonumber(s)
  if n then
    -- Normalize milliseconds to seconds
    return n > 100000000000 and math.floor(n / 1000) or n
  end
  if type(s) ~= "string" then
    return nil
  end
  local year, month, day, hour, min, sec = s:match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)")
  if not year then
    return nil
  end
  year, month, day = tonumber(year), tonumber(month), tonumber(day)
  hour, min, sec = tonumber(hour), tonumber(min), tonumber(sec)
  if not (year and month and day and hour and min and sec) then
    return nil
  end

  local tz = 0
  local sign, th, tm = s:match("([%+%-])(%d+):(%d+)$")
  if sign then
    tz = (sign == "-" and -1 or 1) * (tonumber(th) * 3600 + tonumber(tm) * 60)
  end

  local t = os.time({ year = year, month = month, day = day, hour = hour, min = min, sec = sec })
  if not t then
    return nil
  end

  local tz_string = tostring(os.date("%z"))
  local tz_sign, tz_hour, tz_min = tz_string:match("^([%+%-])(%d%d)(%d%d)$")
  local local_offset = 0
  if tz_sign then
    local_offset = (tz_sign == "-" and -1 or 1) * ((tonumber(tz_hour) or 0) * 3600 + (tonumber(tz_min) or 0) * 60)
  end
  return t - tz + local_offset
end

function M.format_reset(value)
  if value == nil then
    return nil
  end

  local n = tonumber(value)
  if not n then
    return tostring(value)
  end

  -- Some APIs return milliseconds; normalize to seconds.
  if n > 100000000000 then
    n = math.floor(n / 1000)
  end

  local delta = n - os.time()
  if delta <= 0 then
    return "now"
  end

  if delta < 60 then
    return string.format("%ds", delta)
  end

  if delta < 3600 then
    return string.format("%dm", math.ceil(delta / 60))
  end

  if delta < 86400 then
    return string.format("%.1fh", delta / 3600)
  end

  return string.format("%.1fd", delta / 86400)
end

function M.insert_text(text, bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    bufnr = vim.api.nvim_get_current_buf()
  end

  local lines = vim.split(text, "\n", { plain = true })
  local row = vim.api.nvim_win_get_cursor(0)[1]
  vim.api.nvim_buf_set_lines(bufnr, row, row, false, lines)
end

return M
