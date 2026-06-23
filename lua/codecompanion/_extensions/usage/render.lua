local util = require("codecompanion._extensions.usage.util")

local M = {}

local bar_hl_cache = {}

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

local function gradient_color(t)
  t = math.max(0, math.min(1, tonumber(t) or 0))

  local green = { hex_to_rgb("#2ecc71") }
  local yellow = { hex_to_rgb("#f1c40f") }
  local red = { hex_to_rgb("#e74c3c") }

  if t >= 0.5 then
    local local_t = (t - 0.5) / 0.5
    return rgb_to_hex(
      lerp(green[1], yellow[1], local_t),
      lerp(green[2], yellow[2], local_t),
      lerp(green[3], yellow[3], local_t)
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

local function ensure_bar_highlights(width)
  width = math.max(1, math.floor(tonumber(width) or 12))

  if bar_hl_cache[width] then
    return bar_hl_cache[width]
  end

  local groups = {}
  for i = 1, width do
    local ratio = width == 1 and 1 or (i - 1) / (width - 1)
    local group = string.format("CodeCompanionUsageBarFill_%d_%d", width, i)
    vim.api.nvim_set_hl(0, group, { fg = gradient_color(ratio) })
    groups[i] = group
  end

  vim.api.nvim_set_hl(0, "CodeCompanionUsageBarEmpty", { fg = "#5c6370" })
  bar_hl_cache[width] = groups
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
  ensure_bar_highlights(width)
  percent = clamp_percent(percent)
  if percent == nil then
    return hl("CodeCompanionUsageBarEmpty") .. string.rep("░", width) .. "%*"
  end

  local groups = bar_hl_cache[width]
  local filled = math.floor((percent / 100) * width + 1e-9)
  if percent >= 100 then
    filled = width
  end

  local parts = {}
  for i = 1, width do
    if i <= filled then
      parts[#parts + 1] = hl(groups[i]) .. "█"
    else
      parts[#parts + 1] = hl("CodeCompanionUsageBarEmpty") .. "░"
    end
  end
  parts[#parts + 1] = "%*"
  return table.concat(parts)
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

  return escape_statusline(label) .. " " .. colored_progress_bar(percent, width)
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
