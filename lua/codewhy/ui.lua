-- Floating window that streams the answer in.
local render = require("codewhy.render")

local M = {}

local ns = vim.api.nvim_create_namespace("codewhy")
local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local FOOTER = " q close · y yank · p prompt · <C-c> stop "

---@class codewhy.Window
---@field buf integer
---@field win integer
---@field chunks string[] the answer as received
---@field prompt string|nil the exact text sent to the model, shown with `p`
---@field on_close fun()|nil called once when the window closes or the user stops the request
---@field started_at integer hrtime when the window opened
---@field timer uv.uv_timer_t|nil spinner timer while loading
---@field loading_msg string|nil
---@field render boolean draw markdown with codewhy.render
---@field render_pending boolean|nil

local Window = {}
Window.__index = Window

-- Centered float geometry, clamped so it always fits the editor.
local function layout(opts)
  local cols, rows = vim.o.columns, vim.o.lines - vim.o.cmdheight
  local width = math.max(1, math.min(cols - 4, math.max(40, math.floor(cols * opts.width))))
  local height = math.max(1, math.min(rows - 4, math.max(8, math.floor(rows * opts.height))))
  return {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((rows - height) / 2),
    col = math.floor((cols - width) / 2),
  }
end

local function scratch(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  if lines then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  end
  return buf
end

local function set_win_opts(win)
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].breakindent = true
  vim.wo[win].conceallevel = 2
  vim.wo[win].concealcursor = "nc" -- stay rendered under the cursor, like a reading view
  vim.wo[win].signcolumn = "yes:1" -- left padding
  vim.wo[win].winhighlight = "SignColumn:NormalFloat"
end

-- "auto" leaves rendering to render-markdown.nvim / markview.nvim when the user has one.
local function use_builtin_render(opts)
  if opts.render == "builtin" then
    return true
  end
  if opts.render ~= "auto" then
    return false
  end
  return not (package.loaded["render-markdown"] or package.loaded["markview"])
end

---@param opts table config.ui
---@param title string
---@return codewhy.Window
function M.open(opts, title)
  local buf = scratch()
  render.attach(buf)
  local win = vim.api.nvim_open_win(
    buf,
    true,
    vim.tbl_extend("force", layout(opts), {
      style = "minimal",
      border = opts.border,
      title = " " .. title .. " ",
      title_pos = "center",
      footer = FOOTER,
      footer_pos = "right",
    })
  )
  set_win_opts(win)

  local self = setmetatable({
    buf = buf,
    win = win,
    chunks = {},
    started_at = vim.uv.hrtime(),
    render = use_builtin_render(opts),
  }, Window)

  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = "codewhy: " .. desc })
  end
  map("q", function()
    self:close()
  end, "close")
  map("<Esc>", function()
    self:close()
  end, "close")
  map("<C-c>", function()
    self:stop()
  end, "stop the request")
  map("y", function()
    self:yank()
  end, "yank the answer")
  map("p", function()
    self:show_prompt()
  end, "show what was sent")

  local group = vim.api.nvim_create_augroup("codewhy_win_" .. win, { clear = true })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = tostring(win),
    once = true,
    callback = function()
      self:_teardown()
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      if self:valid() then
        vim.api.nvim_win_set_config(self.win, layout(opts))
        self:_schedule_render() -- rules span the window width
      end
    end,
  })

  return self
end

function Window:valid()
  return vim.api.nvim_buf_is_valid(self.buf) and vim.api.nvim_win_is_valid(self.win)
end

--- The answer received so far.
function Window:text()
  return table.concat(self.chunks)
end

--- Seconds since the window opened.
function Window:elapsed()
  return (vim.uv.hrtime() - self.started_at) / 1e9
end

-- Dim virtual line at the bottom of the buffer. nil clears it.
function Window:_render_status(msg, hl)
  if not self:valid() then
    return
  end
  vim.api.nvim_buf_clear_namespace(self.buf, ns, 0, -1)
  if msg then
    local last = vim.api.nvim_buf_line_count(self.buf) - 1
    vim.api.nvim_buf_set_extmark(self.buf, ns, last, 0, {
      virt_lines = { { { msg, hl or "Comment" } } },
    })
  end
end

