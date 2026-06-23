local M = {}

function M.setup(opts)
  M.opts = opts or {}
  return M
end

function M.refresh(cb)
  cb({
    provider = "claude",
    provider_label = "Claude",
    windows = {
      {
        provider = "claude",
        label = "usage",
        used_percent = nil,
        remaining_percent = nil,
        reset_at = nil,
        not_implemented = true,
      },
    },
    not_implemented = true,
    raw = {},
  }, nil)
end

return M
