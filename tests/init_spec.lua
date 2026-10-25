-- End to end: entry points -> context -> prompt -> provider -> panel -> saved
-- session, with a scriptable fake provider in place of the network.
local codewhy = require("codewhy")
local config = require("codewhy.config")
local secrets = require("codewhy.secrets")
local session = require("codewhy.session")
local ui = require("codewhy.ui")

local requests
local script -- what the fake provider does next: "answer" | "hang" | "error"
local answers

package.loaded["codewhy.providers.fake"] = {
  stream = function(req, h)
    table.insert(requests, req)
    local handle = { cancelled = false }
    handle.cancel = function()
      handle.cancelled = true
    end
    if script == "answer" then
      h.on_reasoning("…")
      for _, chunk in ipairs(answers) do
        h.on_chunk(chunk)
      end
      h.on_done()
    elseif script == "error" then
      h.on_error("rate limited")
    end
    requests[#requests].handle = handle
    return handle
  end,
  list_models = function(_, cb)
    cb({ { id = "fake/model", free = true } })
  end,
}

local function panel_lines()
  return vim.api.nvim_buf_get_lines(ui._state.buf, 0, -1, false)
end

local function wait_idle(n)
  assert.is_true(vim.wait(3000, function()
    return #requests >= n
      and (script ~= "answer" or panel_lines()[#panel_lines()] == table.concat(answers):match("[^\n]*$"))
  end))
  vim.wait(20)
end

-- id of the saved chat whose first answer is `answer`
local function current_id_of(answer)
  for _, s in ipairs(session.list()) do
    if s.turns[1] and s.turns[1].answer == answer then
      return s.id
    end
  end
end

local function setup_buffer()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "local function add(a, b)", "  return a + b", "end" })
  vim.bo[buf].filetype = "lua"
  vim.api.nvim_set_current_buf(buf)
end

describe("codewhy chat", function()
  before_each(function()
    requests, script, answers = {}, "answer", { "It adds ", "two numbers." }
    secrets.clear()
    vim.fn.delete(vim.fn.stdpath("data") .. "/codewhy", "rf")
    os.remove(vim.fn.stdpath("state") .. "/codewhy.json")
    ui.hide()
    vim.cmd("silent! only")
    codewhy._reset()
    codewhy.setup({
      provider = "fake",
      model = "fake/model",
      api_key_cmd = { "printf", "sk-fake" },
      keymaps = false,
      context = { lsp = false },
    })
    ui.load({})
    setup_buffer()
  end)

  it("explains a range into the side panel", function()
    local editor = vim.api.nvim_get_current_win()
    codewhy.explain({ line1 = 1, line2 = 3 })
    wait_idle(1)

    assert.is_true(ui.is_open())
    assert.are.equal(editor, vim.api.nvim_get_current_win(), "focus stays in the code")
    local lines = panel_lines()
    assert.truthy(lines[1]:find("^❯ explain · .*:1%-3$"))
    assert.are.equal("It adds two numbers.", lines[#lines])

    local req = requests[1]
    assert.are.equal("sk-fake", req.api_key)
    assert.are.equal("system", req.messages[1].role)
    assert.truthy(req.messages[2].content:find("2    return a + b", 1, true))
  end)

  it("formats the answer for the panel's width", function()
    codewhy.explain({ line1 = 1, line2 = 3 })
    wait_idle(1)
    local width = ui.text_width()
    assert.is_true(width > 0 and width < vim.api.nvim_win_get_width(ui._state.win), "padding is excluded")
    local system = requests[1].messages[1].content
    assert.truthy(system:find(width .. " columns wide", 1, true))
    assert.truthy(system:find("Never use tables", 1, true))
  end)

  it("sends earlier turns with a follow-up", function()
    codewhy.explain({ line1 = 1, line2 = 3 })
    wait_idle(1)
    answers = { "Yes." }
    codewhy.followup("does it handle nil?")
    wait_idle(2)

    local m = requests[2].messages
    assert.are.same(
      { "system", "user", "assistant", "user" },
      vim.tbl_map(function(x)
        return x.role
      end, m)
    )
    assert.are.equal("It adds two numbers.", m[3].content)
    assert.are.equal("does it handle nil?", m[4].content)
    assert.are.equal("Yes.", panel_lines()[#panel_lines()])
  end)

  it("saves the chat and resumes it after a restart", function()
    codewhy.explain({ line1 = 1, line2 = 3 })
    wait_idle(1)
    local saved = session.list()
    assert.are.equal(1, #saved)
    assert.are.equal(1, #saved[1].turns)
    assert.are.equal(2, #saved[1].messages)

    -- like a fresh Neovim: no current chat, panel closed and empty
    codewhy._reset()
    ui.hide()
    ui.load({})
    codewhy.toggle()
    assert.is_true(ui.is_open())
    assert.are.equal("It adds two numbers.", panel_lines()[#panel_lines()])

    answers = { "Sure." }
    codewhy.followup("again?")
    wait_idle(2)
    -- the resumed history went along with the new question
    assert.are.same(
      { "system", "user", "assistant", "user" },
      vim.tbl_map(function(x)
        return x.role
      end, requests[2].messages)
    )
  end)

  it("starts a new chat and keeps the old one in history", function()
    codewhy.explain({ line1 = 1, line2 = 3 })
    wait_idle(1)
    codewhy.new_chat()
    assert.are.same({ "" }, panel_lines())
    answers = { "Fresh." }
    codewhy.followup("hello")
    wait_idle(2)
    assert.are.equal(2, #requests[2].messages, "no history from the previous chat")
    assert.are.equal(2, #session.list())
  end)

  it("reopens a chat from history", function()
    codewhy.explain({ line1 = 1, line2 = 3 })
    wait_idle(1)
    codewhy.new_chat()
    local select = vim.ui.select
    vim.ui.select = function(items, _, cb)
      cb(items[1])
    end
    codewhy.history()
    vim.ui.select = select
    assert.are.equal("It adds two numbers.", panel_lines()[#panel_lines()])
  end)

  it("stops a hanging answer and drops the unanswered question", function()
    script = "hang"
    codewhy.explain({ line1 = 1, line2 = 3 })
    assert.is_true(vim.wait(2000, function()
      return #requests == 1
    end))
    codewhy.stop()
    assert.is_true(requests[1].handle.cancelled)

    -- not busy any more, and the history has no dangling user message
    script = "answer"
    answers = { "ok" }
    codewhy.followup("next")
    wait_idle(2)
    assert.are.same(
      { "system", "user" },
      vim.tbl_map(function(x)
        return x.role
      end, requests[2].messages)
    )
  end)

  it("refuses a second request while one is streaming", function()
    script = "hang"
    codewhy.explain({ line1 = 1, line2 = 3 })
    assert.is_true(vim.wait(2000, function()
      return #requests == 1
    end))
    local notify, warned = vim.notify, nil
    vim.notify = function(msg)
      warned = msg
    end
    codewhy.followup("too soon")
    vim.notify = notify
    assert.truthy(warned:find("still answering", 1, true))
    assert.are.equal(1, #requests)
    codewhy.stop()
  end)

  it("shows provider errors in the chat and forgets the failed question", function()
    script = "error"
    codewhy.explain({ line1 = 1, line2 = 3 })
    assert.is_true(vim.wait(2000, function()
      return panel_lines()[#panel_lines()] == "**Error:** rate limited"
    end))
    script = "answer"
    answers = { "ok" }
    codewhy.followup("retry")
    wait_idle(2)
    assert.are.equal(2, #requests[2].messages)
  end)

  it("shows the exact prompt for the last turn", function()
    codewhy.explain({ line1 = 1, line2 = 3 })
    wait_idle(1)
    codewhy.show_prompt()
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    assert.truthy(text:find("# system", 1, true))
    assert.truthy(text:find("columns wide", 1, true), "shows the width rules that were sent")
    assert.truthy(text:find("return a + b", 1, true))
    vim.api.nvim_win_close(0, true)
  end)

  it("yanks the last answer", function()
    codewhy.explain({ line1 = 1, line2 = 3 })
    wait_idle(1)
    codewhy.yank()
    assert.are.equal("It adds two numbers.", vim.fn.getreg('"'))
  end)

  it("does not touch disk when history is disabled", function()
    codewhy.setup({
      provider = "fake",
      model = "fake/model",
      api_key_cmd = { "printf", "sk-fake" },
      keymaps = false,
      context = { lsp = false },
      history = { enabled = false },
    })
    codewhy.explain({ line1 = 1, line2 = 3 })
    wait_idle(1)
    assert.are.same({}, session.list())
  end)

  it("chats continuously from the composer", function()
    local function send(text)
      vim.api.nvim_buf_set_lines(ui._state.input_buf, 0, -1, false, { text })
      vim.api.nvim_buf_call(ui._state.input_buf, function()
        vim.fn.maparg("<CR>", "n", false, true).callback()
      end)
    end
    codewhy.followup()
    answers = { "one" }
    send("first")
    wait_idle(1)
    answers = { "two" }
    send("second")
    wait_idle(2)
    assert.are.same(
      { "system", "user", "assistant", "user" },
      vim.tbl_map(function(x)
        return x.role
      end, requests[2].messages)
    )
    assert.are.equal("two", panel_lines()[#panel_lines()])
  end)

  it("attaches selected code to the next composer message", function()
    codewhy.ask({ line1 = 2, line2 = 2 })
    assert.truthy(vim.wo[ui._state.input_win].winbar:find(":2-2", 1, true))
    vim.api.nvim_buf_set_lines(ui._state.input_buf, 0, -1, false, { "why return?" })
    vim.api.nvim_buf_call(ui._state.input_buf, function()
      vim.fn.maparg("<CR>", "n", false, true).callback()
    end)
    wait_idle(1)
    local user = requests[1].messages[2].content
    assert.truthy(user:find("## Question\nwhy return?", 1, true))
    assert.truthy(user:find("2    return a + b", 1, true), "the attached code was sent")
    assert.is_nil(vim.wo[ui._state.input_win].winbar:find(":2-2", 1, true), "attachment is used once")
  end)

  describe("deleting", function()
    local confirm
    before_each(function()
      confirm = vim.fn.confirm
    end)
    after_each(function()
      vim.fn.confirm = confirm
    end)
    local function answer(choice)
      vim.fn.confirm = function()
        return choice
      end
    end

    it("deletes the open chat after confirming", function()
      codewhy.explain({ line1 = 1, line2 = 3 })
      wait_idle(1)
      answer(2) -- cancel
      codewhy.delete_chat()
      assert.are.equal(1, #session.list())
      answer(1)
      codewhy.delete_chat()
      assert.are.same({}, session.list())
      assert.are.same({ "" }, panel_lines(), "the panel starts fresh")
    end)

    it("deletes a chat picked from history", function()
      codewhy.explain({ line1 = 1, line2 = 3 })
      wait_idle(1)
      codewhy.new_chat()
      answers = { "other" }
      codewhy.followup("other chat")
      wait_idle(2)
      local first = current_id_of("It adds two numbers.")
      local select = vim.ui.select
      vim.ui.select = function(items, _, cb)
        for _, s in ipairs(items) do
          if s.id == first then
            return cb(s)
          end
        end
      end
      answer(1)
      codewhy.history("delete")
      vim.ui.select = select
      local left = session.list()
      assert.are.equal(1, #left)
      assert.are_not.equal(first, left[1].id)
      assert.are.equal("other", panel_lines()[#panel_lines()], "the open chat is untouched")
    end)

    it("clears all history", function()
      codewhy.explain({ line1 = 1, line2 = 3 })
      wait_idle(1)
      codewhy.new_chat()
      codewhy.followup("again")
      wait_idle(2)
      answer(1)
      codewhy.history("clear")
      assert.are.same({}, session.list())
      assert.are.same({ "" }, panel_lines())
    end)

    it("refuses while an answer is streaming", function()
      script = "hang"
      codewhy.explain({ line1 = 1, line2 = 3 })
      assert.is_true(vim.wait(2000, function()
        return #requests == 1
      end))
      local called = false
      vim.fn.confirm = function()
        called = true
        return 1
      end
      codewhy.history("clear")
      assert.is_false(called)
      codewhy.stop()
    end)
  end)

  it("prefers the model picked with :CodeWhy model over setup()", function()
    config.save_state({ model = "picked/model" })
    assert.are.equal("picked/model", codewhy.current_model())
  end)

  it("registers the configured keymaps", function()
    codewhy.setup({ keymaps = { explain = "<leader>zz", toggle = "<leader>zt", diagnostic = false } })
    assert.are.equal("codewhy: explain code", vim.fn.maparg("<leader>zz", "x", false, true).desc)
    assert.are.equal("codewhy: toggle chat panel", vim.fn.maparg("<leader>zt", "n", false, true).desc)
    assert.are.equal("", vim.fn.maparg("<leader>cd", "n"))
  end)
end)
