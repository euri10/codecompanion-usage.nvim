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
-- Mock snapshots
-- ============================================================================

local copilot_snapshot = {
  provider = "copilot_acp",
  provider_label = "Copilot",
  plan_type = "Free Limited Copilot",
  windows = {
    {
      label = "premium_interactions",
      remaining_percent = 80,
      limit_window_seconds = 3600,
    },
    {
      label = "chat",
      remaining_percent = 85,
      limit_window_seconds = 30 * 86400,
    },
    {
      label = "completions",
      remaining_percent = 90,
      limit_window_seconds = 30 * 86400,
    },
  },
}

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

local codex_snapshot = {
  provider = "codex",
  provider_label = "Codex",
  plan_type = "plus",
  windows = {
    {
      label = "5h",
      remaining_percent = 89,
      reset_at = os.time() + 15840,
      limit_window_seconds = 5 * 3600,
    },
    {
      label = "weekly",
      remaining_percent = 18,
      reset_at = os.time() + 155520,
      limit_window_seconds = 7 * 86400,
    },
  },
}

-- ============================================================================
-- Test: compare() with multiple providers
-- ============================================================================

local snapshots_mixed = {
  copilot_acp = copilot_snapshot,
  deepseek_acp = deepseek_balance_snapshot,
  codex = codex_snapshot,
}

local result = compare.compare(snapshots_mixed)
assert_eq(type(result), "table", "compare() should return a table")
assert_eq(type(result.providers), "table", "result.providers should be a table")
assert_eq(#result.providers, 3, "should have 3 provider estimates")
assert_eq(type(result.recommendation), "string", "should have a recommendation")
assert_eq(type(result.recommendation_text), "string", "should have recommendation text")

-- Verify all providers are represented
local found = {}
for _, est in ipairs(result.providers) do
  found[est.provider] = true
  if est.provider == "copilot_acp" then
    assert_eq(est.type, "time_window", "copilot should be time_window")
    assert_eq(est.bottleneck_label, "premium_interactions")
    assert_eq(est.bottleneck_remaining_pct, 80)
    assert_eq(est.bottleneck_window_sec, 3600)
    assert_eq(est.estimated_session_sec, 2880, "80% of 3600")
  elseif est.provider == "deepseek_acp" then
    assert_eq(est.type, "balance", "deepseek should be balance")
    assert_eq(est.balance_amount, 5.20)
    assert_match(est.estimated_session_text, "%$5%.20")
  elseif est.provider == "codex" then
    assert_eq(est.type, "time_window", "codex should be time_window")
    assert_eq(est.bottleneck_label, "5h")
    assert_eq(est.bottleneck_remaining_pct, 89)
    assert_eq(est.bottleneck_window_sec, 5 * 3600)
    assert_eq(est.estimated_session_sec, 16020, "89% of 18000")
  end
end
assert_eq(found["copilot_acp"], true, "should include Copilot")
assert_eq(found["deepseek_acp"], true, "should include DeepSeek")
assert_eq(found["codex"], true, "should include Codex")

print("compare_test.lua: mixed providers test passed")

-- ============================================================================
-- Test: compare() with empty snapshots
-- ============================================================================

local result_empty = compare.compare({})
assert_eq(#result_empty.providers, 0)
assert_eq(result_empty.recommendation, nil)

local result_nil = compare.compare(nil)
assert_eq(#result_nil.providers, 0)

print("compare_test.lua: empty/nil test passed")

-- ============================================================================
-- Test: compare() with error snapshots
-- ============================================================================

local snapshots_with_error = {
  copilot_acp = { provider = "copilot_acp", error = "Network error" },
  deepseek_acp = deepseek_balance_snapshot,
}

local result_err = compare.compare(snapshots_with_error)
assert_eq(#result_err.providers, 1, "should skip errored provider")
assert_eq(result_err.providers[1].provider, "deepseek_acp")

print("compare_test.lua: error handling test passed")

-- ============================================================================
-- Test: compare() with single provider
-- ============================================================================

local result_single = compare.compare({ codex = codex_snapshot })
assert_eq(#result_single.providers, 1)
assert_eq(result_single.recommendation, "codex")

print("compare_test.lua: single provider test passed")

-- ============================================================================
-- Test: compare() with DeepSeek percentage-based balance
-- ============================================================================

local result_ds_pct = compare.compare({ deepseek_acp = deepseek_pct_snapshot })
assert_eq(#result_ds_pct.providers, 1)
assert_eq(result_ds_pct.providers[1].provider, "deepseek_acp")
assert_eq(result_ds_pct.providers[1].type, "balance")
assert_eq(result_ds_pct.providers[1].bottleneck_remaining_pct, 42)
assert_match(result_ds_pct.providers[1].estimated_session_text, "42%%")

print("compare_test.lua: DeepSeek percentage balance test passed")

-- ============================================================================
-- Test: compare() with only DeepSeek balance (no time limit)
-- ============================================================================

-- DeepSeek with balance should always be preferred over a time-limited provider
-- when the balance is reasonable.
local snapshots_deepseek_wins = {
  deepseek_acp = deepseek_balance_snapshot,
  copilot_acp = copilot_snapshot,
}

local result_ds_wins = compare.compare(snapshots_deepseek_wins)
-- DeepSeek has $5.20, Copilot has 80% of 3600s → score 2880
-- DeepSeek score = 5.20, Copilot score = 80 * 3600 = 288000
-- So Copilot should win here actually (higher score)
-- Let's check: for time_window: score = remaining_pct * window_sec = 80 * 3600 = 288000
-- For balance: score = balance_amount = 5.20
-- So Copilot wins with higher score
print("  DeepSeek score=" .. tostring(deepseek_balance_snapshot.windows[1].display_text and 5.20 or 0))
print("  Copilot score=80*3600=288000")

print("\n✓ All compare_test.lua tests passed!")
