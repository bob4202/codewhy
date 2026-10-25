local ui = require("codewhy.ui")
local config = require("codewhy.config")

local function opts(overrides)
  return vim.tbl_deep_extend("force", vim.deepcopy(config.defaults.ui), overrides or {})
end

local function lines()
  return vim.api.nvim_buf_get_lines(ui._state.buf, 0, -1, false)
end

local function reset(o, actions)
  ui.hide()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
  vim.cmd("silent! only")
  ui.setup(o or opts(), actions)
  ui.load({})
end

describe("panel", function()
  before_each(function()
    reset()
  end)

  it("opens as a fixed-width split on the right without taking focus", function()
    local editor = vim.api.nvim_get_current_win()
    ui.open()
    local win = ui._state.win
    assert.is_true(ui.is_open())
    assert.are.equal(editor, vim.api.nvim_get_current_win())
    assert.are.equal("", vim.api.nvim_win_get_config(win).relative)
    assert.is_true(vim.wo[win].winfixwidth)
    assert.are.equal(math.max(30, math.floor(vim.o.columns * 0.35)), vim.api.nvim_win_get_width(win))
    -- to the right of the editor window
    assert.is_true(vim.api.nvim_win_get_position(win)[2] > vim.api.nvim_win_get_position(editor)[2])
    assert.truthy(vim.api.nvim_buf_get_name(ui._state.buf):find("codewhy://chat", 1, true))
  end)

  it("opens on the left when configured", function()
    reset(opts({ panel = { position = "left" } }))
    local editor = vim.api.nvim_get_current_win()
    ui.open()
    assert.is_true(vim.api.nvim_win_get_position(ui._state.win)[2] < vim.api.nvim_win_get_position(editor)[2])
  end)

  it("opens as a float with the float layout", function()
    reset(opts({ layout = "float" }))
    ui.open(true)
    assert.are.equal("editor", vim.api.nvim_win_get_config(ui._state.win).relative)
  end)

  it("toggles without losing the chat", function()
    ui.open()
    ui.begin_turn("explain · a.lua:1-2"):append("kept")
    ui.toggle()
    assert.is_false(ui.is_open())
    assert.is_true(vim.api.nvim_buf_is_valid(ui._state.buf))
    ui.toggle()
    assert.is_true(ui.is_open())
    assert.are.equal("kept", lines()[#lines()])
  end)

  it("shows help while empty", function()
    ui.open()
    local marks = vim.api.nvim_buf_get_extmarks(ui._state.buf, -1, 0, -1, { details = true })
    assert.is_true(#marks > 0)
    assert.is_not_nil(marks[1][4].virt_lines)
  end)

  it("is read-only for the user", function()
    ui.open()
    assert.is_false(vim.bo[ui._state.buf].modifiable)
  end)

  it("writes turns with a header, question and streamed answer", function()
    ui.open()
    local t = ui.begin_turn("ask · a.lua:3-4", "why?\nreally")
    for _, c in ipairs({ "Bec", "ause\n\n- a" }) do
      t:append(c)
    end
    assert.are.same({ "❯ ask · a.lua:3-4", "  why?", "  really", "", "Because", "", "- a" }, lines())
    assert.are.equal("Because\n\n- a", t:text())

    t:finish()
    ui.begin_turn("follow-up", "more"):append("ok")
    assert.are.same({ "", "❯ follow-up", "  more", "", "ok" }, vim.list_slice(lines(), 8))
  end)

  it("keeps streaming into the chat while hidden", function()
    local t = ui.begin_turn("explain · a.lua:1-1")
    ui.hide()
    t:append("still here")
    assert.are.equal("still here", lines()[#lines()])
  end)

  it("shows a spinner while loading and stops it when the turn finishes", function()
    ui.open()
    local t = ui.begin_turn("x")
    t:loading("thinking…")
    vim.wait(200)
    local found = false
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(ui._state.buf, -1, 0, -1, { details = true })) do
      local vl = m[4].virt_lines
      found = found or (vl and vl[1][1][1]:find("thinking…", 1, true) ~= nil)
    end
    assert.is_true(found)
    t:finish()
    t:loading("again") -- ignored once finished
    t:append("late") -- ignored too
    assert.are_not.equal("late", lines()[#lines()])
  end)

  it("stop cancels the streaming turn", function()
    local t = ui.begin_turn("x")
    local cancelled = 0
    t.on_cancel = function()
      cancelled = cancelled + 1
    end
    assert.is_true(ui.stop())
    assert.is_false(ui.stop()) -- nothing left to stop
    assert.are.equal(1, cancelled)
  end)

  it("appends errors after a partial answer", function()
    local t = ui.begin_turn("x")
    t:append("partial")
    t:error("boom")
    assert.are.same({ "partial", "", "**Error:** boom" }, vim.list_slice(lines(), 3))
  end)

  it("restores a saved chat", function()
    ui.load({
      { label = "explain · a.lua:1-2", answer = "first" },
      { label = "follow-up", question = "and?", answer = "", error = "429" },
    })
    assert.are.same({
      "❯ explain · a.lua:1-2",
      "",
      "first",
      "",
      "❯ follow-up",
      "  and?",
      "",
      "**Error:** 429",
    }, lines())
  end)

  it("puts the title in the winbar", function()
    ui.open()
    ui.set_title("codewhy · m · 100% sure")
    assert.truthy(vim.wo[ui._state.win].winbar:find("100%% sure", 1, true))
  end)

  it("runs the configured actions from panel keymaps", function()
    local called = {}
    local actions = {}
    for _, name in ipairs({ "hide", "stop", "new", "history", "delete", "yank", "prompt" }) do
      actions[name] = function()
        table.insert(called, name)
      end
    end
    reset(opts(), actions)
    ui.open(true)
    for _, lhs in ipairs({ "q", "<C-C>", "n", "H", "D", "y", "p" }) do
      vim.fn.maparg(lhs, "n", false, true).callback()
    end
    assert.are.same({ "hide", "stop", "new", "history", "delete", "yank", "prompt" }, called)
  end)
end)

describe("composer", function()
  local sent, accept
  before_each(function()
    sent, accept = {}, true
    reset(opts(), {
      send = function(text)
        table.insert(sent, text)
        return accept
      end,
    })
  end)

  local function type_and_send(lines)
    vim.api.nvim_buf_set_lines(ui._state.input_buf, 0, -1, false, lines)
    vim.api.nvim_buf_call(ui._state.input_buf, function()
      vim.fn.maparg("<CR>", "n", false, true).callback()
    end)
  end

  it("is docked under the chat whenever the panel is open", function()
    ui.open()
    local input = ui._state.input_win
    assert.is_true(vim.api.nvim_win_is_valid(input))
    assert.is_true(vim.wo[input].winfixheight)
    local chat = vim.api.nvim_win_get_position(ui._state.win)
    local pos = vim.api.nvim_win_get_position(input)
    assert.is_true(pos[1] > chat[1], "below the chat")
    assert.are.equal(chat[2], pos[2], "same column as the chat")
  end)

  it("hides and comes back with the panel, keeping a half-written message", function()
    ui.focus_input()
    vim.api.nvim_buf_set_lines(ui._state.input_buf, 0, -1, false, { "half a thou" })
    ui.toggle()
    assert.is_nil(ui._state.input_win)
    ui.toggle()
    assert.is_true(vim.api.nvim_win_is_valid(ui._state.input_win))
    assert.are.same({ "half a thou" }, vim.api.nvim_buf_get_lines(ui._state.input_buf, 0, -1, false))
  end)

  it("stays open and clears after sending, for continuous chat", function()
    ui.focus_input()
    assert.are.equal(ui._state.input_win, vim.api.nvim_get_current_win())
    type_and_send({ "  first ", "message  " })
    assert.are.same({ "first \nmessage" }, sent)
    assert.are.same({ "" }, vim.api.nvim_buf_get_lines(ui._state.input_buf, 0, -1, false))
    assert.are.equal(ui._state.input_win, vim.api.nvim_get_current_win(), "still typing in the composer")
    type_and_send({ "second" })
    assert.are.same({ "first \nmessage", "second" }, sent)
  end)

  it("keeps the text when the message can't be sent yet", function()
    accept = false
    ui.focus_input()
    type_and_send({ "while busy" })
    assert.are.same({ "while busy" }, vim.api.nvim_buf_get_lines(ui._state.input_buf, 0, -1, false))
  end)

  it("ignores an empty message", function()
    ui.focus_input()
    type_and_send({ "   " })
    assert.are.same({}, sent)
  end)

  it("shows a placeholder only while empty", function()
    ui.open()
    vim.api.nvim_buf_set_lines(ui._state.input_buf, 0, -1, false, {})
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = ui._state.input_buf })
    local function marks()
      return #vim.api.nvim_buf_get_extmarks(ui._state.input_buf, -1, 0, -1, {})
    end
    assert.are.equal(1, marks())
    vim.api.nvim_buf_set_lines(ui._state.input_buf, 0, -1, false, { "x" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = ui._state.input_buf })
    assert.are.equal(0, marks())
    vim.api.nvim_buf_set_lines(ui._state.input_buf, 0, -1, false, {})
  end)

  it("shows attached code in its bar", function()
    ui.open()
    ui.attach("sse.lua:23-33")
    assert.truthy(vim.wo[ui._state.input_win].winbar:find("@sse.lua:23-33", 1, true))
    ui.attach(nil)
    assert.is_nil(vim.wo[ui._state.input_win].winbar:find("@sse", 1, true))
  end)

  it("i in the chat jumps to the composer", function()
    ui.open(true)
    vim.fn.maparg("i", "n", false, true).callback()
    assert.are.equal(ui._state.input_win, vim.api.nvim_get_current_win())
  end)

  it("closes with the chat window", function()
    ui.open()
    local input = ui._state.input_win
    vim.api.nvim_win_close(ui._state.win, true)
    vim.wait(100, function()
      return not vim.api.nvim_win_is_valid(input)
    end)
    assert.is_false(vim.api.nvim_win_is_valid(input))
  end)

  it("stacks under the chat in the float layout", function()
    reset(opts({ layout = "float" }), {})
    ui.open(true)
    local chat = vim.api.nvim_win_get_config(ui._state.win)
    local input = vim.api.nvim_win_get_config(ui._state.input_win)
    assert.are.equal("editor", input.relative)
    assert.are.equal(chat.col, input.col)
    assert.are.equal(chat.row + chat.height + 2, input.row)
  end)
end)

describe("ui helpers", function()
  before_each(function()
    reset()
  end)

  it("yanks into the unnamed register", function()
    ui.yank("the answer")
    assert.are.equal("the answer", vim.fn.getreg('"'))
  end)

  it("shows text in a read-only float", function()
    local win = ui.show_text("sent", "# system\n\nS")
    local buf = vim.api.nvim_win_get_buf(win)
    assert.are.same({ "# system", "", "S" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.is_false(vim.bo[buf].modifiable)
  end)
end)
