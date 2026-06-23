local util = require "codecompanion._extensions.usage.util"
local render = require "codecompanion._extensions.usage.render"

local Extension = {}

local defaults = {
  default_provider = "codex",
  --- If true, auto-refresh usage when entering a codecompanion chat buffer
  --- and whenever the ACP config (model/mode/thought) changes.
  auto_refresh = true,
  --- Debounce auto-refresh by this many milliseconds (prevents bursts).
  auto_refresh_debounce_ms = 2000,
  --- Refresh interval in seconds (0 = no periodic refresh).
  refresh_interval_sec = 300,
  --- Statusline style: "text" (default) or "bar".
  statusline_style = "text",
  --- Width of the progress bar when statusline_style = "bar".
  statusline_bar_width = 12,
  providers = {
    codex = { enabled = true },
    claude_code = { enabled = true },
    copilot = { enabled = true },
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

-- Global table for statusline consumption: _G.codecompanion_usage_stl[bufnr] = "Codex > 5h: 89% (4.4h) W: 18% (1.8d)"
_G.codecompanion_usage_stl = _G.codecompanion_usage_stl or {}

local function canonical_provider_name(name)
  if not name then
    return nil
  end

  return tostring(name):lower():gsub("%s+", "_"):gsub("%-+", "_")
end

local function display_provider_name(name)
  local canonical = canonical_provider_name(name)
  if canonical == "claude_code" then
    return "Claude Code"
  end
  if canonical == "codex" then
    return "Codex"
  end
  if canonical == "copilot" then
    return "Copilot"
  end
  if not canonical then
    return "usage"
  end

  return canonical:gsub("_+", " "):gsub("^(%l)", string.upper)
end

local function normalize_provider_configs(provider_configs)
  local normalized = {}
  for name, provider_opts in pairs(provider_configs or {}) do
    local canonical = canonical_provider_name(name)
    normalized[canonical] = util.deep_extend(normalized[canonical] or {}, provider_opts or {})
  end
  return normalized
end

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
  state.opts.providers = normalize_provider_configs(state.opts.providers)
  for name, provider_opts in pairs(state.opts.providers or {}) do
    if provider_opts.enabled ~= false then
      if vim.g.codecompanion_debug then
        vim.notify(string.format("[usage] setup_providers: loading provider '%s'", name), vim.log.levels.DEBUG)
      end
      local provider = load_provider(name, provider_opts)
      if provider then
        state.providers[name] = provider
        if vim.g.codecompanion_debug then
          vim.notify(string.format("[usage] setup_providers: provider '%s' loaded successfully", name), vim.log.levels.DEBUG)
        end
      else
        if vim.g.codecompanion_debug then
          vim.notify(
            string.format("[usage] setup_providers: provider '%s' FAILED to load: %s", name, tostring(state.last_errors[name])),
            vim.log.levels.ERROR
          )
        end
      end
    end
  end
  if vim.g.codecompanion_debug then
    local names = {}
    for name, _ in pairs(state.providers) do
      table.insert(names, name)
    end
    vim.notify(string.format("[usage] setup_providers done: loaded providers=%s", vim.inspect(names)), vim.log.levels.DEBUG)
  end
end

local function refresh_provider(name, cb)
  name = canonical_provider_name(name)
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

local function render_snapshot(snapshot)
  if state.opts.statusline_style == "bar" then
    return render.bar(snapshot, {
      width = state.opts.statusline_bar_width,
    })
  end

  return render.compact(snapshot)
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
  if vim.g.codecompanion_debug then
    vim.notify(string.format("[usage] refresh_and_update_stl: refreshing '%s' for bufnr=%d", provider_name, bufnr), vim.log.levels.DEBUG)
  end
  refresh_provider(provider_name, function(snapshot, err)
    vim.schedule(function()
      local text
      if err then
        text = display_provider_name(provider_name) .. " > err"
        if vim.g.codecompanion_debug then
          vim.notify(string.format("[usage] refresh_and_update_stl: '%s' error: %s", provider_name, tostring(err)), vim.log.levels.ERROR)
        end
      elseif snapshot then
        text = render_snapshot(snapshot)
        if vim.g.codecompanion_debug then
          vim.notify(
            string.format("[usage] refresh_and_update_stl: '%s' snapshot=%s compact=%s", provider_name, vim.inspect(snapshot), text),
            vim.log.levels.DEBUG
          )
        end
      else
        text = display_provider_name(provider_name) .. " > n/a"
        if vim.g.codecompanion_debug then
          vim.notify(string.format("[usage] refresh_and_update_stl: '%s' no snapshot, no error", provider_name), vim.log.levels.DEBUG)
        end
      end

      -- Write to all known chat buffers for this adapter, or the specific one
      if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        _G.codecompanion_usage_stl[bufnr] = text
      end

      -- Also update the adapter-keyed cache
      _G.codecompanion_usage_stl["__adapter__" .. provider_name] = text

      if vim.g.codecompanion_debug then
        vim.notify(string.format("[usage] refresh_and_update_stl: set stl[%d]='%s' stl[__adapter__%s]='%s'", bufnr, text, provider_name, text), vim.log.levels.DEBUG)
      end

      vim.cmd "redrawstatus"
    end)
  end)
end

---Given a codecompanion adapter name, return the matching provider name if it exists.
---The adapter name is normalized (spaces → underscores, lowercased) to match
---provider keys (e.g. "Claude Code" ↔ "claude_code").
---@param adapter_name string
---@return string|nil
local function provider_for_adapter(adapter_name)
  if not adapter_name then
    if vim.g.codecompanion_debug then
      vim.notify("[usage] provider_for_adapter: nil adapter_name", vim.log.levels.DEBUG)
    end
    return nil
  end

  -- Normalize adapter name to match provider keys:
  -- "Claude Code" → "claude_code"
  local normalized = canonical_provider_name(adapter_name)

  local provider_names = {}
  for name, _ in pairs(state.providers) do
    table.insert(provider_names, name)
    if name == normalized then
      if vim.g.codecompanion_debug then
        vim.notify(string.format("[usage] provider_for_adapter: '%s' matched provider '%s'", adapter_name, name), vim.log.levels.DEBUG)
      end
      return name
    end
  end

  if vim.g.codecompanion_debug then
    vim.notify(
      string.format("[usage] provider_for_adapter: NO match for '%s' (normalized='%s') among providers: %s", adapter_name, normalized, vim.inspect(provider_names)),
      vim.log.levels.WARN
    )
  end
  return nil
end

---Auto-refresh usage for the adapter active in a given chat buffer.
---@param bufnr number
local function auto_refresh_for_buf(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    if vim.g.codecompanion_debug then
      vim.notify(string.format("[usage] auto_refresh_for_buf: invalid bufnr=%s", tostring(bufnr)), vim.log.levels.DEBUG)
    end
    return
  end

  local meta = _G.codecompanion_chat_metadata
  if not meta then
    if vim.g.codecompanion_debug then
      vim.notify("[usage] auto_refresh_for_buf: _G.codecompanion_chat_metadata is nil", vim.log.levels.DEBUG)
    end
    return
  end

  local chat_meta = meta[bufnr]
  if not chat_meta or not chat_meta.adapter then
    if vim.g.codecompanion_debug then
      vim.notify(
        string.format("[usage] auto_refresh_for_buf: no chat_meta or adapter for bufnr=%d (chat_meta=%s)", bufnr, tostring(chat_meta)),
        vim.log.levels.DEBUG
      )
    end
    return
  end

  local adapter_name = chat_meta.adapter.name
  if not adapter_name then
    if vim.g.codecompanion_debug then
      vim.notify(string.format("[usage] auto_refresh_for_buf: adapter.name is nil for bufnr=%d", bufnr), vim.log.levels.DEBUG)
    end
    return
  end

  if vim.g.codecompanion_debug then
    vim.notify(
      string.format("[usage] auto_refresh_for_buf bufnr=%d adapter_name=%s", bufnr, adapter_name),
      vim.log.levels.DEBUG
    )
  end

  local provider_name = provider_for_adapter(adapter_name)

  if not provider_name then
    -- No mapping for this adapter; clear any stale statusline
    _G.codecompanion_usage_stl[bufnr] = nil
    if vim.g.codecompanion_debug then
      vim.notify(
        string.format("[usage] auto_refresh_for_buf: no provider for adapter '%s', cleared stl", adapter_name),
        vim.log.levels.WARN
      )
    end
    return
  end

  if vim.g.codecompanion_debug then
    vim.notify(
      string.format("[usage] auto_refresh_for_buf: matched provider '%s', triggering refresh", provider_name),
      vim.log.levels.DEBUG
    )
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

function Extension.setup(opts)
  state.opts = util.deep_extend(defaults, opts or {})
  state.opts.default_provider = canonical_provider_name(state.opts.default_provider)
  if vim.g.codecompanion_debug then
    local provider_names = {}
    for name, p_opts in pairs(state.opts.providers or {}) do
      table.insert(provider_names, string.format("%s(enabled=%s)", name, tostring(p_opts.enabled ~= false)))
    end
    vim.notify(
      string.format("[usage] Extension.setup: merged config providers=%s auto_refresh=%s refresh_interval=%d",
        table.concat(provider_names, ", "),
        tostring(state.opts.auto_refresh),
        state.opts.refresh_interval_sec
      ),
      vim.log.levels.DEBUG
    )
  end
  setup_providers()
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
  local canonical = canonical_provider_name(provider_name)
  local snapshot = state.last_snapshots[canonical]
  if not snapshot then
    return display_provider_name(provider_name) .. " > n/a"
  end
  return render_snapshot(snapshot)
end

Extension.exports = {
  refresh = refresh_provider,
  refresh_all = refresh_all,

  last_snapshot = function(provider)
    return state.last_snapshots[canonical_provider_name(provider or state.opts.default_provider)]
  end,

  last_error = function(provider)
    return state.last_errors[canonical_provider_name(provider or state.opts.default_provider)]
  end,

  last_refreshed_at = function(provider)
    return state.last_refreshed_at[canonical_provider_name(provider or state.opts.default_provider)]
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