function Window:_stop_spinner()
  if self.timer then
    self.timer:stop()
    self.timer:close()
    self.timer = nil
  end
end

--- Animated status ("⠋ thinking…") until the next status()/error()/close.
function Window:loading(msg)
  self.loading_msg = msg
  if self.timer or not self:valid() then
    return
  end
  local frame = 0
  self.timer = vim.uv.new_timer()
  self.timer:start(
    0,
    80,
    vim.schedule_wrap(function()
      if not self.timer then
        return -- stopped while this tick was queued
      end
      frame = frame % #SPINNER + 1
      self:_render_status(SPINNER[frame] .. " " .. self.loading_msg)
    end)
  )
end

--- Static status line. nil clears it.
function Window:status(msg, hl)
  self:_stop_spinner()
  self:_render_status(msg, hl)
end

function Window:append(chunk)
  if not self:valid() or chunk == "" then
    return
  end
  table.insert(self.chunks, chunk)
  -- only rewrite the last line, so long answers stay cheap to stream
  local count = vim.api.nvim_buf_line_count(self.buf)
  local follow = vim.api.nvim_win_get_cursor(self.win)[1] >= count - 1 -- unless the user scrolled up
  local last = vim.api.nvim_buf_get_lines(self.buf, count - 1, count, false)[1] or ""
  vim.api.nvim_buf_set_lines(self.buf, count - 1, count, false, vim.split(last .. chunk, "\n", { plain = true }))
  if follow then
    vim.api.nvim_win_set_cursor(self.win, { vim.api.nvim_buf_line_count(self.buf), 0 })
  end
  self:_schedule_render()
end

-- Redraw markdown decorations at most every 40ms while streaming.
function Window:_schedule_render()
  if not self.render or self.render_pending then
    return
  end
  self.render_pending = true
  vim.defer_fn(function()
    self.render_pending = false
    if self:valid() then
      render.render(self.buf)
    end
  end, 40)
end

function Window:error(msg)
  if not self:valid() then
    return vim.notify("[codewhy] " .. msg, vim.log.levels.ERROR)
  end
  self:status(nil)
  -- in the buffer rather than a virtual line, so long messages wrap
  self:append((#self.chunks == 0 and "" or "\n\n") .. "**Error:** " .. msg)
end

--- Cancel the request but keep the window.
function Window:stop()
  if self.on_close then
    local cancel = self.on_close
    self.on_close = nil
    cancel()
    self:status("stopped", "WarningMsg")
  end
end

function Window:yank()
  local text = self:text()
  if text == "" then
    return vim.notify("[codewhy] nothing to yank yet", vim.log.levels.WARN)
  end
  vim.fn.setreg('"', text)
  if vim.fn.has("clipboard") == 1 then
    pcall(vim.fn.setreg, "+", text)
  end
  vim.notify("[codewhy] answer yanked")
end

--- Show exactly what was sent to the model, in a float above the answer.
function Window:show_prompt()
  if not self.prompt then
    return vim.notify("[codewhy] the prompt is still being built", vim.log.levels.WARN)
  end
  if not self:valid() then
    return
  end
  local cfg = vim.api.nvim_win_get_config(self.win)
  local buf = scratch(vim.split(self.prompt, "\n", { plain = true }))
  vim.bo[buf].modifiable = false
  render.attach(buf)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = cfg.width,
    height = cfg.height,
    row = cfg.row,
    col = cfg.col,
    zindex = (cfg.zindex or 50) + 1,
    style = "minimal",
    border = cfg.border,
    title = " sent to the model ",
    title_pos = "center",
    footer = " q back ",
    footer_pos = "right",
  })
  set_win_opts(win)
  if self.render then
    render.render(buf)
  end
  for _, lhs in ipairs({ "q", "<Esc>", "p" }) do
    vim.keymap.set("n", lhs, function()
      pcall(vim.api.nvim_win_close, win, true)
    end, { buffer = buf, nowait = true, desc = "codewhy: back to the answer" })
  end
end

function Window:_teardown()
  self:_stop_spinner()
  if self.on_close then
    local cancel = self.on_close
    self.on_close = nil
    cancel()
  end
end

function Window:close()
  if vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_win_close(self.win, true)
  end
  self:_teardown() -- WinClosed does this too; harmless twice
end

return M
