local ui = require("codewhy.ui")

local OPTS = { width = 0.6, height = 0.6, border = "rounded" }

local function lines(win)
  return vim.api.nvim_buf_get_lines(win.buf, 0, -1, false)
end

local function close_floats()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
end

describe("ui window", function()
  after_each(close_floats)

  it("opens a focused markdown float with a title", function()
    local win = ui.open(OPTS, "codewhy · explain")
    assert.is_true(win:valid())
    assert.are.equal(win.win, vim.api.nvim_get_current_win())
    assert.are.equal("markdown", vim.bo[win.buf].filetype)
    local cfg = vim.api.nvim_win_get_config(win.win)
    assert.are.equal("editor", cfg.relative)
    assert.truthy(vim.inspect(cfg.title):find("codewhy · explain", 1, true))
  end)

  it("streams chunks into lines, splitting on newlines", function()
    local win = ui.open(OPTS, "t")
    for _, c in ipairs({ "Hel", "lo\nwor", "ld", "\n\n- item" }) do
      win:append(c)
    end
    assert.are.same({ "Hello", "world", "", "- item" }, lines(win))
    assert.are.equal("Hello\nworld\n\n- item", win:text())
  end)

  it("follows the output while the cursor is at the bottom", function()
    local win = ui.open(OPTS, "t")
    win:append(("line\n"):rep(5) .. "last")
    assert.are.equal(6, vim.api.nvim_win_get_cursor(win.win)[1])
  end)

  it("appends errors after the answer", function()
    local win = ui.open(OPTS, "t")
    win:append("partial")
    win:error("boom")
    assert.are.same({ "partial", "", "**Error:** boom" }, lines(win))
  end)

  it("shows a spinner while loading and stops it on a static status", function()
    local win = ui.open(OPTS, "t")
    win:loading("thinking…")
    assert.is_not_nil(win.timer)
    vim.wait(200)
    local marks = vim.api.nvim_buf_get_extmarks(win.buf, -1, 0, -1, { details = true })
    assert.are.equal(1, #marks)
    assert.truthy(marks[1][4].virt_lines[1][1][1]:find("thinking…", 1, true))
    win:status("done")
    assert.is_nil(win.timer)
  end)

  it("cancels the request and frees the timer when closed", function()
    local win = ui.open(OPTS, "t")
    local cancelled = 0
    win.on_close = function()
      cancelled = cancelled + 1
    end
    win:loading("waiting")
    vim.api.nvim_win_close(win.win, true) -- like :q, not via the keymap
    assert.are.equal(1, cancelled)
    assert.is_nil(win.timer)
    assert.is_false(win:valid())
    win:close() -- idempotent
    assert.are.equal(1, cancelled)
  end)

  it("stop cancels but keeps the window open", function()
    local win = ui.open(OPTS, "t")
    local cancelled = false
    win.on_close = function()
      cancelled = true
    end
    win:stop()
    assert.is_true(cancelled)
    assert.is_true(win:valid())
    assert.is_nil(win.on_close)
  end)

  it("yanks the answer into the unnamed register", function()
    local win = ui.open(OPTS, "t")
    win:append("the answer\nline 2")
    win:yank()
    assert.are.equal("the answer\nline 2", vim.fn.getreg('"'))
  end)

  it("shows the prompt in a read-only float above the answer", function()
    local win = ui.open(OPTS, "t")
    win.prompt = "# system\n\nS\n\n# user\n\nU"
    win:show_prompt()
    local cur = vim.api.nvim_get_current_win()
    assert.are_not.equal(win.win, cur)
    local buf = vim.api.nvim_win_get_buf(cur)
    assert.are.same({ "# system", "", "S", "", "# user", "", "U" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.is_false(vim.bo[buf].modifiable)
    assert.is_true(vim.api.nvim_win_get_config(cur).zindex > vim.api.nvim_win_get_config(win.win).zindex)
  end)

  it("fits inside a tiny editor", function()
    local columns, lines_ = vim.o.columns, vim.o.lines
    vim.o.columns, vim.o.lines = 30, 12
    local win = ui.open(OPTS, "t")
    local cfg = vim.api.nvim_win_get_config(win.win)
    assert.is_true(cfg.width <= 30 and cfg.height <= 12)
    win:close()
    vim.o.columns, vim.o.lines = columns, lines_
  end)
end)
