local M = {}

local function make_enum(values)
  local ret = {}
  for _, v in ipairs(values) do
    ret[v] = v
  end
  return setmetatable(ret, {
    __index = function(_, key)
      error(string.format("Unknown constant value '%s'", key))
    end,
  })
end

M.STATUS = make_enum({ "PENDING", "RUNNING", "CANCELED", "SUCCESS", "FAILURE" })

M.SLOT = make_enum({ "SUMMARY", "RESULT", "NOTIFY", "DISPOSE" })

M.TAG = make_enum({ "TEST", "BUILD", "SERVE" })

return M
