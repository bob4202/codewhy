-- The chat panel: a persistent buffer showing the current session, with a
-- message box (the composer) docked underneath, displayed as a side split
-- (default) or a centered float and toggled without losing anything. Answers
-- stream in turn by turn; the composer stays open so you can keep chatting.
-- Pure view: what keys do is decided by the caller through `actions`.
local render = require("codewhy.render")

local M = {}

local ns = vim.api.nvim_create_namespace("codewhy") -- status line, turn headers, help
local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local INPUT_HEIGHT = 3
local PLACEHOLDER = "Ask anything… ⏎ send · <C-j> new line"

local HELP = {
  { "codewhy", "Title" },
  { "" },
  { "Select code, then", "Comment" },
  { "  <leader>ce  explain", "Comment" },
  { "  <leader>cd  explain diagnostics", "Comment" },
  { "  <leader>ca  ask a question", "Comment" },
  { "" },
  { "  or type below to chat", "Comment" },
  { "" },
  { "In this panel", "Comment" },
  { "  i      type a message", "Comment" },
  { "  n      new chat      H  history", "Comment" },
  { "  D      delete chat   y  yank answer", "Comment" },
  { "  p      show prompt   q  hide", "Comment" },
  { "  <C-c>  stop the answer", "Comment" },
}

local state = {
  opts = nil, ---@type table config.ui
  actions = {}, ---@type table<string, fun()>
  buf = nil, ---@type integer|nil chat
  win = nil, ---@type integer|nil chat
  input_buf = nil, ---@type integer|nil composer
  input_win = nil, ---@type integer|nil composer
  attachment = nil, ---@type string|nil label of code attached to the next message
  title = "codewhy",
  turn = nil, ---@type codewhy.ui.Turn|nil the turn being streamed
  render_pending = false,
}

-- Buffer & window ---------------------------------------------------------------

local function use_builtin_render()
  local r = state.opts.render
  if r == "builtin" then
    return true
  end
  return r == "auto" and not (package.loaded["render-markdown"] or package.loaded["markview"])
end

local function modify(fn)
  vim.bo[state.buf].modifiable = true
  local ok, err = pcall(fn)
  vim.bo[state.buf].modifiable = false
  if not ok then
    error(err, 0)
  end
end

local function is_empty()
  return vim.api.nvim_buf_line_count(state.buf) == 1 and vim.api.nvim_buf_get_lines(state.buf, 0, 1, false)[1] == ""
end

local function show_help()
  if not is_empty() then
    return
  end
  vim.api.nvim_buf_set_extmark(state.buf, ns, 0, 0, {
    virt_lines = vim.tbl_map(function(l)
      return { { l[1], l[2] or "Normal" } }
    end, vim.list_slice(HELP, 2)),
    virt_text = { { HELP[1][1], HELP[1][2] } },
    virt_text_pos = "overlay",
  })
end

local function schedule_render()
  if state.render_pending or not use_builtin_render() then
    return
  end
  state.render_pending = true
  vim.defer_fn(function()
    state.render_pending = false
    if state.buf and vim.api.nvim_buf_is_valid(state.buf) and use_builtin_render() then
      render.render(state.buf)
    end
  end, 40)
end

local function map(buf, lhs, action, desc)
  vim.keymap.set("n", lhs, function()
    local fn = state.actions[action]
    if fn then
      fn()
    end
  end, { buffer = buf, nowait = true, desc = "codewhy: " .. desc })
end

local function ensure_buf()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    return state.buf
  end
  local buf = vim.api.nvim_create_buf(false, true)
  state.buf = buf
  vim.bo[buf].bufhidden = "hide" -- survives the window closing
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, buf, "codewhy://chat")
  render.attach(buf)

  map(buf, "q", "hide", "hide the panel")
  map(buf, "<C-c>", "stop", "stop the answer")
  for _, lhs in ipairs({ "i", "a", "o", "<CR>" }) do
    vim.keymap.set("n", lhs, function()
      M.focus_input()
    end, { buffer = buf, nowait = true, desc = "codewhy: type a message" })
  end
  map(buf, "n", "new", "new chat")
  map(buf, "H", "history", "chat history")
  map(buf, "D", "delete", "delete this chat")
  map(buf, "y", "yank", "yank the last answer")
  map(buf, "p", "prompt", "show what was sent")
  show_help()
  return buf
end

-- Composer --------------------------------------------------------------------------

local input_ns = vim.api.nvim_create_namespace("codewhy_input")

