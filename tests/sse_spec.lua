local sse = require("codewhy.sse")

local function collect()
  local data, other = {}, {}
  local parser = sse.new(function(d)
    table.insert(data, d)
  end, function(l)
    table.insert(other, l)
  end)
  return parser, data, other
end

describe("sse", function()
  it("emits the payload of each data line", function()
    local p, data = collect()
    p.feed('data: {"a":1}\n\ndata: {"b":2}\n\n')
    assert.are.same({ '{"a":1}', '{"b":2}' }, data)
  end)

  it("reassembles lines split across chunks", function()
    local p, data = collect()
    p.feed("da")
    p.feed('ta: {"long":')
    p.feed('"value"}\n')
    assert.are.same({ '{"long":"value"}' }, data)
  end)

  it("ignores comments, blank lines and other fields", function()
    local p, data, other = collect()
    p.feed(": OPENROUTER PROCESSING\n\nevent: message\nid: 7\ndata: x\n")
    assert.are.same({ "x" }, data)
    assert.are.same({}, other)
  end)

  it("handles CRLF line endings", function()
    local p, data = collect()
    p.feed("data: one\r\ndata: two\r\n")
    assert.are.same({ "one", "two" }, data)
  end)

  it("accepts data lines without a space after the colon", function()
    local p, data = collect()
    p.feed("data:[DONE]\n")
    assert.are.same({ "[DONE]" }, data)
  end)

  it("passes non-SSE lines (e.g. a JSON error body) to on_other", function()
    local p, data, other = collect()
    p.feed('{"error":{"message":"nope"}}\n')
    assert.are.same({}, data)
    assert.are.same({ '{"error":{"message":"nope"}}' }, other)
  end)

  it("flush emits a trailing line with no newline", function()
    local p, data = collect()
    p.feed("data: tail")
    assert.are.same({}, data)
    p.flush()
    assert.are.same({ "tail" }, data)
    p.flush() -- nothing left, no duplicate
    assert.are.same({ "tail" }, data)
  end)
end)
