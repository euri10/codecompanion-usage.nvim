local util = require("codecompanion._extensions.usage.util")

local M = {}

local bar_hl_cache = {}
local percent_hl_name = "CodeCompanionUsageBarPercent"
local empty_bar_hl_name = "CodeCompanionUsageBarEmpty"

local function compact_label(label)
  if type(label) ~= "string" or label == "" then
    return nil
  end

  local normalized = label:lower()
  if normalized == "weekly" then
    return "W"
  end

  return label
end

local function percentage_text(value)
  if value == nil then
    return nil
  end

  return string.format("%.0f%%", value)
end

local function escape_statusline(text)
  return (text:gsub("%%", "%%%%"))
end

local function clamp_percent(value)
  local n = tonumber(value)
  if not n then
    return nil
  end
  return math.max(0, math.min(100, n))
end

local function rounded_percent(value)
  local n = clamp_percent(value)
  if n == nil then
    return nil
  end
  return math.floor(n + 0.5)
end

local function hex_to_rgb(hex)
  local cleaned = tostring(hex):gsub("^#", "")
  if #cleaned ~= 6 then
    return nil
  end

  local r = tonumber(cleaned:sub(1, 2), 16)
  local g = tonumber(cleaned:sub(3, 4), 16)
  local b = tonumber(cleaned:sub(5, 6), 16)
  if not (r and g and b) then
    return nil
  end

  return r, g, b
end

local function rgb_to_hex(r, g, b)
  return string.format("#%02x%02x%02x", math.floor(r + 0.5), math.floor(g + 0.5), math.floor(b + 0.5))
end

local function lerp(a, b, t)
  return a + (b - a) * t
end

local function percent_to_color(percent)
  local t = math.max(0, math.min(1, (tonumber(percent) or 0) / 100))

  local red = { hex_to_rgb("#e74c3c") }
  local yellow = { hex_to_rgb("#f1c40f") }
  local green = { hex_to_rgb("#2ecc71") }

  if t >= 0.5 then
    local local_t = (t - 0.5) / 0.5
    return rgb_to_hex(
      lerp(yellow[1], green[1], local_t),
      lerp(yellow[2], green[2], local_t),
      lerp(yellow[3], green[3], local_t)
    )
  end

  local local_t = t / 0.5
  return rgb_to_hex(
    lerp(red[1], yellow[1], local_t),
    lerp(red[2], yellow[2], local_t),
    lerp(red[3], yellow[3], local_t)
  )
end

local function hl(group)
  return "%#" .. group .. "#"
end

local function ensure_bar_highlights(width, percent)
  width = math.max(1, math.floor(tonumber(width) or 12))

  local percent_key = rounded_percent(percent) or 0
  local cache_key = string.format("%d:%d", width, percent_key)
  if bar_hl_cache[cache_key] then
    return bar_hl_cache[cache_key]
  end

  local fill_group = string.format("CodeCompanionUsageBarFill_%d_%d", width, percent_key)
  vim.api.nvim_set_hl(0, fill_group, { fg = percent_to_color(percent_key), bold = true })

  if not bar_hl_cache.empty then
    vim.api.nvim_set_hl(0, empty_bar_hl_name, { fg = "#5c6370" })
    vim.api.nvim_set_hl(0, percent_hl_name, { fg = "#f5f7ff", bold = true })
    bar_hl_cache.empty = true
  end

  local groups = {
    fill = fill_group,
    empty = empty_bar_hl_name,
    percent = percent_hl_name,
  }
  bar_hl_cache[cache_key] = groups
  return groups
end

local function window_percent(window)
  if type(window) ~= "table" then
    return nil
  end

  if window.remaining_percent ~= nil then
    return clamp_percent(window.remaining_percent)
  end

  if window.used_percent ~= nil then
    local used = clamp_percent(window.used_percent)
    if used == nil then
      return nil
    end
    return 100 - used
  end

  return nil
end

local function format_window(window)
  if not window then
    return nil
  end

  if window.not_implemented then
    return "not implemented"
  end

  local label = compact_label(window.label)
  local used = window.used_percent
  local remaining = window.remaining_percent
  local reset = util.format_reset(window.reset_at)

  local usage
  if remaining then
    usage = percentage_text(remaining)
  elseif used then
    usage = percentage_text(used)
  else
    usage = "n/a"
  end

  if not label then
    return nil
  end

  if reset then
    return string.format("%s: %s (%s)", label, usage, reset)
  end

  return string.format("%s: %s", label, usage)