local function input_text()
  return vim.trim(table.concat(vim.api.nvim_buf_get_lines(state.input_buf, 0, -1, false), "\n"))
end

local function update_placeholder()
  local buf = state.input_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, input_ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if #lines == 1 and lines[1] == "" then
    vim.api.nvim_buf_set_extmark(buf, input_ns, 0, 0, {
      virt_text = { { PLACEHOLDER, "Comment" } },
      virt_text_pos = "overlay",
    })
  end
end

--- Send what's in the composer. It's cleared only if the caller accepts it
--- (actions.send returns false when an answer is still streaming).
local function submit()
  local text = input_text()
  if text == "" then
    return
  end
  local send = state.actions.send
  if send and send(text) ~= false then
    vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, {})
    update_placeholder()
  end
end

local function ensure_input_buf()
  if state.input_buf and vim.api.nvim_buf_is_valid(state.input_buf) then
    return state.input_buf
  end
  local buf = vim.api.nvim_create_buf(false, true)
  state.input_buf = buf
  vim.bo[buf].bufhidden = "hide" -- a half-written message survives hiding the panel
  vim.bo[buf].filetype = "markdown"
  pcall(vim.api.nvim_buf_set_name, buf, "codewhy://input")

  local o = { buffer = buf, nowait = true }
  local function action(name)
    return function()
      local fn = state.actions[name]
      if fn then
        fn()
      end
    end
  end
  vim.keymap.set({ "i", "n" }, "<CR>", submit, vim.tbl_extend("force", o, { desc = "codewhy: send" }))
  vim.keymap.set({ "i", "n" }, "<C-c>", action("stop"), vim.tbl_extend("force", o, { desc = "codewhy: stop" }))
  vim.keymap.set(
    { "i", "n" },
    "<C-x>",
    action("detach"),
    vim.tbl_extend("force", o, { desc = "codewhy: remove attached code" })
  )
  vim.keymap.set("n", "q", action("hide"), vim.tbl_extend("force", o, { desc = "codewhy: hide the panel" }))
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufEnter" }, {
    buffer = buf,
    callback = update_placeholder,
  })
  update_placeholder()
  return buf
end

local function input_open()
  return state.input_win ~= nil and vim.api.nvim_win_is_valid(state.input_win)
end

-- What the composer shows above (split) or around (float) the text.
local function update_input_bar()
  if not input_open() then
    return
  end
  local label = state.attachment and (" @" .. state.attachment .. " ") or " Message "
  local hint = state.attachment and " <C-x> detach · ⏎ send " or " ⏎ send · <C-c> stop "
  if state.opts.layout == "float" then
    vim.api.nvim_win_set_config(state.input_win, {
      title = { { label, state.attachment and "CodewhyAttachment" or "FloatTitle" } },
      title_pos = "left",
      footer = hint,
      footer_pos = "right",
    })
  else
    local esc = function(t)
      return (t:gsub("%%", "%%%%"))
    end
    vim.wo[state.input_win].winbar = ("%%#%s#%s%%*%%=%%#Comment#%s%%*"):format(
      state.attachment and "CodewhyAttachment" or "Comment",
      esc(label),
      esc(hint)
    )
  end
end

--- Attach (label) or detach (nil) code to the next message, shown on the composer.
---@param label string|nil
function M.attach(label)
  state.attachment = label
  update_input_bar()
end

function M.is_open()
  return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

local function float_config()
  local o = state.opts
  local cols, rows = vim.o.columns, vim.o.lines - vim.o.cmdheight
  local width = math.max(1, math.min(cols - 4, math.max(40, math.floor(cols * o.width))))
  local height = math.max(1, math.min(rows - 4, math.max(8, math.floor(rows * o.height))))
  return {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((rows - height) / 2),
    col = math.floor((cols - width) / 2),
  }
end

local function panel_width()
  local w = state.opts.panel.width
  return math.max(30, w < 1 and math.floor(vim.o.columns * w) or w)
end

local function set_win_opts(win)
  local wo = vim.wo[win]
  wo.wrap = true
  wo.linebreak = true
  wo.breakindent = true
  wo.breakindentopt = "list:-1" -- wrapped list items line up under their text
  wo.conceallevel = 2
  wo.concealcursor = "nc" -- stay rendered under the cursor, like a reading view
  wo.number = false
  wo.relativenumber = false
  wo.cursorline = false
  wo.spell = false
  wo.list = false
  wo.foldcolumn = "0"
  wo.signcolumn = "yes:1" -- left padding
  wo.statuscolumn = ""
  wo.winhighlight = "SignColumn:Normal"
  wo.fillchars = "eob: " -- no ~ below the chat
  vim.api.nvim_set_option_value("showbreak", "NONE", { scope = "local", win = win }) -- breakindent is enough
