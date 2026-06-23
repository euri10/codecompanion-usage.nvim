local util = require("codecompanion._extensions.usage.util")

local M = {}

local function format_window(window)
  if not window then
    return nil
  end

  if window.not_implemented then
    return "not implemented"
  end

  local used = window.used_percent
  local remaining = window.remaining_percent
  local reset = util.format_reset(window.reset_at)

  local usage
  if remaining then
    usage = string.format("%.0f%% left", remaining)
  elseif used then
    usage = string.format("%.0f%% used", used)
  else
    usage = "n/a"
  end

  if reset then
    return string.format("%s: %s, resets in %s", window.label, usage, reset)
  end

  return string.format("%s: %s", window.label, usage)
end

function M.provider(snapshot)
  if not snapshot then
    return "Usage: unavailable"
  end

  local title = snapshot.provider_label or snapshot.provider or "Usage"
  if snapshot.plan_type then
    title = title .. " usage (" .. snapshot.plan_type .. ")"
  else
    title = title .. " usage"
  end

  local lines = { title .. ":" }

  for _, window in ipairs(snapshot.windows or {}) do
    local formatted = format_window(window)
    if formatted then
      table.insert(lines, "- " .. formatted)
    end
  end

  if #lines == 1 then
    table.insert(lines, "- unavailable")
  end

  return table.concat(lines, "\n")
end

function M.all(snapshots)
  if not snapshots or vim.tbl_isempty(snapshots) then
    return "AI usage: unavailable"
  end

  local lines = { "AI usage:" }

  for provider, snapshot in pairs(snapshots) do
    if snapshot and snapshot.error then
      table.insert(lines, string.format("- %s: unavailable (%s)", provider, snapshot.error))
    elseif snapshot then
      local label = snapshot.provider_label or snapshot.provider or provider
      local first = snapshot.windows and snapshot.windows[1]
      local second = snapshot.windows and snapshot.windows[2]
      local parts = {}

      if first and first.not_implemented then
        table.insert(parts, "not implemented")
      else
        if first and first.remaining_percent then
          table.insert(parts, string.format("%s %.0f%% left", first.label, first.remaining_percent))
        elseif first and first.used_percent then
          table.insert(parts, string.format("%s %.0f%% used", first.label, first.used_percent))
        end

        if second and second.remaining_percent then
          table.insert(parts, string.format("%s %.0f%% left", second.label, second.remaining_percent))
        elseif second and second.used_percent then
          table.insert(parts, string.format("%s %.0f%% used", second.label, second.used_percent))
        end
      end

      if #parts == 0 then
        table.insert(lines, string.format("- %s: available", label))
      else
        table.insert(lines, string.format("- %s: %s", label, table.concat(parts, ", ")))
      end
    end
  end

  return table.concat(lines, "\n")
end

---Return a single-line compact string suitable for a statusline.
---NOTE: Never emit raw "%" — Neovim's statusline engine interprets % sequences.
---@param snapshot table
---@return string
function M.compact(snapshot)
  if not snapshot then
    return "usage n/a"
  end

  local provider = snapshot.provider_label or snapshot.provider or "usage"

  if snapshot.not_implemented then
    return provider .. " n/a"
  end

  if snapshot.error then
    return provider .. " err"
  end

  local first = snapshot.windows and snapshot.windows[1]
  local second = snapshot.windows and snapshot.windows[2]

  if first and first.not_implemented then
    return provider .. " n/a"
  end

  local p = first and first.remaining_percent
  local s = second and second.remaining_percent
  local reset = second and util.format_reset(second.reset_at)

  -- Use "pct" instead of "%" to avoid statusline %-escaping madness.
  -- e.g. "Codex 75pct/50pct 2.3d"
  if p and s then
    return string.format("%s %.0fpct/%.0fpct%s", provider, p, s, reset and (" " .. reset) or "")
  end

  if p then
    return string.format("%s %.0fpct%s", provider, p, reset and (" " .. reset) or "")
  end

  return provider .. " n/a"
end

return M