end

local function progress_bar(percent, width)
  width = math.max(1, math.floor(tonumber(width) or 12))
  percent = clamp_percent(percent)
  if percent == nil then
    return string.rep("░", width)
  end

  local filled = math.floor((percent / 100) * width + 1e-9)
  if percent >= 100 then
    filled = width
  end

  return string.rep("█", filled) .. string.rep("░", width - filled)
end

local function colored_progress_bar(percent, width)
  width = math.max(1, math.floor(tonumber(width) or 12))
  local groups = ensure_bar_highlights(width, percent)
  percent = clamp_percent(percent)
  if percent == nil then
    return hl(empty_bar_hl_name) .. string.rep("░", width) .. "%*"
  end

  local filled = math.floor((percent / 100) * width + 1e-9)
  if percent >= 100 then
    filled = width
  end

  local parts = {}
  parts[#parts + 1] = hl(groups.fill) .. string.rep("█", filled)
  parts[#parts + 1] = hl(groups.empty) .. string.rep("░", width - filled)
  parts[#parts + 1] = "%*"
  return table.concat(parts)
end

local function percent_badge(percent)
  percent = rounded_percent(percent)
  if percent == nil then
    return hl(percent_hl_name) .. "n/a" .. "%*"
  end

  return hl(percent_hl_name) .. tostring(percent) .. "%*"
end

local function format_window_bar(window, width)
  if not window then
    return nil
  end

  if window.not_implemented then
    return "not implemented"
  end

  local label = compact_label(window.label)
  local percent = window_percent(window)

  if not label then
    return nil
  end

  if not percent then
    return escape_statusline(label .. ": n/a")
  end

  local reset = util.format_reset(window.reset_at)
  local bar = escape_statusline(label) .. " " .. colored_progress_bar(percent, width) .. " " .. percent_badge(percent)
  if reset then
    bar = bar .. escape_statusline(" (" .. reset .. ")")
  end
  return bar
end

local function snapshot_title(snapshot)
  local title = snapshot.provider_label or snapshot.provider or "Usage"
  if snapshot.plan_type then
    title = title .. " usage (" .. snapshot.plan_type .. ")"
  else
    title = title .. " usage"
  end
  return title
end

function M.provider(snapshot)
  if not snapshot then
    return "Usage: unavailable"
  end

  local title = snapshot_title(snapshot)

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

function M.bar(snapshot, opts)
  opts = opts or {}

  if not snapshot then
    return escape_statusline("usage > n/a")
  end

  local title = snapshot.provider_label or snapshot.provider or "usage"
  if snapshot.not_implemented then
    return escape_statusline(title .. " > n/a")
  end

  if snapshot.error then
    return escape_statusline(title .. " > err")
  end

  local width = opts.width or 12
  local parts = {}

  for _, window in ipairs(snapshot.windows or {}) do
    local formatted = format_window_bar(window, width)
    if formatted then
      parts[#parts + 1] = formatted
    end
    if #parts >= 2 then
      break
    end
  end

  if #parts == 0 then
    return escape_statusline(title .. " > n/a")
  end

  return escape_statusline(title .. " > ") .. table.concat(parts, " ")
end

---Return a single-line compact string suitable for a statusline.
---NOTE: Never emit raw "%" — Neovim's statusline engine interprets % sequences.
---@param snapshot table
---@return string
function M.compact(snapshot)
  if not snapshot then
    return escape_statusline("usage > n/a")
  end

  local provider = snapshot.provider_label or snapshot.provider or "usage"

  if snapshot.not_implemented then
    return escape_statusline(provider .. " > n/a")
  end

  if snapshot.error then
    return escape_statusline(provider .. " > err")
  end

  local first = snapshot.windows and snapshot.windows[1]
  local second = snapshot.windows and snapshot.windows[2]

  if first and first.not_implemented then
    return escape_statusline(provider .. " > n/a")
  end

  local parts = {}
  local first_formatted = format_window(first)
  local second_formatted = format_window(second)

  if first_formatted then
    table.insert(parts, first_formatted)
  end
  if second_formatted then
    table.insert(parts, second_formatted)
  end

  if #parts == 0 then
    return escape_statusline(provider .. " > n/a")
  end

  return escape_statusline(provider .. " > " .. table.concat(parts, " "))
end

M.progress_bar = progress_bar
M.colored_progress_bar = colored_progress_bar

return M
