local util = require "codecompanion._extensions.usage.util"

local M = {}

local defaults = {
  enabled = true,
  --- Credentials file. Defaults to ~/.claude/.credentials.json
  credentials_path = nil,
  --- OAuth usage API endpoint (requires valid access token)
  usage_endpoint = "https://api.anthropic.com/api/oauth/usage",
  --- Token refresh endpoint
  token_endpoint = "https://platform.claude.com/v1/oauth/token",
  --- OAuth client ID (public value from Claude Code CLI)
  client_id = "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
  --- Beta header required by the OAuth usage endpoint
  beta_header = "oauth-2025-04-20",
  --- User-Agent header
  user_agent = "codecompanion-usage.nvim",
  --- HTTP timeout in milliseconds
  timeout_ms = 10000,
  --- Try to refresh the access token when expired
  allow_token_refresh = true,
}

-- ============================================================================
-- Helpers
-- ============================================================================

local function claude_home()
  return vim.env.CLAUDE_CODE_HOME ~= "" and vim.env.CLAUDE_CODE_HOME or vim.fn.expand "~/.claude"
end

local function credentials_path(opts)
  return (opts.credentials_path and opts.credentials_path ~= "" and util.expand(opts.credentials_path)) or claude_home() .. "/.credentials.json"
end

--- Parse ISO‑8601 timestamp → epoch seconds.
local function parse_iso8601(s)
  if not s or s == "" then
    return nil
  end
  local year, month, day, hour, min, sec = s:match "^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)"
  if not year then
    return nil
  end
  year, month, day = math.tointeger(year), math.tointeger(month), math.tointeger(day)
  hour, min, sec = math.tointeger(hour), math.tointeger(min), math.tointeger(sec)
  if not (year and month and day and hour and min and sec) then
    return nil
  end

  local tz = 0
  local sign, th, tm = s:match "([%+%-])(%d+):(%d+)$"
  if sign then
    tz = (sign == "-" and -1 or 1) * (tonumber(th) * 3600 + tonumber(tm) * 60)
  end

  local t = os.time { year = year, month = month, day = day, hour = hour, min = min, sec = sec }
  if not t then
    return nil
  end

  -- os.time interprets the table as *local* time.  To convert to UTC:
  --   local_offset = current local time - current UTC time (seconds)
  --   The string represents a time in zone `tz` (positive = east of UTC).
  --   UTC epoch = t - (tz - local_offset) = t - tz + local_offset
  local local_offset = os.difftime(os.time(), os.time(os.date("!*t")))
  return t - tz + local_offset
end

-- ============================================================================
-- Credentials
-- ============================================================================

local function load_credentials(opts)
  local path = credentials_path(opts)
  local raw, err = util.read_file(path)
  if not raw then
    return nil, "Could not read credentials from " .. path .. ": " .. tostring(err)
  end

  local data, json_err = util.json_decode(raw)
  if not data then
    return nil, "Could not parse " .. path .. ": " .. tostring(json_err)
  end

  local oauth = data.claudeAiOauth
  if not oauth then
    return nil, "No claudeAiOauth entry in " .. path .. ".\nRun `claude login` to authenticate."
  end
  if not oauth.accessToken then
    return nil, "No access token in " .. path .. ".\nRun `claude login` to authenticate."
  end

  return {
    path = path,
    raw_data = data,
    access_token = oauth.accessToken,
    refresh_token = oauth.refreshToken,
    expires_at = tonumber(oauth.expiresAt),
    scopes = oauth.scopes or {},
    subscription_type = oauth.subscriptionType,
    rate_limit_tier = oauth.rateLimitTier,
  },
    nil
end

local function is_token_expired(creds)
  return creds.expires_at and creds.expires_at <= (os.time() * 1000 + 300000) or false
end

-- ============================================================================
-- Token refresh (async)
-- ============================================================================

