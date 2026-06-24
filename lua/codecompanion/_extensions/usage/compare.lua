--- Compare AI provider usage and recommend the ACP provider that offers
--- the longest possible session without interruption.
---
--- This module extends the codecompanion usage extension with a comparison
--- command that:
---   1. Refreshes all configured providers
---   2. Reports all usages left (remaining percentages/windows)
---   3. Compares ACP providers (copilot_acp, deepseek_acp) to determine
---      which one can sustain the longest uninterrupted session
---
--- Usage:
---   :CodeCompanionUsageCompare      -- full comparison report
---   :CodeCompanionUsageCompareACP   -- ACP providers only
---
---   :lua require("codecompanion._extensions.usage.compare").report()
---   :lua require("codecompanion._extensions.usage.compare").report_acp()
---
---   -- Get the comparison result as a Lua table:
---   :lua local r = require("codecompanion._extensions.usage.compare").compare_now()

local util = require "codecompanion._extensions.usage.util"

local M = {}

-- ============================================================================
-- Helpers
-- ============================================================================

--- Format a duration in seconds to a human-readable string.
--- Examples: "45m", "2.3h", "4.2d"
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

--- Format a provider key nicely.
local function display_name(provider_key)
  local names = {
    codex = "Codex",
    claude_code = "Claude",
    copilot_acp = "Copilot",
    deepseek_acp = "DeepSeek",
  }
  return names[provider_key] or provider_key:gsub("_", " "):gsub("^(%l)", string.upper)
end

--- Determine the "bottleneck" window for a snapshot — the window that is most
--- likely to cause an interruption (lowest remaining percentage weighted by
--- window duration).
---
--- Returns the window table and a score (lower = more restrictive).
local function bottleneck_window(snapshot)
  if not snapshot or not snapshot.windows or #snapshot.windows == 0 then
    return nil, nil
  end

  local worst = nil
  local worst_score = nil

  for _, w in ipairs(snapshot.windows) do
    if w.not_implemented then
      goto continue
    end

    local remaining = w.remaining_percent
    if not remaining then
      if w.used_percent then
        remaining = math.max(0, 100 - w.used_percent)
      end
    end

    if remaining then
      -- Score: lower remaining % = more restrictive.
      -- For windows with equal remaining %, shorter window = more restrictive.
      -- So score = remaining_pct / window_seconds (lower = more restrictive).
      local window_sec = w.limit_window_seconds or (86400 * 365) -- default to ~1 year if unknown
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

--- Estimate the "uninterrupted session time" for a given snapshot.
---
--- This is a heuristic that combines the remaining percentage with the
--- window duration to estimate how long you can use the provider before
--- hitting a limit.
---
--- Returns a table with:
---   - provider: provider key
---   - label: human-readable provider name
---   - type: "time_window" | "balance"
---   - bottleneck_label: which window is the bottleneck
---   - bottleneck_remaining_pct: remaining % in the bottleneck window
---   - bottleneck_window_sec: duration of the bottleneck window
---   - estimated_session_sec: estimated seconds of uninterrupted usage
---   - estimated_session_text: human-readable session estimate
---   - balance_amount: (only for balance type) the monetary amount remaining
local function estimate_session(snapshot)
  if not snapshot then
    return nil
  end

  local provider_key = snapshot.provider or "unknown"
  local label = display_name(provider_key)

  -- Balance-based provider (DeepSeek)
  if provider_key == "deepseek_acp" then
    -- Find the balance window
    local balance_window = nil
    for _, w in ipairs(snapshot.windows or {}) do
      if w.label == "balance" then
        balance_window = w
        break
      end
    end

    if balance_window then
      -- Extract the balance value from display_text if available
      local balance_amount = nil
      if balance_window.display_text then
        local amount_str = balance_window.display_text:match "[%d%.]+"
        if amount_str then
          balance_amount = tonumber(amount_str)
        end
      end

      -- If display_text is not set, look at remaining_percent (0-100) as a
      -- proxy for "how full is the balance bucket"
      local remaining_pct = balance_window.remaining_percent
      if not remaining_pct and balance_window.used_percent then
        remaining_pct = math.max(0, 100 - balance_window.used_percent)
      end

      return {
        provider = provider_key,
        label = label,
        type = "balance",
        bottleneck_label = "balance",
        bottleneck_remaining_pct = remaining_pct,
        bottleneck_window_sec = nil,
        estimated_session_sec = nil, -- unknown without per-interaction cost
        estimated_session_text = balance_amount and string.format("$%.2f remaining", balance_amount)
          or (remaining_pct and string.format("%.0f%% remaining", remaining_pct) or "available"),
        balance_amount = balance_amount,
      }
    end

    -- No balance window found but it's deepseek_acp
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

  -- Time-window-based provider (Codex, Claude, Copilot)
  local bottleneck, score = bottleneck_window(snapshot)
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

  -- Estimate: the remaining percentage of the window duration gives a rough
  -- idea of how much "quota time" you have before the window resets.
  -- For rolling windows, this is approximate but useful for comparison.
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
-- ACP Provider Comparison
-- ============================================================================

