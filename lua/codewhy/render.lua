-- Built-in markdown rendering for the answer window, in the spirit of Obsidian's
-- reading view: headings with a tinted band and no `#`s, real bullets and
-- checkboxes, shaded code blocks with a language label, quote bars, box-drawn
-- tables (re-aligned) and full-width rules. Everything is extmarks on top of the treesitter
-- parse; the buffer text stays plain markdown (so `y` yanks markdown).
--
-- Emphasis, inline code and link delimiters are hidden by Neovim's own markdown
-- highlight queries, given conceallevel=2 (set by ui.lua).
local M = {}

local ns = vim.api.nvim_create_namespace("codewhy_render")

local HEADING_ICONS = { "◆ ", "◇ ", "▸ ", "▹ ", "· ", "· " }
local BULLETS = { "•", "◦", "▪", "▫" }

local QUERY = [[
(atx_heading) @heading
(fenced_code_block) @code
[(list_marker_minus) (list_marker_plus) (list_marker_star)] @bullet
(task_list_marker_unchecked) @unchecked
(task_list_marker_checked) @checked
(block_quote) @quote
(thematic_break) @hr
(pipe_table) @table
]]

local INLINE_QUERY = [[
(code_span) @code_span
]]

-- Highlights ------------------------------------------------------------------

local function hl_color(name, attr)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  return ok and hl[attr] or nil
end

-- Mix two 0xRRGGBB colors; alpha is the share of `a`.
local function blend(a, b, alpha)
  local function ch(c, shift)
    return math.floor(c / 2 ^ shift) % 256
  end
  local out = 0
  for _, shift in ipairs({ 16, 8, 0 }) do
    out = out + math.floor(ch(a, shift) * alpha + ch(b, shift) * (1 - alpha) + 0.5) * 2 ^ shift
  end
  return out
end

--- (Re)define the highlight groups from the current colorscheme. Users can
--- override any of them; we only set them when they aren't defined already
--- or when we defined them ourselves.
function M.set_highlights()
  local dark = vim.o.background == "dark"
  -- transparent themes have no bg; blend against what the terminal most likely shows
  local bg = hl_color("NormalFloat", "bg") or hl_color("Normal", "bg") or (dark and 0x000000 or 0xffffff)
  local fg = hl_color("NormalFloat", "fg") or hl_color("Normal", "fg") or (dark and 0xffffff or 0x000000)

  local function set(name, spec)
    spec.default = true
    vim.api.nvim_set_hl(0, name, spec)
  end

  for level = 1, 6 do
    local color = hl_color("@markup.heading." .. level .. ".markdown", "fg")
      or hl_color("@markup.heading", "fg")
      or hl_color("Title", "fg")
    set("CodewhyH" .. level, { fg = color, bold = true })
    -- a translucent band behind the heading
    if color then
      set("CodewhyH" .. level .. "Bg", { bg = blend(color, bg, level <= 2 and 0.18 or 0.10) })
    else
      set("CodewhyH" .. level .. "Bg", { link = "CursorLine" })
    end
  end

  set("CodewhyCode", { bg = blend(fg, bg, 0.07) })
  set("CodewhyInlineCode", { bg = blend(fg, bg, 0.12) })
  set("CodewhyCodeLabel", { link = "Comment" })
  set("CodewhyBullet", { link = "Special" })
  set("CodewhyUnchecked", { link = "Comment" })
  set("CodewhyChecked", { link = "DiagnosticOk" })
  set("CodewhyQuote", { link = "Comment" })
  set("CodewhyRule", { link = "FloatBorder" })
  set("CodewhyTable", { link = "FloatBorder" })
  set("CodewhyTableHeader", { bold = true })
end

local hl_ready = false
local function ensure_highlights()
  if hl_ready then
    return
  end
  hl_ready = true
  M.set_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("codewhy_render", { clear = true }),
    callback = M.set_highlights,
  })
end

-- Language icon from mini.icons or nvim-web-devicons, when installed.
local function lang_icon(lang)
  local ok, icons = pcall(require, "mini.icons")
  if ok and icons.get then
    local got, icon = pcall(icons.get, "filetype", lang)
    if got and icon then
      return icon .. " "
    end
  end
  local ok2, devicons = pcall(require, "nvim-web-devicons")
  if ok2 then
    local icon = devicons.get_icon_by_filetype(lang)
    if icon then
      return icon .. " "
    end
  end
  return ""
