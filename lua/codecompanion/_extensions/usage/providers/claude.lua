local M = {}

function M.setup(opts)
  M.opts = opts or {}
  return M
end

function M.refresh(cb)
  cb(nil, "Claude provider is not implemented yet")
end

return M
