local session = require("codewhy.session")

local DIR = vim.fn.stdpath("data") .. "/codewhy/sessions"

local function with_turn(s, answer)
  table.insert(s.messages, { role = "user", content = "q" })
  table.insert(s.messages, { role = "assistant", content = answer })
  table.insert(s.turns, { label = "explain", answer = answer, sent = #s.messages - 1 })
  return s
end

describe("session", function()
  before_each(function()
    vim.fn.delete(vim.fn.stdpath("data") .. "/codewhy", "rf")
  end)

  it("creates sessions with distinct, filename-safe ids", function()
    local a, b = session.new(), session.new()
    assert.are_not.equal(a.id, b.id)
    assert.truthy(a.id:match("^[%w%-]+$"))
  end)

  it("round-trips through disk", function()
    local s = with_turn(session.new(), "hello")
    s.title = "t"
    assert.is_true(session.save(s))
    local loaded = session.load(s.id)
    assert.are.equal("t", loaded.title)
    assert.are.same(s.messages, loaded.messages)
    assert.are.same(s.turns, loaded.turns)
  end)

  it("stores chats owner-only", function()
    local s = with_turn(session.new(), "hello")
    session.save(s)
    assert.are.equal(
      tonumber("600", 8),
      bit.band(vim.uv.fs_stat(DIR .. "/" .. s.id .. ".json").mode, tonumber("777", 8))
    )
    assert.are.equal(tonumber("700", 8), bit.band(vim.uv.fs_stat(DIR).mode, tonumber("777", 8)))
  end)

  it("does not save an empty chat", function()
    local s = session.new()
    session.save(s)
    assert.is_nil(vim.uv.fs_stat(DIR .. "/" .. s.id .. ".json"))
  end)

  it("lists the most recent first", function()
    local old = with_turn(session.new(), "old")
    session.save(old)
    local new = with_turn(session.new(), "new")
    session.save(new)
    -- same second: make the order unambiguous
    old.updated = old.updated - 100
    local f = assert(io.open(DIR .. "/" .. old.id .. ".json", "w"))
    f:write(vim.json.encode(old))
    f:close()
    local ids = vim.tbl_map(function(s)
      return s.id
    end, session.list())
    assert.are.same({ new.id, old.id }, ids)
  end)

  it("lists nothing when there is no history yet", function()
    assert.are.same({}, session.list())
  end)

  it("prunes the oldest beyond the limit", function()
    for i = 1, 3 do
      local s = with_turn(session.new(), tostring(i))
      s.id = "s" .. i
      session.save(s)
    end
    session.prune(2)
    assert.are.equal(2, #session.list())
  end)

  it("rejects ids that could escape the sessions directory", function()
    assert.is_nil(session.load("../../secrets"))
    assert.is_nil(session.load("a/b"))
    session.delete("../x") -- no error, no effect
  end)

  it("ignores corrupt files", function()
    vim.fn.mkdir(DIR, "p")
    vim.fn.writefile({ "{nope" }, DIR .. "/bad.json")
    assert.is_nil(session.load("bad"))
    assert.are.same({}, session.list())
  end)
end)

describe("session.trim", function()
  local function msgs(...)
    local out = {}
    for i, len in ipairs({ ... }) do
      table.insert(out, { role = i % 2 == 1 and "user" or "assistant", content = ("x"):rep(len) })
    end
    return out
  end

  it("keeps everything under the budget", function()
    assert.are.equal(4, #session.trim(msgs(10, 10, 10, 10), 100))
  end)

  it("drops the oldest turns first and starts on a user message", function()
    local m = msgs(50, 50, 10, 10, 10)
    local out = session.trim(m, 40)
    assert.are.equal(3, #out)
    assert.are.equal("user", out[1].role)
    assert.are.equal(m[3], out[1])
  end)

  it("always keeps the latest message", function()
    local out = session.trim(msgs(10, 10, 500), 40)
    assert.are.equal(1, #out)
    assert.are.equal(500, #out[1].content)
  end)
end)

describe("session.age", function()
  it("formats relative times", function()
    assert.are.equal("just now", session.age(100, 130))
    assert.are.equal("5m ago", session.age(0, 300))
    assert.are.equal("2h ago", session.age(0, 7200))
    assert.are.equal("3d ago", session.age(0, 3 * 86400))
  end)
end)
