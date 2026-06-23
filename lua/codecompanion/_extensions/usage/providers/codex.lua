local util = require("codecompanion._extensions.usage.util")

local M = {}

local defaults = {
  enabled = true,
  endpoint = "https://chatgpt.com/backend-api/wham/usage",
  user_agent = "codecompanion-usage.nvim",
  timeout_ms = 10000,

  -- This provider is intentionally read-only: it uses Codex's cached
  -- access token and lets the Codex CLI/extension own token refresh.

  -- Defaults to $CODEX_HOME/auth.json or ~/.codex/auth.json.
  auth_path = nil,
}

local function codex_home()
  if vim.env.CODEX_HOME and vim.env.CODEX_HOME ~= "" then
    return vim.env.CODEX_HOME
  end
  return vim.fn.expand("~/.codex")
end

local function auth_path(opts)
  if opts.auth_path and opts.auth_path ~= "" then
    return util.expand(opts.auth_path)
  end
  return codex_home() .. "/auth.json"
end

local function load_auth(opts)
  local path = auth_path(opts)
  local raw, read_err = util.read_file(path)
  if not raw then
    return nil, read_err
  end

  local data, decode_err = util.json_decode(raw)
  if not data then
    return nil, "Could not parse " .. path .. ": " .. tostring(decode_err)
  end

  local tokens = data.tokens or data
  local access_token = tokens.access_token
  local refresh_token = tokens.refresh_token
  local account_id = tokens.account_id or data.account_id

  if not access_token then
    return nil, "No access_token found in " .. path .. ". Run `codex login` first."
  end

  return {
    path = path,
    raw = data,
    tokens = tokens,
    access_token = access_token,
    refresh_token = refresh_token,
    account_id = account_id,
    exp = util.jwt_exp(access_token),
  }, nil
end

local function percent_remaining(w)
  if type(w) ~= "table" then
    return nil
  end

  local remaining = tonumber(w.remaining_percent or w.percent_remaining)
  if remaining then
    return remaining
  end

  local used = tonumber(w.used_percent or w.percent_used or w.usage_percent)
  if used then
    return math.max(0, 100 - used)
  end

  return nil
end

local function percent_used(w)
  if type(w) ~= "table" then
    return nil
  end

  local used = tonumber(w.used_percent or w.percent_used or w.usage_percent)
  if used then
    return used
  end

  local remaining = tonumber(w.remaining_percent or w.percent_remaining)
  if remaining then
    return math.max(0, 100 - remaining)
  end

  return nil
end

local function reset_at(w)
  if type(w) ~= "table" then
    return nil
  end
  return w.reset_at or w.resets_at or w.reset_time or w.end_time
end

local function normalize_window(label, w)
  if type(w) ~= "table" then
    return nil
  end

  return {
    provider = "codex",
    label = label,
    used_percent = percent_used(w),
    remaining_percent = percent_remaining(w),
    reset_at = reset_at(w),
    limit_window_seconds = tonumber(w.limit_window_seconds or w.window_seconds),
    raw = w,
  }
end

local function normalize(data)
  local rl = data.rate_limit or {}
  local windows = {}

  local primary = normalize_window("5h", rl.primary_window)
  if primary then
    table.insert(windows, primary)
  end

  local secondary = normalize_window("weekly", rl.secondary_window)
  if secondary then
    table.insert(windows, secondary)
  end

  if type(data.additional_rate_limits) == "table" then
    for _, item in ipairs(data.additional_rate_limits) do
      local label = item.title or item.name or item.id or "extra"
      local window = normalize_window(label, item)
      if window then
        table.insert(windows, window)
      end
    end
  end

  return {
    provider = "codex",
    provider_label = "Codex",
    plan_type = data.plan_type,
    windows = windows,
    raw = data,
  }
end

function M.setup(opts)
  M.opts = util.deep_extend(defaults, opts or {})
  return M
end

function M.fetch_raw(cb)
  local opts = M.opts or defaults
  local auth, err = load_auth(opts)
  if err then
    cb(nil, err)
    return
  end

  local cmd = {
    "curl",
    "-sS",
    "--fail-with-body",
    "--max-time",
    tostring(math.floor((opts.timeout_ms or 10000) / 1000)),
    opts.endpoint,
    "-H",
    "Authorization: Bearer " .. auth.access_token,
    "-H",
    "User-Agent: " .. opts.user_agent,
  }

  if auth.account_id then
    table.insert(cmd, "-H")
    table.insert(cmd, "ChatGPT-Account-Id: " .. auth.account_id)
  end

  util.system_json(cmd, function(data, usage_err)
    if usage_err then
      cb(nil, "Codex usage request failed: " .. util.redact(usage_err) .. ". Try running `codex login` or any Codex command to refresh your session.")
      return
    end

    cb(data, nil)
  end)
end

function M.refresh(cb)
  M.fetch_raw(function(data, err)
    if err then
      cb(nil, err)
      return
    end
    cb(normalize(data), nil)
  end)
end

return M