--- Compare ACP providers (copilot_acp, deepseek_acp) and determine which
--- offers the longest uninterrupted session.
---
--- @param snapshots table: provider snapshots keyed by provider name
--- @return table with `providers`, `recommendation`, `recommendation_text`
function M.compare_acp_providers(snapshots)
  if not snapshots or vim.tbl_isempty(snapshots) then
    return {
      providers = {},
      recommendation = nil,
      recommendation_text = "No usage data available.",
    }
  end

  local acp_providers = { "copilot_acp", "deepseek_acp" }
  local estimates = {}

  for _, key in ipairs(acp_providers) do
    local snapshot = snapshots[key]
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
      recommendation_text = "No ACP providers (Copilot, DeepSeek) are enabled or have available usage data.",
    }
  end

  if #estimates == 1 then
    local only = estimates[1]
    return {
      providers = estimates,
      recommendation = only.provider,
      recommendation_text = string.format("Only one ACP provider (%s) is available with data.", only.label),
    }
  end

  -- Compare the two (or more) ACP providers.
  local best = nil
  local best_score = nil
  local best_reason = ""

  for _, est in ipairs(estimates) do
    if est.type == "balance" then
      -- Balance-based: no time limit, but finite money.
      -- Score: higher balance = more usage available.
      -- Use balance_amount if available, otherwise remaining_pct as a proxy.
      local score = est.balance_amount or (est.bottleneck_remaining_pct or 0)
      if best == nil or score > best_score then
        best = est
        best_score = score
      end
    elseif est.type == "time_window" then
      -- Time-window-based: longer window * higher remaining % = more headroom.
      -- Score = remaining_pct * window_seconds (higher = more capacity)
      local score = (est.bottleneck_remaining_pct or 0) * (est.bottleneck_window_sec or 1)
      if best == nil or score > best_score then
        best = est
        best_score = score
      end
    end
  end

  -- Build the recommendation text
  if best then
    if best.type == "balance" then
      best_reason =
        string.format("%s has no time-based limits. You can use it continuously until the balance is depleted (%s).", best.label, best.estimated_session_text)
    else
      best_reason = string.format(
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
    recommendation_text = best and best_reason or "Unable to determine the best provider.",
  }
end

-- ============================================================================
-- Report Formatting
-- ============================================================================

--- Format a single provider's usage into human-readable lines.
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

  -- Add session estimate
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

--- Build the full comparison report text from snapshots.
--- @param snapshots table: provider snapshots keyed by provider name
--- @return string
local function build_report(snapshots)
  local lines = {}
  table.insert(lines, "╔══════════════════════════════════════════╗")
  table.insert(lines, "║     AI Provider Usage Comparison        ║")
  table.insert(lines, "╚══════════════════════════════════════════╝")
  table.insert(lines, "")

  -- Sort provider keys for consistent output
  local provider_keys = {}
  for key, _ in pairs(snapshots) do
    table.insert(provider_keys, key)
  end
  table.sort(provider_keys)

  for _, key in ipairs(provider_keys) do
    local formatted = format_provider_usage(key, snapshots[key])
    table.insert(lines, formatted)
    table.insert(lines, "")
  end

  -- ACP Provider Comparison
  table.insert(lines, "─── ACP Provider Comparison ───")
  table.insert(lines, "")
  local acp_result = M.compare_acp_providers(snapshots)
  if acp_result then
    for _, est in ipairs(acp_result.providers) do
      if est.type == "balance" then
        table.insert(lines, string.format("  %s (Balance): %s", est.label, est.estimated_session_text))
      else
        table.insert(
          lines,
          string.format(
            "  %s (Time Window): bottleneck=%s, remaining=%s%%, window=%s, est.session=%s",
            est.label,
            est.bottleneck_label,
            est.bottleneck_remaining_pct and string.format("%.0f", est.bottleneck_remaining_pct) or "?",
            format_duration(est.bottleneck_window_sec) or "?",
            est.estimated_session_text
          )
        )
      end
    end
    table.insert(lines, "")
    if acp_result.recommendation then
      table.insert(lines, string.format("  ★ Recommended: %s", display_name(acp_result.recommendation)))
      table.insert(lines, string.format("    %s", acp_result.recommendation_text))
    else
      table.insert(lines, string.format("  %s", acp_result.recommendation_text))
    end
  end

  return table.concat(lines, "\n")
