local util = require("codecompanion._extensions.usage.util")
local render = require("codecompanion._extensions.usage.render")

local Extension = {}

local defaults = {
  notify = true,
  command = "CodeCompanionUsage",
  add_chat_keymap = true,
  chat_keymap = "gu",
  default_provider = "codex",
  providers = {
    codex = { enabled = true },
    claude = { enabled = false },
  },
}

local state = {
  opts = {},
  providers = {},
  last_snapshots = {},
  last_errors = {},
  last_refreshed_at = {},
}

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

local function insert_provider(name)
  refresh_provider(name, function(snapshot, err)
    vim.schedule(function()
      if err then
        util.notify(err, vim.log.levels.ERROR, state.opts.notify)
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
    insert_provider("codex")
  end, { desc = "Fetch and insert Codex usage" })

  vim.api.nvim_create_user_command(state.opts.command .. "Claude", function()
    insert_provider("claude")
  end, { desc = "Fetch and insert Claude usage" })
end

local function add_chat_keymap()
  if state.opts.add_chat_keymap == false then
    return
  end

  local ok, config = pcall(require, "codecompanion.config")
  if not ok or not config.interactions or not config.interactions.chat then
    return
  end

  config.interactions.chat.keymaps = config.interactions.chat.keymaps or {}
  config.interactions.chat.keymaps.usage = {
    modes = { n = state.opts.chat_keymap },
    description = "Insert AI usage",
    callback = function(chat)
      refresh_all(function(snapshots)
        vim.schedule(function()
          local bufnr = chat and chat.bufnr
          util.insert_text(render.all(snapshots), type(bufnr) == "number" and bufnr or nil)
        end)
      end)
    end,
  }
end

function Extension.setup(opts)
  state.opts = util.deep_extend(defaults, opts or {})
  setup_providers()
  create_commands()
  add_chat_keymap()
end

Extension.exports = {
  refresh = refresh_provider,
  refresh_all = refresh_all,

  last_snapshot = function(provider)
    return state.last_snapshots[provider or state.opts.default_provider]
  end,

  last_snapshots = function()
    return state.last_snapshots
  end,

  last_error = function(provider)
    return state.last_errors[provider or state.opts.default_provider]
  end,

  render = function(snapshot)
    return render.provider(snapshot or state.last_snapshots[state.opts.default_provider])
  end,

  render_all = function(snapshots)
    return render.all(snapshots or state.last_snapshots)
  end,

  compact = function(provider)
    return render.compact(state.last_snapshots[provider or state.opts.default_provider])
  end,

  insert = function(provider)
    if provider then
      insert_provider(provider)
    else
      insert_all()
    end
  end,
}

return Extension
