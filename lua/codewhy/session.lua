-- Chat sessions: the conversation sent to the model plus what the panel shows,
-- saved as JSON under stdpath("data")/codewhy/sessions. Sessions contain code
-- that was sent to the provider, so files are created owner-only (0600 in a
-- 0700 directory). They never contain the API key.
local M = {}

---@class codewhy.Turn
---@field label string e.g. "explain · lua/foo.lua:10-20", or "you" for a typed message
---@field question string|nil
---@field answer string
---@field error string|nil
---@field sent integer number of session messages sent for this turn (for `p`)
---@field width integer|nil panel text width the answer was formatted for

---@class codewhy.Session
---@field id string
---@field title string|nil
---@field created integer
---@field updated integer
---@field messages { role: "user"|"assistant", content: string }[] without the system prompt
---@field turns codewhy.Turn[]

local function dir()
  return vim.fn.stdpath("data") .. "/codewhy/sessions"
end

local function valid_id(id)
  return type(id) == "string" and id:match("^[%w%-]+$") ~= nil
end

local function path(id)
  assert(valid_id(id), "invalid session id")
  return dir() .. "/" .. id .. ".json"
end

---@return codewhy.Session
function M.new()
  local now = os.time()
  return {
    id = os.date("%Y%m%d-%H%M%S", now) .. ("-%04x"):format(vim.uv.hrtime() % 0x10000),
    created = now,
    updated = now,
    messages = {},
    turns = {},
  }
end

---@param s codewhy.Session
---@return boolean ok, string|nil err
function M.save(s)
  if #s.turns == 0 then
    return true -- nothing worth keeping
  end
  s.updated = os.time()
  vim.fn.mkdir(dir(), "p", tonumber("700", 8))
  local fd, err = vim.uv.fs_open(path(s.id), "w", tonumber("600", 8))
  if not fd then
    return false, err
  end
  vim.uv.fs_write(fd, vim.json.encode(s))
  vim.uv.fs_close(fd)
  return true
end

---@return codewhy.Session|nil
function M.load(id)
  if not valid_id(id) then
    return nil
  end
  local f = io.open(path(id), "r")
  if not f then
    return nil
  end
  local ok, s = pcall(vim.json.decode, f:read("*a"))
  f:close()
  if not ok or type(s) ~= "table" or type(s.messages) ~= "table" or type(s.turns) ~= "table" then
    return nil
  end
  s.id = id
  return s
end

--- Saved sessions, most recently updated first.
---@return codewhy.Session[]
function M.list()
  local out = {}
  for name, kind in vim.fs.dir(dir()) do
    local id = kind == "file" and name:match("^(.+)%.json$")
    local s = id and M.load(id)
    if s then
      table.insert(out, s)
    end
  end
  table.sort(out, function(a, b)
    if a.updated ~= b.updated then
      return a.updated > b.updated
    end
    return a.id > b.id
  end)
  return out
end

function M.delete(id)
  if valid_id(id) then
    os.remove(path(id))
  end
end

--- Keep only the newest `max` sessions on disk.
function M.prune(max)
  for i, s in ipairs(M.list()) do
    if i > max then
      M.delete(s.id)
    end
  end
end

--- The newest messages that fit in `max_chars`, dropping whole turns from the
--- start. The last message is always kept, even if it alone is over budget.
---@param messages { role: string, content: string }[]
---@param max_chars integer
function M.trim(messages, max_chars)
  local total, from = 0, #messages + 1
  for i = #messages, 1, -1 do
    total = total + #messages[i].content
    if total > max_chars and i < #messages then
      break
    end
    from = i
  end
  -- never start on an assistant reply
  while messages[from] and messages[from].role ~= "user" and from < #messages do
    from = from + 1
  end
  return vim.list_slice(messages, from)
end

--- "3m ago" style age.
function M.age(t, now)
  local d = (now or os.time()) - t
  if d < 60 then
    return "just now"
  elseif d < 3600 then
    return ("%dm ago"):format(d / 60)
  elseif d < 86400 then
    return ("%dh ago"):format(d / 3600)
  end
  return ("%dd ago"):format(d / 86400)
end

return M
