local prompt = require("codewhy.prompt")

local function ctx(overrides)
  return vim.tbl_extend("force", {
    selection = {
      filetype = "lua",
      start_row = 10,
      end_row = 11,
      lines = { "local x = add(1, 2)", "return x" },
    },
    rel_path = "lua/foo.lua",
    diagnostics = {},
    surrounding = {},
    definitions = {},
    references = {},
  }, overrides or {})
end

local function user_content(messages)
  return messages[2].content
end

describe("prompt.build", function()
  it("returns a system and a user message", function()
    local m = prompt.build("explain", ctx())
    assert.are.equal(2, #m)
    assert.are.equal("system", m[1].role)
    assert.are.equal("user", m[2].role)
  end)

  it("includes the task, path and numbered selection", function()
    local c = user_content(prompt.build("explain", ctx()))
    assert.truthy(c:find("## Task", 1, true))
    assert.truthy(c:find("lua/foo.lua, lines 10-11", 1, true))
    assert.truthy(c:find("```lua\n10  local x = add(1, 2)\n11  return x\n```", 1, true))
  end)

  it("puts the user's question first for ask", function()
    local c = user_content(prompt.build("ask", ctx(), "why add?"))
    assert.are.equal(1, c:find("## Question\nwhy add?", 1, true))
  end)

  it("lists diagnostics with source and code", function()
    local c = user_content(prompt.build(
      "diagnostic",
      ctx({
        diagnostics = {
          {
            severity = "ERROR",
            line = 10,
            col = 11,
            message = "undefined global add",
            source = "lua_ls",
            code = "undefined-global",
          },
        },
      })
    ))
    assert.truthy(c:find("- ERROR at line 10, col 11 [lua_ls undefined-global]: undefined global add", 1, true))
  end)

  it("says so when asked about diagnostics but there are none", function()
    local c = user_content(prompt.build("diagnostic", ctx()))
    assert.truthy(c:find("No diagnostics were reported", 1, true))
  end)

  it("includes surrounding code, definitions and references", function()
    local c = user_content(prompt.build(
      "explain",
      ctx({
        surrounding = { before = { start_row = 9, lines = { "-- adds" } } },
        definitions = { { symbol = "add", path = "lua/math.lua", start_row = 3, lines = { "function add(a, b)" } } },
        references = { { symbol = "add", path = "lua/bar.lua", start_row = 20, lines = { "add(3, 4)" } } },
      })
    ))
    assert.truthy(c:find("Before the selection:\n```lua\n9  -- adds", 1, true))
    assert.truthy(c:find("`add` — lua/math.lua:3", 1, true))
    assert.truthy(c:find("## Where `add` is used elsewhere", 1, true))
    assert.truthy(c:find("lua/bar.lua:20", 1, true))
  end)

  it("pads line numbers to the same width", function()
    local c = user_content(
      prompt.build(
        "explain",
        ctx({ selection = { filetype = "lua", start_row = 9, end_row = 10, lines = { "a", "b" } } })
      )
    )
    assert.truthy(c:find(" 9  a\n10  b", 1, true))
  end)
end)

describe("prompt.render", function()
  it("joins messages under role headings", function()
    local out = prompt.render({ { role = "system", content = "S" }, { role = "user", content = "U" } })
    assert.are.equal("# system\n\nS\n\n# user\n\nU", out)
  end)
end)
