vim.opt.runtimepath:prepend(vim.fn.getcwd())

local render = require("codecompanion._extensions.usage.render")

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

assert_eq(render.progress_bar(100, 12), "████████████", "100% should fill the bar")
assert_eq(render.progress_bar(83, 12), "█████████░░░", "83% should fill nine of twelve cells")
assert_eq(render.progress_bar(0, 12), "░░░░░░░░░░░░", "0% should leave the bar empty")

local colored = render.colored_progress_bar(83, 12)
assert_match(colored, "%%#CodeCompanionUsageBarFill_12_83#", "colored bar should emit one fill highlight for the whole bar")
assert_match(colored, "█", "colored bar should contain filled cells")
assert_match(colored, "░", "colored bar should contain empty cells")

local snapshot = {
  provider_label = "Codex",
  windows = {
    {
      label = "5h",
      remaining_percent = 83,
    },
  },
}

local statusline = render.bar(snapshot, { width = 12 })
assert_match(statusline, "^Codex %>%s*5h ", "bar output should keep the provider and window labels")
assert_match(statusline, "%%#CodeCompanionUsageBarFill_12_83#", "bar output should use one fill color")
assert_match(statusline, "%%#CodeCompanionUsageBarPercent#83%%*", "bar output should include the numeric percent badge")

print("render_test.lua passed")