local function refresh_token_async(creds, opts, cb)
  if not creds.refresh_token then
    return cb(nil, "No refresh token available. Run `claude login` first.")
  end

  local body = "grant_type=refresh_token" .. "&refresh_token=" .. creds.refresh_token .. "&client_id=" .. opts.client_id

  util.system_json({
    "curl",
    "-sS",
    "--fail-with-body",
    "--max-time",
    tostring(math.floor((opts.timeout_ms or 10000) / 1000)),
    "-X",
    "POST",
    opts.token_endpoint,
    "-H",
    "Content-Type: application/x-www-form-urlencoded",
    "-H",
    "Accept: application/json",
    "-H",
    "User-Agent: " .. opts.user_agent,
    "-d",
    body,
  }, function(data, err)
    if err then
      return cb(nil, "Token refresh failed: " .. util.redact(err))
    end
    if not data then
      return cb(nil, "Token refresh returned empty response")
    end

    local new_creds = vim.deepcopy(creds)
    if data.access_token then
      new_creds.access_token = data.access_token
    end
    if data.refresh_token then
      new_creds.refresh_token = data.refresh_token
    end
    if data.expires_in then
      new_creds.expires_at = os.time() * 1000 + tonumber(data.expires_in) * 1000
    end

    -- Persist
    if creds.raw_data and (data.access_token or data.refresh_token) then
      if data.access_token then
        creds.raw_data.claudeAiOauth.accessToken = data.access_token
      end
      if data.refresh_token then
        creds.raw_data.claudeAiOauth.refreshToken = data.refresh_token
      end
      if data.expires_in then
        creds.raw_data.claudeAiOauth.expiresAt = new_creds.expires_at
      end
      local encoded = util.json_encode(creds.raw_data)
      if encoded then
        util.write_file_secure(creds.path, encoded)
      end
    end

    cb(new_creds, nil)
  end)
end

-- ============================================================================
-- OAuth Usage API (async)
-- ============================================================================

local function fetch_oauth_usage_async(access_token, opts, cb)
  util.system_json({
    "curl",
    "-sS",
    "--fail-with-body",
    "--max-time",
    tostring(math.floor((opts.timeout_ms or 10000) / 1000)),
    opts.usage_endpoint,
    "-H",
    "Authorization: Bearer " .. access_token,
    "-H",
    "Accept: application/json",
    "-H",
    "Content-Type: application/json",
    "-H",
    "anthropic-beta: " .. opts.beta_header,
    "-H",
    "User-Agent: " .. opts.user_agent,
  }, function(data, err)
    if err then
      cb(nil, "Claude OAuth usage request failed: " .. util.redact(err))
      return
    end
    cb(data, nil)
  end)
end

-- ============================================================================
-- Normalize OAuth response → snapshot
-- ============================================================================

local function normalize_window(w, label, seconds)
  -- Guard against userdata or non-table values (vim.json.decode can return
  -- vim.NIL or other userdata for null/nested arrays in some API responses).
  if type(w) ~= "table" or w.utilization == nil then
    return nil
  end
  local used = tonumber(w.utilization)
  if not used then
    return nil
  end
  return {
    provider = "claude_code",
    label = label,
    used_percent = used,
    remaining_percent = math.max(0, 100 - used),
    reset_at = parse_iso8601(w.resets_at),
    limit_window_seconds = seconds,
  }
end

