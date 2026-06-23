local util = require("codecompanion._extensions.usage.util")

local M = {}

local defaults = {
  enabled = true,
  endpoint = "https://api.github.com/copilot_internal/user",
  user_agent = "codecompanion-usage.nvim",
  timeout_ms = 10000,

  -- This provider is read-only: it uses Copilot's cached token and lets
  -- the Copilot extension/CLI own token refresh.

  -- Defaults to $XDG_CONFIG_HOME/github-copilot or ~/.config/github-copilot
  config_path = nil,
}

local function find_config_path(opts)
  if opts.config_path and opts.config_path ~= "" then
    return util.expand(opts.config_path)
  end

  local xdg_config = vim.env.XDG_CONFIG_HOME
  if xdg_config and xdg_config ~= "" then
    local path = util.expand(xdg_config)
    if vim.fn.isdirectory(path) > 0 then
      return path
    end
  end

  local default_path = util.expand("~/.config")
  if vim.fn.isdirectory(default_path) > 0 then
    return default_path
  end

  return nil
end

local function load_auth(opts)
  local config_path = find_config_path(opts)
  if not config_path then
    return nil, "Could not find config directory (set $XDG_CONFIG_HOME or use ~/.config)"
  end

  -- Try JSON files first (hosts.json, apps.json)
  local json_paths = {
    vim.fs.joinpath(config_path, "github-copilot", "hosts.json"),
    vim.fs.joinpath(config_path, "github-copilot", "apps.json"),
  }

  for _, json_path in ipairs(json_paths) do
    if vim.uv.fs_stat(json_path) then
      local raw, read_err = util.read_file(json_path)
      if raw then
        local data, decode_err = util.json_decode(raw)
        if data then
          for key, value in pairs(data) do
            if type(value) == "table" and value.oauth_token then
              return {
                path = json_path,
                access_token = value.oauth_token,
              }, nil
            end
          end
        end
      end
    end
  end

  -- Fall back to SQLite database
  local db_path = vim.fs.joinpath(config_path, "github-copilot", "auth.db")
  if vim.uv.fs_stat(db_path) then
    if vim.fn.executable("sqlite3") == 0 then
      return nil, "sqlite3 is required to read tokens from GitHub Copilot auth database"
    end

    local db_token = nil
    local cmd_result = vim.system(
      { "sqlite3", db_path, "SELECT token_ciphertext FROM oauth_tokens WHERE auth_authority == 'github.com' LIMIT 1" },
      { text = true }
    ):wait()

    if cmd_result.stdout and cmd_result.stdout ~= "" then
      db_token = vim.trim(cmd_result.stdout)
      if db_token ~= "" then
        return {
          path = db_path,
          access_token = db_token,
        }, nil
      end
    end
  end

  return nil, "No GitHub Copilot OAuth token found. Make sure you're logged in with Copilot."
end

local function calculate_usage_percent(entitlement, remaining)
  if not entitlement or entitlement == 0 then
    return nil
  end
  local used = entitlement - remaining
  return (used / entitlement) * 100
end

local function normalize_quota(label, quota, seconds)
  if type(quota) ~= "table" then
    return nil
  end

  local entitlement = tonumber(quota.entitlement or quota.limit)
  local remaining = tonumber(quota.remaining)

  if not entitlement or not remaining then
    return nil
  end

  local used_percent = calculate_usage_percent(entitlement, remaining)
  if not used_percent then
    return nil
  end

  return {
    provider = "copilot",
    label = label,
    used_percent = used_percent,
    remaining_percent = math.max(0, 100 - used_percent),
    reset_at = nil,
    limit_window_seconds = seconds,
  }
end

local function normalize(data)
  if not data then
    return nil
  end

  local windows = {}
  local is_limited = data.access_type_sku == "free_limited_copilot"

  if is_limited then
    -- Limited user quotas
    local chat = normalize_quota("chat", data.limited_user_quotas and data.limited_user_quotas.chat, 30 * 86400)
    if chat then
      table.insert(windows, chat)
    end

    local completions = normalize_quota("completions", data.limited_user_quotas and data.limited_user_quotas.completions, 30 * 86400)
    if completions then
      table.insert(windows, completions)
    end
  else
    -- Premium user quotas (quota_snapshots)
    local premium = normalize_quota("premium", data.quota_snapshots and data.quota_snapshots.premium_interactions, 3600)
    if premium then
      table.insert(windows, premium)
    end

    local chat = normalize_quota("chat", data.quota_snapshots and data.quota_snapshots.chat, 30 * 86400)
    if chat then
      table.insert(windows, chat)
    end

    local completions = normalize_quota("completions", data.quota_snapshots and data.quota_snapshots.completions, 30 * 86400)
    if completions then
      table.insert(windows, completions)
    end
  end

  local plan_type = nil
  if data.access_type_sku then
    plan_type = data.access_type_sku:gsub("_", " "):gsub("^%l", string.upper)
  end

  return {
    provider = "copilot",
    provider_label = "Copilot",
    plan_type = plan_type,
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
    "Accept: */*",
    "-H",
    "User-Agent: " .. opts.user_agent,
  }

  util.system_json(cmd, function(data, usage_err)
    if usage_err then
      cb(nil, "Copilot usage request failed: " .. util.redact(usage_err) .. ". Try logging in again with your GitHub account.")
      return
    end

    if not data then
      cb(nil, "Copilot API returned empty response")
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
      cb(nil, "No usage windows found in Copilot API response")
      return
    end

    cb(snapshot, nil)
  end)
end

return M