end

-- Float layout: chat on top, composer below it, together the size of float_config().
local function float_layout()
  local cfg = float_config()
  local chat = vim.deepcopy(cfg)
  chat.height = math.max(1, cfg.height - INPUT_HEIGHT - 2)
  local input = {
    relative = "editor",
    width = cfg.width,
    height = INPUT_HEIGHT,
    row = cfg.row + chat.height + 2,
    col = cfg.col,
  }
  return chat, input
end

local function set_input_win_opts(win)
  local wo = vim.wo[win]
  wo.wrap = true
  wo.linebreak = true
  wo.number = false
  wo.relativenumber = false
  wo.cursorline = false
  wo.spell = false
  wo.list = false
  wo.foldcolumn = "0"
  wo.signcolumn = "yes:1"
  wo.statuscolumn = ""
  wo.winhighlight = "SignColumn:Normal"
  wo.fillchars = "eob: "
end

local function open_input()
  if input_open() then
    return
  end
  ensure_input_buf()
  local win
  if state.opts.layout == "float" then
    local _, cfg = float_layout()
    win = vim.api.nvim_open_win(
      state.input_buf,
      false,
      vim.tbl_extend("force", cfg, { style = "minimal", border = state.opts.border, zindex = 51 })
    )
  else
    win = vim.api.nvim_open_win(state.input_buf, false, { split = "below", win = state.win, height = INPUT_HEIGHT })
    vim.wo[win].winfixheight = true
  end
  state.input_win = win
  set_input_win_opts(win)
  update_input_bar()
  vim.api.nvim_create_autocmd("WinClosed", {
    group = vim.api.nvim_create_augroup("codewhy_input", { clear = true }),
    pattern = tostring(win),
    once = true,
    callback = function()
      state.input_win = nil
    end,
  })
end

local function update_title()
  if not M.is_open() then
    return
  end
  if state.opts.layout == "float" then
    vim.api.nvim_win_set_config(state.win, { title = " " .. state.title .. " ", title_pos = "center" })
  else
    vim.wo[state.win].winbar = "%#Title# " .. state.title:gsub("%%", "%%%%") .. "%*"
  end
end

--- Show the panel. Focus moves to it only if `enter` (floats always take focus).
function M.open(enter)
  ensure_buf()
  if M.is_open() then
    open_input() -- in case only the composer was closed
    if enter then
      vim.api.nvim_set_current_win(state.win)
    end
    return
  end
  local o = state.opts
  local win
  if o.layout == "float" then
    local chat = float_layout()
    win = vim.api.nvim_open_win(
      state.buf,
      true,
      vim.tbl_extend("force", chat, {
        style = "minimal",
        border = o.border,
        footer = " q hide · n new · H history ",
        footer_pos = "right",
      })
    )
  else
    win = vim.api.nvim_open_win(state.buf, enter or false, {
      split = o.panel.position == "left" and "left" or "right",
      win = -1, -- full height, at the edge of the editor
      width = panel_width(),
    })
    vim.wo[win].winfixwidth = true
  end
  state.win = win
  set_win_opts(win)
  if o.layout ~= "float" then
    -- a plain rule between the chat and the composer instead of the buffer name
    vim.wo[win].statusline = "%#WinSeparator#%="
    vim.wo[win].fillchars = "eob: ,stl:─,stlnc:─"
  end
  update_title()
  open_input()
  schedule_render()

  local group = vim.api.nvim_create_augroup("codewhy_panel", { clear = true })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = tostring(win),
    once = true,
    callback = function()
      state.win = nil
      -- the composer goes with the chat (e.g. after :q in the chat window)
      vim.schedule(function()
        if input_open() and not M.is_open() then
          pcall(vim.api.nvim_win_close, state.input_win, true)
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      if M.is_open() then
        if o.layout == "float" then
          local chat, input = float_layout()
          vim.api.nvim_win_set_config(state.win, chat)
          if input_open() then
            vim.api.nvim_win_set_config(state.input_win, input)
          end
        else
          vim.api.nvim_win_set_width(state.win, panel_width())
        end
        schedule_render() -- rules span the window width
      end
    end,
  })
end

