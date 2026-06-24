vim.opt.runtimepath:prepend(vim.fn.getcwd())

local compare = require("codecompanion._extensions.usage.compare")

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s\nexpected: %s\nactual:   %s", message or "assertion failed", vim.inspect(expected), vim.inspect(actual)))
  end
end

local function assert_match(value, pattern, message)
  if not value:match(pattern) then
    error(string.format("%s\npattern: %s\nvalue:   %s", message or "assertion failed", pattern, value))
  end
end

-- ============================================================================
-- Test: format_duration (internal via compare_acp_providers output)
-- ============================================================================

-- Create a mock copilot_acp snapshot
local copilot_snapshot = {
  provider = "copilot_acp",
  provider_label = "Copilot",
  plan_type = "Free Limited Copilot",
  windows = {
    {
      label = "premium_interactions",
      remaining_percent = 80,
      reset_at = nil,
      limit_window_seconds = 3600, -- 1 hour
    },
    {
      label = "chat",
      remaining_percent = 85,
      reset_at = nil,
      limit_window_seconds = 30 * 86400, -- 30 days
    },
    {
      label = "completions",
      remaining_percent = 90,
      reset_at = nil,
      limit_window_seconds = 30 * 86400, -- 30 days
    },
  },
}

-- Create a mock deepseek_acp snapshot (balance-based)
local deepseek_balance_snapshot = {
  provider = "deepseek_acp",
  provider_label = "DeepSeek",
  plan_type = nil,
  windows = {
    {
      label = "balance",
      display_text = "balance: USD 5.20",
    },
  },
}

-- Create a mock deepseek_acp snapshot (percentage-based)
local deepseek_pct_snapshot = {
  provider = "deepseek_acp",
  provider_label = "DeepSeek",
  plan_type = nil,
  windows = {
    {
      label = "balance",
      remaining_percent = 42,
    },
  },
}

-- Create a mock codex snapshot
local codex_snapshot = {
  provider = "codex",
  provider_label = "Codex",
  plan_type = "plus",
  windows = {
    {
      label = "5h",
      remaining_percent = 89,
      reset_at = os.time() + 15840, -- 4.4 hours
      limit_window_seconds = 5 * 3600,
    },
    {
      label = "weekly",
      remaining_percent = 18,
      reset_at = os.time() + 155520, -- 1.8 days
      limit_window_seconds = 7 * 86400,
    },
  },
}

-- Create a mock claude_code snapshot
local claude_snapshot = {
  provider = "claude_code",
  provider_label = "Claude",
  plan_type = "Pro",
  windows = {
    {
      label = "5h",
      remaining_percent = 75,
      reset_at = os.time() + 10800, -- 3 hours
      limit_window_seconds = 5 * 3600,
    },
    {
      label = "weekly",
      remaining_percent = 60,
      reset_at = os.time() + 345600, -- 4 days
      limit_window_seconds = 7 * 86400,
    },
  },
}

-- ============================================================================
-- Test: compare_acp_providers with both ACP providers
-- ============================================================================

local snapshots_with_both = {
  copilot_acp = copilot_snapshot,
  deepseek_acp = deepseek_balance_snapshot,
}

