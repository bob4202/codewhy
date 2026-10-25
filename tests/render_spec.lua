local render = require("codewhy.render")

local DOC = {
  "# Title", -- 0
  "Some **bold** and `code`.", -- 1
  "", -- 2
  "## Sub", -- 3
  "- item", -- 4
  "  - nested", -- 5
  "- [ ] todo", -- 6
  "- [x] done", -- 7
  "", -- 8
  "> quoted", -- 9
  "> more", -- 10
  "", -- 11
  "```lua", -- 12
  "local x = 1", -- 13
  "```", -- 14
  "", -- 15
  "| a | b |", -- 16
  "|---|:-:|", -- 17
  "| 1 | 2 |", -- 18
  "", -- 19
  "---", -- 20
}

local function rendered(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  render.render(buf, 40)
  return buf
end

-- All extmarks on a row, with details.
local function marks(buf, row)
  return vim.tbl_map(function(m)
    return m[4]
  end, vim.api.nvim_buf_get_extmarks(buf, render.ns, { row, 0 }, { row, -1 }, { details = true }))
end

local function find(buf, row, pred)
  for _, d in ipairs(marks(buf, row)) do
    if pred(d) then
      return d
    end
  end
end

local function virt(d)
  return d.virt_text and table.concat(vim.tbl_map(function(c)
    return c[1]
  end, d.virt_text)) or nil
end

local function with_virt(text)
  return function(d)
    return virt(d) == text
  end
end

describe("render", function()
  if not render.available() then
    pending("markdown treesitter parsers are not available")
    return
  end

  local buf
  before_each(function()
    buf = rendered(DOC)
  end)

  it("hides heading markers and shades the heading line", function()
    local hide = find(buf, 0, function(d)
      return d.conceal == ""
    end)
    assert.is_not_nil(hide)
    assert.are.equal(2, hide.end_col) -- "# "
    assert.are.equal("◆ ", virt(hide))
    assert.is_not_nil(find(buf, 0, function(d)
      return d.line_hl_group == "CodewhyH1Bg"
    end))
    assert.is_not_nil(find(buf, 3, function(d)
      return d.line_hl_group == "CodewhyH2Bg"
    end))
  end)

  it("draws bullets by nesting depth", function()
    assert.is_not_nil(find(buf, 4, with_virt("•")))
    assert.is_not_nil(find(buf, 5, with_virt("◦")))
  end)

  it("replaces task markers with checkboxes in place of the bullet", function()
    assert.is_not_nil(find(buf, 6, with_virt("☐")))
    local bullet = find(buf, 6, function(d)
      return d.conceal == "" and d.end_col == 2
    end)
    assert.is_not_nil(bullet, "the '- ' should be hidden")
    assert.is_not_nil(find(buf, 7, with_virt("☑")))
  end)

  it("draws a bar for each quoted line", function()
    assert.is_not_nil(find(buf, 9, with_virt("▎")))
    assert.is_not_nil(find(buf, 10, with_virt("▎")))
  end)

  it("shades code blocks, labels the language and hides the fences", function()
    for row = 12, 14 do
      assert.is_not_nil(
        find(buf, row, function(d)
          return d.line_hl_group == "CodewhyCode"
        end),
        "row " .. row
      )
    end
    local label = find(buf, 13, function(d)
      return d.virt_text_pos == "right_align"
    end)
    assert.truthy(virt(label):find("lua", 1, true))
    assert.is_not_nil(find(buf, 14, function(d)
      return d.conceal == ""
    end))
    assert.are.same({}, marks(buf, 15), "shading must stop at the closing fence")
  end)

  it("draws tables with box characters", function()
    assert.are.equal(3, #vim.tbl_filter(with_virt("│"), marks(buf, 16)))
    assert.is_not_nil(find(buf, 17, with_virt("├───┼───┤")))
  end)

  it("re-aligns ragged tables", function()
    local b = rendered({ "| Step | Module |", "|---|:-:|", "| context | `context.lua` |", "| send | x |" })
    -- column widths: " context " = 9, " context.lua " = 13 (backticks are concealed)
    assert.is_not_nil(
      find(b, 1, with_virt("├─────────┼─────────────┤"))
    )
    local function padding(row)
      return vim.tbl_map(
        virt,
        vim.tbl_filter(function(d)
          return d.virt_text_pos == "inline"
        end, marks(b, row))
      )
    end
    -- padding before each closing pipe = column width - cell width
    assert.are.same({ "│", "   │", "     │" }, padding(0)) -- " Step " 6/9, " Module " 8/13
    assert.are.same({ "│", "│", "│" }, padding(2))
    assert.are.same({ "│", "   │", "          │" }, padding(3)) -- " send " 6/9, " x " 3/13
  end)

  it("draws a full-width rule", function()
    assert.is_not_nil(find(buf, 20, with_virt(("─"):rep(40))))
  end)

  it("gives inline code a background", function()
    assert.is_not_nil(find(buf, 1, function(d)
      return d.hl_group == "CodewhyInlineCode"
    end))
  end)

  it("never changes the buffer text", function()
    assert.are.same(DOC, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end)

  it("redraws idempotently", function()
    local before = #vim.api.nvim_buf_get_extmarks(buf, render.ns, 0, -1, {})
    render.render(buf, 40)
    assert.are.equal(before, #vim.api.nvim_buf_get_extmarks(buf, render.ns, 0, -1, {}))
  end)

  it("copes with an unterminated code block mid-stream", function()
    local b = rendered({ "Here:", "```python", "def f():" })
    assert.is_not_nil(find(b, 2, function(d)
      return d.line_hl_group == "CodewhyCode"
    end))
  end)

  it("defines highlight groups that follow the colorscheme", function()
    assert.is_true(vim.fn.hlexists("CodewhyH1Bg") == 1)
    assert.is_true(vim.fn.hlexists("CodewhyCode") == 1)
  end)
end)

describe("render blend", function()
  it("mixes colors", function()
    assert.are.equal(0xffffff, render._blend(0xffffff, 0x000000, 1))
    assert.are.equal(0x000000, render._blend(0xffffff, 0x000000, 0))
    assert.are.equal(0x808080, render._blend(0xffffff, 0x000000, 0.5))
    assert.are.equal(0x1a0000, render._blend(0xff0000, 0x000000, 0.1))
  end)
end)

describe("ui + render", function()
  local ui = require("codewhy.ui")
  after_each(function()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(w).relative ~= "" then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
  end)

  it("renders streamed markdown in the answer window", function()
    local win = ui.open({ width = 0.6, height = 0.6, border = "rounded", render = "builtin" }, "t")
    win:append("# Hel")
    win:append("lo\n- a")
    assert.is_true(vim.wait(500, function()
      return #vim.api.nvim_buf_get_extmarks(win.buf, render.ns, 0, -1, {}) > 0
    end))
    assert.are.equal("nc", vim.wo[win.win].concealcursor)
  end)

  it("does not render when disabled", function()
    local win = ui.open({ width = 0.6, height = 0.6, border = "rounded", render = false }, "t")
    win:append("# Hello")
    vim.wait(100)
    assert.are.same({}, vim.api.nvim_buf_get_extmarks(win.buf, render.ns, 0, -1, {}))
  end)

  it("auto defers to render-markdown.nvim when it is loaded", function()
    package.loaded["render-markdown"] = {}
    local win = ui.open({ width = 0.6, height = 0.6, border = "rounded", render = "auto" }, "t")
    package.loaded["render-markdown"] = nil
    assert.is_false(win.render)
  end)
end)
