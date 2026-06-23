local util = require "codecompanion._extensions.usage.util"
local render = require "codecompanion._extensions.usage.render"

local Extension = {}

local defaults = {
  command = "CodeCompanionUsage",
  default_provider = "codex",
  --- If true, auto-refresh usage when entering a codecompanion chat buffer
  --- and whenever the ACP config (model/mode/thought) changes.
  auto_refresh = true,
  --- Debounce auto-refresh by this many milliseconds (prevents bursts).
  auto_refresh_debounce_ms = 2000,
  --- Refresh interval in seconds (0 = no periodic refresh).
  refresh_interval_sec = 300,
  providers = {
    codex = { enabled = true },
    claude = { enabled = true },
  },
}

local state = {
  opts = {},
  providers = {},
  last_snapshots = {},
  last_errors = {},
  last_refreshed_at = {},
  _auto_refresh_timers = {},
  _periodic_timer = nil,
}

-- Global table for statusline consumption: _G.codecompanion_usage_stl[bufnr] = "codex 75%/50% 2.3d"
_G.codecompanion_usage_stl = _G.codecompanion_usage_stl or {}

local function enabled_provider_names()
  local names = {}
  for name, provider in pairs(state.providers) do
    local provider_opts = state.opts.providers[name] or {}
    if provider_opts.enabled ~= false and provider.refresh then
      table.insert(names, name)
    end
  end
  table.sort(names)
  return names
end

local function load_provider(name, provider_opts)
  local ok, provider = pcall(require, "codecompanion._extensions.usage.providers." .. name)
  if not ok then
    state.last_errors[name] = provider
    return nil
  end
  if provider.setup then
    provider = provider.setup(provider_opts or {})
  end
  return provider
end

local function setup_providers()
  state.providers = {}
  for name, provider_opts in pairs(state.opts.providers or {}) do
    if provider_opts.enabled ~= false then
      local provider = load_provider(name, provider_opts)
      if provider then
        state.providers[name] = provider
      end
    end
  end
end

local function refresh_provider(name, cb)
  local provider = state.providers[name]
  if not provider then
    cb(nil, "Provider is not enabled or unavailable: " .. tostring(name))
    return
  end

  provider.refresh(function(snapshot, err)
    if err then
      state.last_errors[name] = err
      cb(nil, err)
      return
    end

    state.last_snapshots[name] = snapshot
    state.last_errors[name] = nil
    state.last_refreshed_at[name] = os.time()
    cb(snapshot, nil)
  end)
end

local function refresh_all(cb)
  local names = enabled_provider_names()
  local remaining = #names
  local snapshots = {}

  if remaining == 0 then
    cb({}, { _global = "No providers enabled" })
    return
  end

  for _, name in ipairs(names) do
    refresh_provider(name, function(snapshot, err)
      if err then
        snapshots[name] = { provider = name, error = err }
      else
        snapshots[name] = snapshot
      end

      remaining = remaining - 1
      if remaining == 0 then
        cb(snapshots, nil)
      end
    end)
  end
end

---Refresh a provider and update the global statusline string for a bufnr.
---@param provider_name string
---@param bufnr number
local function refresh_and_update_stl(provider_name, bufnr)
  refresh_provider(provider_name, function(snapshot, err)
    vim.schedule(function()
      local text
      if err then
        text = (state.opts.providers[provider_name] and state.opts.providers[provider_name].label or provider_name) .. " err"
      elseif snapshot then
        text = render.compact(snapshot)
      else
        text = provider_name .. " n/a"
      end

      -- Write to all known chat buffers for this adapter, or the specific one
      if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        _G.codecompanion_usage_stl[bufnr] = text
      end

      -- Also update the adapter-keyed cache
      _G.codecompanion_usage_stl["__adapter__" .. provider_name] = text

      vim.cmd "redrawstatus"
    end)
  end)
end

---Given a codecompanion adapter name, return the matching provider name if it exists.
---The adapter name must match a provider name directly (case-insensitive).
---@param adapter_name string
---@return string|nil
local function provider_for_adapter(adapter_name)
  if not adapter_name then
    return nil
  end

  -- Case-insensitive exact match against enabled providers
  local lower = adapter_name:lower()
  for name, _ in pairs(state.providers) do
    if name:lower() == lower then
      return name
    end
  end

  return nil
end

