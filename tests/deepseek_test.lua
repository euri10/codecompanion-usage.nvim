vim.opt.runtimepath:prepend(vim.fn.getcwd())

local deepseek = require("codecompanion._extensions.usage.providers.deepseek_acp")

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s\nexpected: %s\nactual:   %s", message or "assertion failed", vim.inspect(expected), vim.inspect(actual)))
  end
end

-- Test setup
local provider = deepseek.setup({})
assert_eq(provider ~= nil, true, "setup should return a provider")
assert_eq(provider.refresh ~= nil, true, "provider should have refresh method")
assert_eq(provider.fetch_raw ~= nil, true, "provider should have fetch_raw method")

print("deepseek_test.lua passed")