--- Hide the panel. The chat (and any answer still streaming) is kept.
function M.hide()
  if vim.fn.mode() == "i" then
    vim.cmd.stopinsert()
  end
  if input_open() then
    pcall(vim.api.nvim_win_close, state.input_win, true)
  end
  state.input_win = nil
  if M.is_open() then
    -- the last window can't be closed; leave it be
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  state.win = nil
end

--- Open the panel if needed and put the cursor in the composer, in insert mode.
function M.focus_input()
  M.open(false)
  open_input()
  vim.api.nvim_set_current_win(state.input_win)
  vim.cmd.startinsert({ bang = true }) -- append, after any half-written text
end

function M.toggle()
  if M.is_open() then
    M.hide()
  else
    M.open(state.opts.layout == "float")
  end
end

--- Columns available for text in the panel (window width minus the padding
--- column), or nil when it isn't open.
function M.text_width()
  if not M.is_open() then
    return nil
  end
  local info = vim.fn.getwininfo(state.win)[1]
  return vim.api.nvim_win_get_width(state.win) - (info and info.textoff or 0)
end

function M.set_title(title)
  state.title = title
  update_title()
end

-- Status line (virtual, under the last line) --------------------------------------

local status_mark, timer

local function stop_spinner()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
end

local function draw_status(msg, hl)
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end
  if status_mark then
    pcall(vim.api.nvim_buf_del_extmark, state.buf, ns, status_mark)
    status_mark = nil
  end
  if msg then
    local last = vim.api.nvim_buf_line_count(state.buf) - 1
    status_mark = vim.api.nvim_buf_set_extmark(state.buf, ns, last, 0, {
      virt_lines = { { { msg, hl or "Comment" } } },
    })
  end
end

-- Writing -------------------------------------------------------------------------

local function follow_bottom(fn)
  local was_bottom = M.is_open()
    and vim.api.nvim_win_get_cursor(state.win)[1] >= vim.api.nvim_buf_line_count(state.buf) - 1
  fn()
  if was_bottom and M.is_open() then
    vim.api.nvim_win_set_cursor(state.win, { vim.api.nvim_buf_line_count(state.buf), 0 })
  end
end

-- Append text at the end of the buffer, continuing the last line.
local function append_text(text)
  follow_bottom(function()
    modify(function()
      local count = vim.api.nvim_buf_line_count(state.buf)
      local last = vim.api.nvim_buf_get_lines(state.buf, count - 1, count, false)[1] or ""
      vim.api.nvim_buf_set_lines(state.buf, count - 1, count, false, vim.split(last .. text, "\n", { plain = true }))
    end)
  end)
  schedule_render()
end

-- Start a new section: header line, optional question, then the answer below.
local function write_header(label, question)
  if is_empty() then
    vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1) -- help text
    status_mark = nil
  end
  local lines = { "❯ " .. label }
  if question and question ~= "" then
    for _, l in ipairs(vim.split(question, "\n", { plain = true })) do
      table.insert(lines, "  " .. l)
    end
  end
  table.insert(lines, "")
  table.insert(lines, "")
  local start
  follow_bottom(function()
    modify(function()
      if is_empty() then
        start = 0
        vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
      else
        start = vim.api.nvim_buf_line_count(state.buf) + 1
        table.insert(lines, 1, "")
        vim.api.nvim_buf_set_lines(state.buf, -1, -1, false, lines)
      end
    end)
  end)
  vim.api.nvim_buf_set_extmark(state.buf, ns, start, 0, {
    end_col = #lines[start == 0 and 1 or 2],
    hl_group = "CodewhyTurn",
    line_hl_group = "CodewhyTurnBg",
  })
  if question and question ~= "" then
    local n = #vim.split(question, "\n", { plain = true })
    vim.api.nvim_buf_set_extmark(state.buf, ns, start + 1, 0, {
      end_row = start + n + 1,
      end_col = 0,
      hl_group = "CodewhyQuestion",
    })
  end
end

-- Turns -----------------------------------------------------------------------------

---@class codewhy.ui.Turn
---@field chunks string[]
---@field started_at integer
---@field on_cancel fun()|nil
local Turn = {}
Turn.__index = Turn

--- Start streaming a new turn at the end of the chat.
---@return codewhy.ui.Turn
function M.begin_turn(label, question)
  ensure_buf()
  stop_spinner()
  draw_status(nil)
  write_header(label, question)
  local turn = setmetatable({ chunks = {}, started_at = vim.uv.hrtime() }, Turn)
  state.turn = turn
  return turn
end

-- Only the latest turn may draw, and only until it has finished.
function Turn:active()
  return state.turn == self and not self.done
end

