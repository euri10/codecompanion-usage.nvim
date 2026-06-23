local util = require("codecompanion._extensions.usage.util")

local M = {}

local defaults = {
  enabled = true,
  endpoint = "https://api.deepseek.com/user/balance",
  user_agent = "codecompanion-usage.nvim",
  timeout_ms = 10000,

  -- This provider is read-only: it uses DeepSeek's API key and lets
  -- the DeepSeek CLI/web own token management.

  -- Defaults to $DEEPSEEK_API_KEY env var, then ~/.deepseek/api_key
  api_key_path = nil,
}

local function load_auth(opts)
  -- Try environment variable first
  local api_key = vim.env.DEEPSEEK_API_KEY
  if api_key and api_key ~= "" then
    return {
      source = "env",
      api_key = api_key,
    }, nil
  end

  -- Try config file
  local config_path = opts.api_key_path
  if not config_path or config_path == "" then
    config_path = util.expand("~/.deepseek/api_key")
  else
    config_path = util.expand(config_path)
  end

  local raw = util.read_file(config_path)
  if raw then
    api_key = vim.trim(raw)
    if api_key ~= "" then
      return {
        source = "file",
        path = config_path,
        api_key = api_key,
      }, nil
    end
  end

  return nil, "No DeepSeek API key found. Set DEEPSEEK_API_KEY env var or create ~/.deepseek/api_key"
end

local function normalize(data)
  if not data then
    return nil
  end

  local windows = {}

  -- DeepSeek balance API returns: { balance_infos: [...], data: { ... } }
  -- or directly: { total_balance, grant_balance, charged_balance }
  local balance_info = data

  -- Handle nested structure (balance_infos array)
  if data.balance_infos and type(data.balance_infos) == "table" and #data.balance_infos > 0 then
    balance_info = data.balance_infos[1]
  elseif data.data and type(data.data) == "table" then
    balance_info = data.data
  end

  if type(balance_info) ~= "table" then
    return nil
  end

  local total_balance = tonumber(balance_info.total_balance or balance_info.balance)
  local used_amount = tonumber(balance_info.charged_balance or balance_info.used)

  if not total_balance or total_balance == 0 then
    return nil
  end

  -- If used_amount is nil (neither charged_balance nor used returned), default to 0
  if not used_amount then
    used_amount = 0
  end

  local used_percent = (used_amount / total_balance) * 100
  if not used_percent then
    return nil
  end

  table.insert(windows, {
    provider = "deepseek_acp",
    label = "balance",
    used_percent = used_percent,
    remaining_percent = math.max(0, 100 - used_percent),
    reset_at = nil,
    limit_window_seconds = nil,
  })

  return {
    provider = "deepseek_acp",
    provider_label = "DeepSeek",
    plan_type = nil,
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
    "Authorization: Bearer " .. auth.api_key,
    "-H",
    "Accept: application/json",
    "-H",
    "User-Agent: " .. opts.user_agent,
  }

  util.system_json(cmd, function(data, usage_err)
    if usage_err then
      local msg = "DeepSeek usage request failed: " .. util.redact(usage_err) .. ". Check your API key or visit https://platform.deepseek.com/api_keys"
      cb(nil, msg)
      return
    end

    if not data then
      cb(nil, "DeepSeek API returned empty response")
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

    local snapshot = normalize(data)
    if not snapshot or #(snapshot.windows or {}) == 0 then
      cb(nil, "No balance found in DeepSeek API response")
      return
    end

    cb(snapshot, nil)
  end)
end

return M
