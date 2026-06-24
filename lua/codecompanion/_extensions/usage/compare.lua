--- Compare all AI provider usages and recommend the provider that offers
--- the longest possible session without interruption.
---
--- Command (auto-registered on setup):
---   :CodeCompanionUsageCompare
---
--- Lua:
---   require("codecompanion._extensions.usage.compare").report()
---   local result = require("codecompanion._extensions.usage.compare").compare_now()

local util = require "codecompanion._extensions.usage.util"

local M = {}

-- ============================================================================
-- Helpers
-- ============================================================================

local function format_duration(seconds)
  if not seconds or seconds <= 0 then
    return nil
  end

  if seconds < 60 then
    return string.format("%ds", seconds)
  end
  if seconds < 3600 then
    return string.format("%dm", math.ceil(seconds / 60))
  end
  if seconds < 86400 then
    return string.format("%.1fh", seconds / 3600)
  end
  return string.format("%.1fd", seconds / 86400)
end

local function display_name(provider_key)
  local names = {
    codex = "Codex",
    claude_code = "Claude",
    copilot_acp = "Copilot",
    deepseek_acp = "DeepSeek",
  }
  return names[provider_key] or provider_key:gsub("_", " "):gsub("^(%l)", string.upper)
end

--- Find the bottleneck window for a snapshot (the limit you'll hit first).
--- Lower remaining% in a shorter window = more restrictive.
local function bottleneck_window(snapshot)
  if not snapshot or not snapshot.windows or #snapshot.windows == 0 then
    return nil
  end

  local worst = nil
  local worst_score = nil

  for _, w in ipairs(snapshot.windows) do
    if w.not_implemented then
      goto continue
    end

    local remaining = w.remaining_percent
    if not remaining and w.used_percent then
      remaining = math.max(0, 100 - w.used_percent)
    end

    if remaining then
      local window_sec = w.limit_window_seconds or (86400 * 365)
      local score = remaining / window_sec
      if worst == nil or score < worst_score then
        worst = w
        worst_score = score
      end
    end

    ::continue::
  end

  return worst, worst_score
end

--- Estimate uninterrupted session time for a provider.
local function estimate_session(snapshot)
  if not snapshot then
    return nil
  end

  local provider_key = snapshot.provider or "unknown"
  local label = display_name(provider_key)

  -- Balance-based provider (DeepSeek)
  if provider_key == "deepseek_acp" then
    for _, w in ipairs(snapshot.windows or {}) do
      if w.label == "balance" then
        local amount_str = w.display_text and w.display_text:match "[%d%.]+"
        local balance_amount = amount_str and tonumber(amount_str)
        local remaining_pct = w.remaining_percent
        if not remaining_pct and w.used_percent then
          remaining_pct = math.max(0, 100 - w.used_percent)
        end

        return {
          provider = provider_key,
          label = label,
          type = "balance",
          bottleneck_label = "balance",
          bottleneck_remaining_pct = remaining_pct,
          bottleneck_window_sec = nil,
          estimated_session_sec = nil,
          estimated_session_text = balance_amount and string.format("$%.2f remaining", balance_amount)
            or (remaining_pct and string.format("%.0f%% remaining", remaining_pct) or "available"),
          balance_amount = balance_amount,
        }
      end
    end
    return {
      provider = provider_key,
      label = label,
      type = "balance",
      bottleneck_label = "balance",
      bottleneck_remaining_pct = nil,
      bottleneck_window_sec = nil,
      estimated_session_sec = nil,
      estimated_session_text = "available",
      balance_amount = nil,
    }
  end

  -- Time-window-based provider
  local bottleneck = bottleneck_window(snapshot)
  if not bottleneck then
    return {
      provider = provider_key,
      label = label,
      type = "time_window",
      bottleneck_label = "none",
      bottleneck_remaining_pct = nil,
      bottleneck_window_sec = nil,
      estimated_session_sec = nil,
      estimated_session_text = "no limit data",
    }
  end

  local remaining = bottleneck.remaining_percent
  if not remaining and bottleneck.used_percent then
    remaining = math.max(0, 100 - bottleneck.used_percent)
  end

  local window_sec = bottleneck.limit_window_seconds or 3600
  local remaining_frac = math.max(0, math.min(1, (remaining or 0) / 100))
  local estimated_sec = window_sec * remaining_frac

  return {
    provider = provider_key,
    label = label,
    type = "time_window",
    bottleneck_label = bottleneck.label,
    bottleneck_remaining_pct = remaining,
    bottleneck_window_sec = window_sec,
    estimated_session_sec = estimated_sec,
    estimated_session_text = format_duration(estimated_sec) or "unknown",
  }
end

-- ============================================================================
-- Comparison
-- ============================================================================

--- Compare all providers and return the one offering the longest session.
--- @param snapshots table: provider snapshots keyed by name
--- @return table { providers, recommendation, recommendation_text }
function M.compare(snapshots)
  if not snapshots or vim.tbl_isempty(snapshots) then
    return {
      providers = {},
      recommendation = nil,
      recommendation_text = "No usage data available.",
    }
  end

  local estimates = {}
  for key, snapshot in pairs(snapshots) do
    if snapshot and not snapshot.error then
      local est = estimate_session(snapshot)
      if est then
        table.insert(estimates, est)
      end
    end
  end

  if #estimates == 0 then
    return {
      providers = {},
      recommendation = nil,
      recommendation_text = "No enabled providers have available usage data.",
    }
  end

  if #estimates == 1 then
    local only = estimates[1]
    return {
      providers = estimates,
      recommendation = only.provider,
      recommendation_text = string.format("Only one provider (%s) is available.", only.label),
    }
  end

  -- Pick the best: balance amount or remaining_pct * window_sec
  local best, best_score
  for _, est in ipairs(estimates) do
    local score = est.type == "balance"
      and (est.balance_amount or (est.bottleneck_remaining_pct or 0))
      or ((est.bottleneck_remaining_pct or 0) * (est.bottleneck_window_sec or 1))
    if best == nil or score > best_score then
      best = est
      best_score = score
    end
  end

  local reason
  if best then
    if best.type == "balance" then
      reason = string.format(
        "%s has no time-based limits. Use it continuously until the balance is depleted (%s).",
        best.label, best.estimated_session_text
      )
    else
      reason = string.format(
        "%s has %s remaining in its most restrictive window (%s, window: %s). Estimated uninterrupted usage: ~%s.",
        best.label,
        best.bottleneck_remaining_pct and string.format("%.0f%%", best.bottleneck_remaining_pct) or "unknown",
        best.bottleneck_label,
        format_duration(best.bottleneck_window_sec) or "unknown",
        best.estimated_session_text
      )
    end
  end

  return {
    providers = estimates,
    recommendation = best and best.provider or nil,
    recommendation_text = best and reason or "Unable to determine the best provider.",
  }
end

-- ============================================================================
-- Formatting
-- ============================================================================

local function format_provider_usage(provider_key, snapshot)
  if not snapshot then
    return string.format("  - %s: unavailable", display_name(provider_key))
  end
  if snapshot.error then
    return string.format("  - %s: error — %s", display_name(provider_key), snapshot.error)
  end

  local lines = {}
  local label = snapshot.provider_label or display_name(provider_key)

  if snapshot.plan_type then
    table.insert(lines, string.format("  - %s (%s):", label, snapshot.plan_type))
  else
    table.insert(lines, string.format("  - %s:", label))
  end

  for _, w in ipairs(snapshot.windows or {}) do
    if w.not_implemented then
      table.insert(lines, string.format("      %s: not implemented", w.label))
    elseif w.display_text then
      table.insert(lines, string.format("      %s", w.display_text))
    else
      local parts = {}
      if w.remaining_percent then
        table.insert(parts, string.format("%.0f%% left", w.remaining_percent))
      elseif w.used_percent then
        table.insert(parts, string.format("%.0f%% used", w.used_percent))
      else
        table.insert(parts, "n/a")
      end
      if w.reset_at then
        local reset_text = util.format_reset(w.reset_at)
        if reset_text then
          table.insert(parts, string.format("resets %s", reset_text))
        end
      end
      if w.limit_window_seconds then
        table.insert(parts, string.format("window: %s", format_duration(w.limit_window_seconds)))
      end
      table.insert(lines, string.format("      %s: %s", w.label, table.concat(parts, ", ")))
    end
  end

  local est = estimate_session(snapshot)
  if est then
    if est.type == "balance" then
      table.insert(lines, string.format("      → session: %s (no time-based limit)", est.estimated_session_text))
    else
      table.insert(lines, string.format("      → session: ~%s before hitting %s limit", est.estimated_session_text, est.bottleneck_label))
    end
  end

  return table.concat(lines, "\n")
end

local function build_report(snapshots)
  local lines = {}
  table.insert(lines, "╔══════════════════════════════════════════╗")
  table.insert(lines, "║        AI Provider Usage Comparison     ║")
  table.insert(lines, "╚══════════════════════════════════════════╝")
  table.insert(lines, "")

  local provider_keys = vim.tbl_keys(snapshots)
  table.sort(provider_keys)

  for _, key in ipairs(provider_keys) do
    table.insert(lines, format_provider_usage(key, snapshots[key]))
    table.insert(lines, "")
  end

  -- Recommendation
  table.insert(lines, "─── Recommendation ───")
  table.insert(lines, "")
  local result = M.compare(snapshots)
  if result then
    for _, est in ipairs(result.providers) do
      if est.type == "balance" then
        table.insert(lines, string.format("  %s (Balance): %s", est.label, est.estimated_session_text))
      else
        table.insert(lines, string.format(
          "  %s: bottleneck=%s, remaining=%s%%, window=%s, est.session=%s",
          est.label,
          est.bottleneck_label,
          est.bottleneck_remaining_pct and string.format("%.0f", est.bottleneck_remaining_pct) or "?",
          format_duration(est.bottleneck_window_sec) or "?",
          est.estimated_session_text
        ))
      end
    end
    table.insert(lines, "")
    if result.recommendation then
      table.insert(lines, string.format("  ★ Best choice: %s", display_name(result.recommendation)))
      table.insert(lines, string.format("    %s", result.recommendation_text))
    else
      table.insert(lines, string.format("  %s", result.recommendation_text))
    end
  end

  return table.concat(lines, "\n")
end

-- ============================================================================
-- Public API
-- ============================================================================

--- Refresh all providers and show the comparison report.
function M.report()
  local ok, usage_ext = pcall(require, "codecompanion._extensions.usage")
  if not ok then
    vim.notify("CodeCompanion Usage extension is not loaded. Run :CodeCompanionUsage setup first.", vim.log.levels.ERROR)
    return
  end

  local exports = usage_ext.exports
  if not exports or not exports.refresh_all then
    vim.notify("CodeCompanion Usage extension is not properly initialized.", vim.log.levels.ERROR)
    return
  end

  exports.refresh_all(function(snapshots, err)
    vim.schedule(function()
      if err then
        vim.notify("Failed to refresh providers: " .. tostring(err), vim.log.levels.ERROR)
        return
      end
      vim.notify(build_report(snapshots), vim.log.levels.INFO, { title = "AI Usage Comparison" })
    end)
  end)
end

--- Get comparison from cached data (no refresh).
function M.compare_now()
  local ok, usage_ext = pcall(require, "codecompanion._extensions.usage")
  if not ok then
    return nil, "CodeCompanion Usage extension is not loaded."
  end

  local exports = usage_ext.exports
  if not exports then
    return nil, "Extension not initialized."
  end

  local snapshots = {}
  for name, _ in pairs((exports._state or {}).providers or {}) do
    local snap = exports.last_snapshot(name)
    if snap then
      snapshots[name] = snap
    end
  end

  if vim.tbl_isempty(snapshots) then
    return nil, "No cached usage data. Run :CodeCompanionUsageCompare first."
  end

  return M.compare(snapshots), nil
end

--- Register the :CodeCompanionUsageCompare command.
function M.setup_commands()
  vim.api.nvim_create_user_command("CodeCompanionUsageCompare", function()
    M.report()
  end, { desc = "Compare AI provider usage and recommend the provider with the longest uninterrupted session" })
end

return M
