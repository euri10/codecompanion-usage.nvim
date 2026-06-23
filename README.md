# CodeCompanion Usage

A Neovim extension for [codecompanion.nvim](https://github.com/olimorris/codecompanion.nvim) that displays AI usage and rate-limit information in your statusline.

Shows usage statistics for:
- **Codex** (OpenAI Codex CLI) – reads auth from `~/.codex/auth.json` and queries the Codex usage API
- **Claude** (Anthropic Claude Code) – reads OAuth credentials from `~/.claude/.credentials.json` and queries the Anthropic OAuth usage API. The canonical provider key is `claude_code`; the legacy `claude` alias is still accepted.

Built following the architecture of [CodexBar](https://github.com/steipete/CodexBar).

## Installation

Using **lazy.nvim**:

```lua
{
  "olimorris/codecompanion.nvim",
  dependencies = {
    -- … other dependencies
    {
      "your-username/codecompanion-usage.nvim",
      config = function()
        require("codecompanion._extensions.usage").setup({
          providers = {
            codex = { enabled = true },
            claude_code = { enabled = true },
          },
        })
      end,
    },
  },
}
```

## How It Works

### Codex Provider
Reads the Codex access token from `~/.codex/auth.json` (or `$CODEX_HOME/auth.json`) and calls the Codex usage API at `https://chatgpt.com/backend-api/wham/usage`. No token refresh is performed; if the token is expired, run `codex login` to refresh.

### Claude Provider
Reads the OAuth access token from `~/.claude/.credentials.json` and calls `https://api.anthropic.com/api/oauth/usage`. If the token is expired, it attempts a refresh via `https://platform.claude.com/v1/oauth/token` using the stored refresh token. Updated tokens are written back to the credentials file.

> **Note:** The Claude OAuth token in `.credentials.json` may become stale because the Claude CLI does not always write refreshed tokens back to this file. If you see an authentication error, run `claude login` (or simply use `claude` interactively) to refresh your session, then try again.

## Configuration

```lua
require("codecompanion._extensions.usage").setup({
  default_provider = "codex",       -- or "claude_code"
  auto_refresh = true,
  auto_refresh_debounce_ms = 2000,
  refresh_interval_sec = 300,       -- periodic refresh (0 = disabled)

  providers = {
    codex = {
      enabled = true,
      -- endpoint = "https://chatgpt.com/backend-api/wham/usage",
      -- auth_path = "~/.codex/auth.json",
      -- timeout_ms = 10000,
    },
    claude_code = {
      enabled = true,
      -- credentials_path = "~/.claude/.credentials.json",
      -- usage_endpoint = "https://api.anthropic.com/api/oauth/usage",
      -- allow_token_refresh = true,
      -- timeout_ms = 10000,
    },
  },
})
```

> **Backward compatibility:** The legacy provider key `claude` is normalized to `claude_code`. Existing configurations using `claude = { enabled = true }` will continue to work.

## Statusline

The extension exposes a global table `_G.codecompanion_usage_stl` keyed by buffer number. You can use it in your statusline:

```lua
-- Example statusline component
function _G.codecompanion_usage_status()
  local bufnr = vim.api.nvim_get_current_buf()
  return _G.codecompanion_usage_stl[bufnr] or ""
end
```

For [lualine.nvim](https://github.com/nvim-lualine/lualine.nvim):

```lua
{
  function()
    return _G.codecompanion_usage_stl[vim.api.nvim_get_current_buf()] or ""
  end,
  cond = function()
    return _G.codecompanion_usage_stl[vim.api.nvim_get_current_buf()] ~= nil
  end,
}
```

The compact render is provider-agnostic and uses the same shape for Codex and Claude, for example:

```text
Codex > 5h: 89% (4.4h) W: 18% (1.8d)
```

## Requirements

- Neovim 0.9+
- [codecompanion.nvim](https://github.com/olimorris/codecompanion.nvim)
- `curl` (for API requests)

## License

MIT