---Auto-refresh usage for the adapter active in a given chat buffer.
---@param bufnr number
local function auto_refresh_for_buf(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local meta = _G.codecompanion_chat_metadata
  if not meta then
    return
  end

  local chat_meta = meta[bufnr]
  if not chat_meta or not chat_meta.adapter then
    return
  end

  local adapter_name = chat_meta.adapter.name
  if not adapter_name then
    return
  end

  local provider_name = provider_for_adapter(adapter_name)

  if not provider_name then
    -- No mapping for this adapter; clear any stale statusline
    _G.codecompanion_usage_stl[bufnr] = nil
    return
  end

  -- Debounce: cancel any pending timer for this bufnr
  local timer = state._auto_refresh_timers[bufnr]
  if timer then
    timer:stop()
    timer:close()
  end

  local debounce = state.opts.auto_refresh_debounce_ms or 2000
  timer = vim.uv.new_timer()
  timer:start(
    debounce,
    0,
    vim.schedule_wrap(function()
      state._auto_refresh_timers[bufnr] = nil
      if timer then
        timer:close()
      end
      refresh_and_update_stl(provider_name, bufnr)
    end)
  )
  state._auto_refresh_timers[bufnr] = timer
end

local function setup_auto_refresh()
  if state.opts.auto_refresh ~= true then
    return
  end

  local group = vim.api.nvim_create_augroup("CodeCompanionUsageAutoRefresh", { clear = true })

  vim.api.nvim_create_autocmd({ "User" }, {
    group = group,
    pattern = { "CodeCompanionChatOpened", "ChatACPConfigChanged" },
    callback = function(args)
      local bufnr = args.data and args.data.bufnr
      if not bufnr then
        return
      end
      auto_refresh_for_buf(bufnr)
    end,
  })

  -- Also refresh when entering a codecompanion buffer
  vim.api.nvim_create_autocmd({ "BufEnter" }, {
    group = group,
    callback = function(args)
      local bufnr = args.buf
      if not bufnr or vim.bo[bufnr].filetype ~= "codecompanion" then
        return
      end
      -- Only if we don't already have fresh data (< refresh_interval)
      local last = _G.codecompanion_usage_stl[bufnr]
      if not last then
        auto_refresh_for_buf(bufnr)
      end
    end,
  })
end

local function setup_periodic_refresh()
  local interval = state.opts.refresh_interval_sec
  if not interval or interval <= 0 then
    return
  end

  if state._periodic_timer then
    state._periodic_timer:stop()
    state._periodic_timer:close()
  end

  state._periodic_timer = vim.uv.new_timer()
  state._periodic_timer:start(
    interval * 1000,
    interval * 1000,
    vim.schedule_wrap(function()
      -- Refresh all visible codecompanion buffers
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        local bufnr = vim.api.nvim_win_get_buf(win)
        if vim.bo[bufnr].filetype == "codecompanion" then
          auto_refresh_for_buf(bufnr)
        end
      end
    end)
  )
end

local function insert_provider(name)
  refresh_provider(name, function(snapshot, err)
    vim.schedule(function()
      if err then
        return
      end
      util.insert_text(render.provider(snapshot))
    end)
  end)
end

local function insert_all()
  refresh_all(function(snapshots)
    vim.schedule(function()
      util.insert_text(render.all(snapshots))
    end)
  end)
end

local function create_commands()
  if not state.opts.command or state.opts.command == "" then
    return
  end

  pcall(vim.api.nvim_del_user_command, state.opts.command)
  pcall(vim.api.nvim_del_user_command, state.opts.command .. "Codex")
  pcall(vim.api.nvim_del_user_command, state.opts.command .. "Claude")

  vim.api.nvim_create_user_command(state.opts.command, function(args)
    if args.args and args.args ~= "" then
      insert_provider(args.args)
    else
      insert_all()
    end
  end, {
    nargs = "?",
    complete = function()
      return enabled_provider_names()
    end,
    desc = "Fetch and insert AI usage for enabled providers",
  })

  vim.api.nvim_create_user_command(state.opts.command .. "Codex", function()
    insert_provider "codex"
  end, { desc = "Fetch and insert Codex usage" })

  vim.api.nvim_create_user_command(state.opts.command .. "Claude", function()
    insert_provider "claude"
  end, { desc = "Fetch and insert Claude usage" })
end

function Extension.setup(opts)
  state.opts = util.deep_extend(defaults, opts or {})
  setup_providers()
  create_commands()
  setup_auto_refresh()
  setup_periodic_refresh()
end

---Get the compact statusline text for the adapter in the current (or given) buffer.
---@param bufnr? number
---@return string|nil
local function statusline_for_buf(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return _G.codecompanion_usage_stl[bufnr]
end

---Get the compact statusline text for a specific provider's last snapshot.
---@param provider_name string
---@return string
local function statusline_for_provider(provider_name)
  local snapshot = state.last_snapshots[provider_name]
  if not snapshot then
    return provider_name .. " n/a"
  end
  return render.compact(snapshot)
end

Extension.exports = {
  refresh = refresh_provider,
  refresh_all = refresh_all,

  last_snapshot = function(provider)
    return state.last_snapshots[provider or state.opts.default_provider]
  end,

  last_error = function(provider)
    return state.last_errors[provider or state.opts.default_provider]
  end,

  last_refreshed_at = function(provider)
    return state.last_refreshed_at[provider or state.opts.default_provider]
  end,

  ---Return compact statusline text for the adapter active in the current buffer.
  ---@param bufnr? number
  ---@return string|nil
  statusline = statusline_for_buf,

  ---Return compact statusline text for a named provider (e.g. "codex").
  ---@param provider_name string
  ---@return string
  statusline_for = statusline_for_provider,

  ---Given a codecompanion adapter name, return the matching provider name if it exists.
  ---@param adapter_name string
  ---@return string|nil
  provider_for = provider_for_adapter,

  ---Manually trigger auto-refresh for a buffer.
  auto_refresh = auto_refresh_for_buf,

  ---Access the internal state (for debugging).
  _state = state,
}

return Extension