function Turn:append(chunk)
  if chunk == "" or not self:active() then
    return
  end
  table.insert(self.chunks, chunk)
  append_text(chunk)
end

function Turn:text()
  return table.concat(self.chunks)
end

function Turn:elapsed()
  return (vim.uv.hrtime() - self.started_at) / 1e9
end

--- Animated status ("⠋ thinking…") until the next status()/error()/finish.
function Turn:loading(msg)
  if not self:active() then
    return
  end
  self.loading_msg = msg
  if timer then
    return
  end
  local frame = 0
  timer = vim.uv.new_timer()
  timer:start(
    0,
    80,
    vim.schedule_wrap(function()
      if not timer or not state.turn then
        return -- stopped while this tick was queued
      end
      frame = frame % #SPINNER + 1
      draw_status(SPINNER[frame] .. " " .. state.turn.loading_msg)
    end)
  )
end

--- Static status line; ends the turn's streaming state.
function Turn:status(msg, hl)
  if state.turn ~= self then
    return -- a finished turn may still set its final status ("stopped")
  end
  stop_spinner()
  draw_status(msg, hl)
end

function Turn:error(msg)
  if not self:active() then
    return
  end
  self:status(nil)
  append_text((#self.chunks == 0 and "" or "\n\n") .. "**Error:** " .. msg)
end

--- The streaming turn is over (done, failed or stopped).
function Turn:finish()
  if self:active() then
    stop_spinner()
  end
  self.on_cancel = nil
  self.done = true
end

--- Cancel whatever is streaming. Returns true if something was stopped.
function M.stop()
  local turn = state.turn
  if turn and turn.on_cancel then
    local cancel = turn.on_cancel
    turn.on_cancel = nil
    cancel()
    turn:status("stopped", "WarningMsg")
    return true
  end
  return false
end

-- Whole-chat operations -----------------------------------------------------------

--- Replace the panel's contents with these turns (a restored or new session).
---@param turns codewhy.Turn[]
function M.load(turns)
  ensure_buf()
  stop_spinner()
  state.turn = nil
  status_mark = nil
  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  render.clear(state.buf)
  modify(function()
    vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, {})
  end)
  for _, t in ipairs(turns) do
    write_header(t.label, t.question)
    local body = t.answer or ""
    if t.error then
      body = body .. (body == "" and "" or "\n\n") .. "**Error:** " .. t.error
    end
    if body ~= "" then
      append_text(body)
    end
  end
  show_help()
  if M.is_open() and #turns > 0 then
    vim.api.nvim_win_set_cursor(state.win, { vim.api.nvim_buf_line_count(state.buf), 0 })
  end
  schedule_render()
end

function M.yank(text)
  if not text or text == "" then
    return vim.notify("[codewhy] nothing to yank yet", vim.log.levels.WARN)
  end
  vim.fn.setreg('"', text)
  if vim.fn.has("clipboard") == 1 then
    pcall(vim.fn.setreg, "+", text)
  end
  vim.notify("[codewhy] answer yanked")
end

--- Show text (the prompt sent) in a read-only float over the editor.
function M.show_text(title, text)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
  vim.bo[buf].modifiable = false
  render.attach(buf)
  local cfg = float_config()
  local win = vim.api.nvim_open_win(
    buf,
    true,
    vim.tbl_extend("force", cfg, {
      style = "minimal",
      border = state.opts.border,
      zindex = 60,
      title = " " .. title .. " ",
      title_pos = "center",
      footer = " q close ",
      footer_pos = "right",
    })
  )
  set_win_opts(win)
  if use_builtin_render() then
    render.render(buf)
  end
  for _, lhs in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", lhs, function()
      pcall(vim.api.nvim_win_close, win, true)
    end, { buffer = buf, nowait = true, desc = "codewhy: close" })
  end
  return win
end

---@param opts table config.ui
---@param actions table<string, function> key handlers: send(text) -> false to keep the text, hide, stop,
--- detach, new, history, delete, yank, prompt
function M.setup(opts, actions)
  state.opts = opts
  state.actions = actions or {}
  vim.api.nvim_set_hl(0, "CodewhyTurn", { default = true, link = "Title" })
  vim.api.nvim_set_hl(0, "CodewhyTurnBg", { default = true, link = "CursorLine" })
  vim.api.nvim_set_hl(0, "CodewhyQuestion", { default = true, italic = true })
  vim.api.nvim_set_hl(0, "CodewhyAttachment", { default = true, link = "Special" })
end

-- For tests.
M._state = state

return M