end

-- Renderers -------------------------------------------------------------------

local function mark(buf, row, col, opts)
  opts.priority = opts.priority or 200
  pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, col, opts)
end

local function line(buf, row)
  return vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
end

local render = {}

function render.heading(buf, node)
  local marker = node:child(0)
  local level = tonumber(marker and marker:type():match("^atx_h(%d)_marker$")) or 1
  local row, col, _, mcol = marker:range()
  local text = line(buf, row)
  -- hide "## " and draw an icon in its place
  local hide_to = math.min(#text, mcol + (text:sub(mcol + 1, mcol + 1) == " " and 1 or 0))
  mark(buf, row, col, {
    end_col = hide_to,
    conceal = "",
    virt_text = { { HEADING_ICONS[level], "CodewhyH" .. level } },
    virt_text_pos = "inline",
  })
  mark(buf, row, 0, {
    end_row = row,
    end_col = #text,
    hl_group = "CodewhyH" .. level,
    line_hl_group = "CodewhyH" .. level .. "Bg",
  })
end

function render.code(buf, node)
  local srow, _, erow, ecol = node:range()
  -- the range ends at column 0 of the line after the closing fence
  local last = ecol == 0 and erow - 1 or erow
  for row = srow, last do
    mark(buf, row, 0, { line_hl_group = "CodewhyCode", priority = 100 })
  end

  local open = line(buf, srow)
  local lang = open:match("^%s*[`~]+%s*([%w_+#.-]+)")
  mark(buf, srow, 0, { end_col = #open, conceal = "" })
  -- Neovim 0.11+ hides fence lines completely (conceal_lines), so the label goes
  -- on the first line of code
  if lang and srow + 1 <= last then
    mark(buf, srow + 1, 0, {
      virt_text = { { " " .. lang_icon(lang) .. lang .. " ", "CodewhyCodeLabel" } },
      virt_text_pos = "right_align",
    })
  end

  local close = line(buf, last)
  if last > srow and close:match("^%s*[`~][`~][`~]+%s*$") then
    mark(buf, last, 0, { end_col = #close, conceal = "" })
  end
end

function render.bullet(buf, node)
  local row, col = node:range()
  local depth = 0
  local parent = node:parent()
  while parent do
    if parent:type() == "list" then
      depth = depth + 1
    end
    parent = parent:parent()
  end
  local next = node:next_named_sibling()
  if next and next:type():find("^task_list_marker") then
    -- the checkbox takes the bullet's place
    local _, _, _, ecol = node:range()
    mark(buf, row, col, { end_col = ecol, conceal = "" })
    return
  end
  mark(buf, row, col, {
    virt_text = { { BULLETS[(depth - 1) % #BULLETS + 1], "CodewhyBullet" } },
    virt_text_pos = "overlay",
  })
end

local function checkbox(icon, hl)
  return function(buf, node)
    local row, col, _, ecol = node:range()
    mark(buf, row, col, { end_col = ecol, conceal = "", virt_text = { { icon, hl } }, virt_text_pos = "inline" })
  end
end
render.unchecked = checkbox("☐", "CodewhyUnchecked")
render.checked = checkbox("☑", "CodewhyChecked")

function render.quote(buf, node)
  local srow, _, erow, ecol = node:range()
  local last = ecol == 0 and erow - 1 or erow
  for row = srow, last do
    local col = line(buf, row):find(">", 1, true)
    if col then
      mark(buf, row, col - 1, { virt_text = { { "▎", "CodewhyQuote" } }, virt_text_pos = "overlay" })
    end
  end
end

function render.hr(buf, node, width)
  local row = node:range()
  mark(buf, row, 0, {
    virt_text = { { ("─"):rep(width), "CodewhyRule" } },
    virt_text_pos = "overlay",
  })
end

-- Byte columns of the unescaped pipes in a table line.
local function pipes(text)
  local out = {}
  for i in text:gmatch("()|") do
    if text:sub(i - 1, i - 1) ~= "\\" then
      table.insert(out, i - 1)
    end
  end
  return out
end

-- Display width of a cell as rendered: inline delimiters and link targets are concealed.
local function cell_width(text)
  text = text:gsub("%[([^%]]*)%]%b()", "%1"):gsub("[`*]", "")
  return vim.fn.strdisplaywidth(text)
end

-- Tables are drawn with box characters and re-aligned: each cell gets inline padding
-- up to its column's width, so ragged markdown (as models tend to write) lines up.
function render.table(buf, node)
  local rows = {}
  for child in node:iter_children() do
    local t = child:type()
    if t == "pipe_table_header" or t == "pipe_table_row" or t == "pipe_table_delimiter_row" then
      local row = child:range()
      local text = line(buf, row)
      table.insert(rows, { row = row, text = text, pipes = pipes(text), kind = t })
    end
  end

  local widths = {}
  for _, r in ipairs(rows) do
    r.cells = {}
    if r.kind ~= "pipe_table_delimiter_row" then
      for i = 1, #r.pipes - 1 do
        local w = cell_width(r.text:sub(r.pipes[i] + 2, r.pipes[i + 1]))
        r.cells[i] = w
        widths[i] = math.max(widths[i] or 0, w)
      end
    end
  end
  if #widths == 0 then
    return
  end

  for _, r in ipairs(rows) do
    if r.kind == "pipe_table_delimiter_row" then
      local parts = {}
      for i, w in ipairs(widths) do
        parts[i] = ("─"):rep(w)
      end
      mark(buf, r.row, 0, {
        end_col = #r.text,
        conceal = "",
        virt_text = { { (r.text:match("^%s*") or "") .. "├" .. table.concat(parts, "┼") .. "┤", "CodewhyTable" } },
        virt_text_pos = "inline",
      })
    else
      if r.kind == "pipe_table_header" then
        mark(buf, r.row, 0, { end_col = #r.text, hl_group = "CodewhyTableHeader", priority = 90 })
      end
      for i, col in ipairs(r.pipes) do
        local pad = i > 1 and widths[i - 1] and (widths[i - 1] - (r.cells[i - 1] or 0)) or 0
        mark(buf, r.row, col, {
          end_col = col + 1,
          conceal = "",
          virt_text = { { (" "):rep(pad) .. "│", "CodewhyTable" } },
          virt_text_pos = "inline",
        })
      end
    end
  end
end

function render.code_span(buf, node)
  local srow, scol, erow, ecol = node:range()
  mark(buf, srow, scol, { end_row = erow, end_col = ecol, hl_group = "CodewhyInlineCode", priority = 90 })
end

-- Entry point -------------------------------------------------------------------

local queries = {}
local function query(lang, src)
  if queries[lang] == nil then
    local ok, q = pcall(vim.treesitter.query.parse, lang, src)
    queries[lang] = ok and q or false
  end
  return queries[lang] or nil
end

--- Whether the markdown parsers are available (bundled with Neovim 0.10+).
function M.available()
  return pcall(vim.treesitter.language.add, "markdown") and pcall(vim.treesitter.language.add, "markdown_inline")
end

--- Set up treesitter highlighting (and its built-in concealing) for a buffer.
function M.attach(buf)
  if M.available() then
    pcall(vim.treesitter.start, buf, "markdown")
  end
end

--- Redraw all decorations. Cheap enough to call on every streamed chunk
--- (treesitter reparses incrementally), but ui.lua throttles it anyway.
---@param buf integer
---@param width? integer for horizontal rules; defaults to the window showing buf
function M.render(buf, width)
  if not vim.api.nvim_buf_is_valid(buf) or not M.available() then
    return
  end
  ensure_highlights()
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  local ok, parser = pcall(vim.treesitter.get_parser, buf, "markdown")
  if not ok or not parser then
    return
  end
  parser:parse(true)
  if not width then
    local win = vim.fn.bufwinid(buf)
    width = win ~= -1 and vim.api.nvim_win_get_width(win) or 80
  end

  parser:for_each_tree(function(tree, ltree)
    local lang = ltree:lang()
    local q = lang == "markdown" and query(lang, QUERY) or lang == "markdown_inline" and query(lang, INLINE_QUERY)
    if not q then
      return
    end
    for id, node in q:iter_captures(tree:root(), buf, 0, -1) do
      local fn = render[q.captures[id]]
      if fn then
        fn(buf, node, width)
      end
    end
  end)
end

function M.clear(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  end
end

M.ns = ns
M._blend = blend

return M