end

--- Build the ACP-only comparison report text from snapshots.
--- @param snapshots table: provider snapshots keyed by provider name
--- @return string
local function build_acp_report(snapshots)
  local lines = {}
  table.insert(lines, "ACP Provider Comparison:")
  table.insert(lines, "")

  local acp_result = M.compare_acp_providers(snapshots)
  if acp_result then
    for _, est in ipairs(acp_result.providers) do
      table.insert(lines, string.format("  • %s", est.label))
      if est.type == "balance" then
        table.insert(lines, string.format "      Type: Balance-based")
        table.insert(lines, string.format("      Balance: %s", est.estimated_session_text))
        table.insert(lines, string.format "      Limits: No time-based rate limits")
      else
        table.insert(lines, string.format "      Type: Time-window-based")
        table.insert(lines, string.format("      Bottleneck: %s", est.bottleneck_label))
        table.insert(lines, string.format("      Remaining: %s", est.bottleneck_remaining_pct and string.format("%.0f%%", est.bottleneck_remaining_pct) or "?"))
        table.insert(lines, string.format("      Window: %s", format_duration(est.bottleneck_window_sec) or "?"))
        table.insert(lines, string.format("      Estimated session: ~%s", est.estimated_session_text))
      end
      table.insert(lines, "")
    end

    if acp_result.recommendation then
      table.insert(lines, string.format("  ★ Recommendation: %s", display_name(acp_result.recommendation)))
      table.insert(lines, string.format("    %s", acp_result.recommendation_text))
    else
      table.insert(lines, string.format("  %s", acp_result.recommendation_text))
    end
  end

  return table.concat(lines, "\n")
end

-- ============================================================================
-- Public API
-- ============================================================================

--- Refresh all providers and display a comprehensive comparison report.
--- Uses vim.notify to show the result.
---
--- @param opts? table
---   - title: string (default: "AI Usage Comparison")
function M.report(opts)
  opts = opts or {}

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

      local report = build_report(snapshots)
      vim.notify(report, vim.log.levels.INFO, { title = opts.title or "AI Usage Comparison" })
    end)
  end)
end

--- Refresh all providers and display an ACP-focused comparison report.
---
--- @param opts? table
---   - title: string (default: "ACP Provider Comparison")
function M.report_acp(opts)
  opts = opts or {}

  local ok, usage_ext = pcall(require, "codecompanion._extensions.usage")
  if not ok then
    vim.notify("CodeCompanion Usage extension is not loaded.", vim.log.levels.ERROR)
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

      local report = build_acp_report(snapshots)
      vim.notify(report, vim.log.levels.INFO, { title = opts.title or "ACP Provider Comparison" })
    end)
  end)
end

--- Synchronously get the comparison result using cached data (no refresh).
--- Returns the same structure as compare_acp_providers().
function M.compare_now()
  local ok, usage_ext = pcall(require, "codecompanion._extensions.usage")
  if not ok then
    return nil, "CodeCompanion Usage extension is not loaded."
  end

  local exports = usage_ext.exports
  if not exports then
    return nil, "Extension not initialized."
  end

  -- Build a snapshots table from the cached last snapshots
  local snapshots = {}
  for name, _ in pairs(usage_ext.exports._state and usage_ext.exports._state.providers or {}) do
    local snap = exports.last_snapshot(name)
    if snap then
      snapshots[name] = snap
    end
  end

  if vim.tbl_isempty(snapshots) then
    return nil, "No cached usage data. Run :CodeCompanionUsageCompare first."
  end

  return M.compare_acp_providers(snapshots), nil
end

--- Register Neovim user commands.
function M.setup_commands()
  vim.api.nvim_create_user_command("CodeCompanionUsageCompare", function()
    M.report()
  end, {
    desc = "Compare all AI provider usage and recommend the best ACP provider for uninterrupted sessions",
  })

  vim.api.nvim_create_user_command("CodeCompanionUsageCompareACP", function()
    M.report_acp()
  end, {
    desc = "Compare only ACP providers (Copilot vs DeepSeek) for the longest uninterrupted session",
  })
end

return M
