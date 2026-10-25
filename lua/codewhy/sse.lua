-- Minimal Server-Sent Events line parser.
local M = {}

---@param on_data fun(data: string) called with the payload of each `data:` line
---@param on_other fun(line: string)|nil called with non-SSE lines (e.g. a JSON error body)
function M.new(on_data, on_other)
  local buf = ""
  local self = {}

  local function handle(line)
    line = line:gsub("\r$", "")
    if line == "" or line:sub(1, 1) == ":" then
      return -- blank separator or comment (OpenRouter sends ": OPENROUTER PROCESSING")
    end
    local data = line:match("^data:%s?(.*)$")
    if data then
      on_data(data)
    elseif not line:match("^%a+:") and on_other then
      on_other(line)
    end
  end

  function self.feed(chunk)
    buf = buf .. chunk
    while true do
      local nl = buf:find("\n", 1, true)
      if not nl then
        break
      end
      handle(buf:sub(1, nl - 1))
      buf = buf:sub(nl + 1)
    end
  end

  function self.flush()
    if buf ~= "" then
      handle(buf)
      buf = ""
    end
  end

  return self
end

return M