local result = compare.compare_acp_providers(snapshots_with_both)
assert_eq(type(result), "table", "compare_acp_providers should return a table")
assert_eq(type(result.providers), "table", "result.providers should be a table")
assert_eq(#result.providers, 2, "should have 2 ACP provider estimates")
assert_eq(type(result.recommendation), "string", "should have a recommendation")
assert_eq(type(result.recommendation_text), "string", "should have recommendation text")

-- Verify both providers are represented
local found_copilot = false
local found_deepseek = false
for _, est in ipairs(result.providers) do
  if est.provider == "copilot_acp" then
    found_copilot = true
    assert_eq(est.type, "time_window", "copilot should be time_window type")
    assert_eq(est.bottleneck_label, "premium_interactions", "copilot bottleneck should be premium_interactions")
    assert_eq(est.bottleneck_remaining_pct, 80, "copilot remaining should be 80%")
    assert_eq(est.bottleneck_window_sec, 3600, "copilot window should be 3600s")
    assert_eq(est.estimated_session_sec, 2880, "estimated session should be 2880s (80% of 3600)")
    assert_match(est.estimated_session_text, "%d+m", "session text should be human-readable")
  elseif est.provider == "deepseek_acp" then
    found_deepseek = true
    assert_eq(est.type, "balance", "deepseek should be balance type")
    assert_eq(est.balance_amount, 5.20, "deepseek balance should be 5.20")
    assert_match(est.estimated_session_text, "%$5%.20", "should show $5.20")
  end
end
assert_eq(found_copilot, true, "should include Copilot")
assert_eq(found_deepseek, true, "should include DeepSeek")

print("compare_test.lua: both ACP providers test passed")

-- ============================================================================
-- Test: compare_acp_providers with only copilot
-- ============================================================================

local snapshots_only_copilot = {
  copilot_acp = copilot_snapshot,
}

local result_only = compare.compare_acp_providers(snapshots_only_copilot)
assert_eq(#result_only.providers, 1, "should have 1 estimate")
assert_eq(result_only.providers[1].provider, "copilot_acp", "should be copilot")
assert_eq(result_only.recommendation, "copilot_acp", "recommendation should be copilot")

print("compare_test.lua: only copilot test passed")

-- ============================================================================
-- Test: compare_acp_providers with no ACP providers
-- ============================================================================

local snapshots_no_acp = {
  codex = codex_snapshot,
  claude_code = claude_snapshot,
}

local result_none = compare.compare_acp_providers(snapshots_no_acp)
assert_eq(#result_none.providers, 0, "should have 0 estimates when no ACP providers")
assert_eq(result_none.recommendation, nil, "recommendation should be nil")

print("compare_test.lua: no ACP providers test passed")

-- ============================================================================
-- Test: compare_acp_providers with DeepSeek percentage-based balance
-- ============================================================================

local snapshots_deepseek_pct = {
  deepseek_acp = deepseek_pct_snapshot,
}

local result_ds_pct = compare.compare_acp_providers(snapshots_deepseek_pct)
assert_eq(#result_ds_pct.providers, 1, "should have 1 estimate")
assert_eq(result_ds_pct.providers[1].provider, "deepseek_acp", "should be deepseek")
assert_eq(result_ds_pct.providers[1].type, "balance", "should be balance type")
assert_eq(result_ds_pct.providers[1].bottleneck_remaining_pct, 42, "remaining pct should be 42")
assert_match(result_ds_pct.providers[1].estimated_session_text, "42%%", "should show 42% remaining")

print("compare_test.lua: DeepSeek percentage balance test passed")

-- ============================================================================
-- Test: compare_acp_providers with error snapshots
-- ============================================================================

local snapshots_with_error = {
  copilot_acp = { provider = "copilot_acp", error = "Network error" },
  deepseek_acp = deepseek_balance_snapshot,
}

local result_err = compare.compare_acp_providers(snapshots_with_error)
assert_eq(#result_err.providers, 1, "should skip errored provider")
assert_eq(result_err.providers[1].provider, "deepseek_acp", "should only have deepseek")

print("compare_test.lua: error handling test passed")

-- ============================================================================
-- Test: compare_acp_providers with empty snapshots
-- ============================================================================

local result_empty = compare.compare_acp_providers({})
assert_eq(#result_empty.providers, 0, "should have 0 estimates for empty snapshots")

local result_nil = compare.compare_acp_providers(nil)
assert_eq(#result_nil.providers, 0, "should handle nil snapshots")

print("compare_test.lua: empty/nil test passed")

print("\n✓ All compare_test.lua tests passed!")