local function normalize_oauth_usage(data, creds)
  local windows = {}

  local function add(w, label, sec)
    if type(w) ~= "table" then
      if vim.g.codecompanion_debug then
        vim.notify(
          string.format("[usage:claude_code] normalize: skipping '%s' — expected table, got %s", label, type(w)),
          vim.log.levels.DEBUG
        )
      end
      return
    end
    local n = normalize_window(w, label, sec)
    if n then
      table.insert(windows, n)
    end
  end

  if vim.g.codecompanion_debug then
    vim.notify(
      string.format("[usage:claude_code] normalize: raw keys=%s", vim.inspect(vim.tbl_keys(data or {}))),
      vim.log.levels.DEBUG
    )
  end

  add(data.five_hour, "5h", 5 * 3600)
  add(data.seven_day, "weekly", 7 * 86400)
  add(data.seven_day_sonnet, "sonnet weekly", 7 * 86400)
  if not data.seven_day_sonnet then
    add(data.seven_day_opus, "opus weekly", 7 * 86400)
  end
  add(data.seven_day_routines, "routines weekly", 7 * 86400)
  add(data.seven_day_oauth_apps, "oauth apps weekly", 7 * 86400)

  -- Extra usage (spend limit / credits)
  local extra = data.extra_usage
  if extra and extra.is_enabled then
    local used = tonumber(extra.used_credits)
    local limit = tonumber(extra.monthly_limit)
    if used and limit and limit > 0 then
      local pct = (used / limit) * 100
      table.insert(windows, {
        provider = "claude_code",
        label = "spend (monthly)",
        used_percent = pct,
        remaining_percent = math.max(0, 100 - pct),
        reset_at = nil,
        limit_window_seconds = 30 * 86400,
      })
    end
  end

  local plan_type = nil
  if creds then
    local parts = {}
    if creds.subscription_type then
      table.insert(parts, creds.subscription_type)
    end
    if creds.rate_limit_tier and creds.rate_limit_tier ~= "default_claude_ai" then
      table.insert(parts, creds.rate_limit_tier)
    end
    plan_type = #parts > 0 and table.concat(parts, " ") or nil
  end

  return {
    provider = "claude_code",
    provider_label = "Claude",
    plan_type = plan_type,
    windows = windows,
    raw = data,
  }
end

-- ============================================================================
-- Setup & Refresh
-- ============================================================================

function M.setup(opts)
  M.opts = util.deep_extend(defaults, opts or {})
  return M
end

function M.refresh(cb)
  local opts = M.opts or defaults

  if vim.g.codecompanion_debug then
    vim.notify("[usage:claude_code] refresh: starting", vim.log.levels.DEBUG)
  end

  -- 1. Load credentials -> OAuth API
  local creds, creds_err = load_credentials(opts)
  if not creds then
    return cb(nil, creds_err)
  end

  if vim.g.codecompanion_debug then
    vim.notify(
      string.format("[usage:claude_code] refresh: creds loaded, token_expired=%s allow_refresh=%s",
        tostring(is_token_expired(creds)), tostring(opts.allow_token_refresh)),
      vim.log.levels.DEBUG
    )
  end

  -- 2. Optionally refresh, then call OAuth API
  local function call_oauth()
    if vim.g.codecompanion_debug then
      vim.notify("[usage:claude_code] refresh: calling OAuth usage API", vim.log.levels.DEBUG)
    end
    fetch_oauth_usage_async(creds.access_token, opts, function(data, err)
      if vim.g.codecompanion_debug then
        vim.notify(
          string.format("[usage:claude_code] refresh: OAuth response err=%s data=%s windows=%d",
            tostring(err), tostring(data ~= nil), data and #(data.windows or {}) or 0),
          vim.log.levels.DEBUG
        )
      end
      if data and not err then
        local snap = normalize_oauth_usage(data, creds)
        if snap and #snap.windows > 0 then
          return cb(snap, nil)
        end
        return cb(nil, "Claude OAuth returned empty usage data")
      end

      cb(nil, err)
    end)
  end

  if is_token_expired(creds) and opts.allow_token_refresh then
    if vim.g.codecompanion_debug then
      vim.notify("[usage:claude_code] refresh: token expired, refreshing", vim.log.levels.DEBUG)
    end
    refresh_token_async(creds, opts, function(new_creds, _)
      if new_creds then
        creds = new_creds
      end
      call_oauth()
    end)
  else
    call_oauth()
  end
end

return M
