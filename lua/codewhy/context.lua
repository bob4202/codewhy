-- Collects what the model gets to see: the selection, nearby lines, diagnostics,
-- and (via LSP) definitions of the symbols used in the selection plus usages.
local M = {}

---@class codewhy.Selection
---@field bufnr integer
---@field path string
---@field filetype string
---@field start_row integer 1-based, inclusive
---@field end_row integer 1-based, inclusive
---@field lines string[]

local DEF_NODE_PATTERNS = {
  "function",
  "method",
  "class",
  "struct",
  "interface",
  "impl",
  "enum",
  "declaration",
  "definition",
  "type_alias",
  "type_spec",
  "trait",
}

local function rel(path)
  return vim.fn.fnamemodify(path, ":~:.")
end

--- Selection from visual mode (when called while still in it), a command range, or the cursor line.
---@param range? { line1: integer, line2: integer }
---@return codewhy.Selection
function M.get_selection(range)
  local bufnr = vim.api.nvim_get_current_buf()
  local mode = vim.fn.mode()
  local s, e, lines

  if mode == "v" or mode == "V" or mode == "\22" then
    local p1, p2 = vim.fn.getpos("v"), vim.fn.getpos(".")
    lines = vim.fn.getregion(p1, p2, { type = mode })
    s, e = math.min(p1[2], p2[2]), math.max(p1[2], p2[2])
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  elseif range then
    s, e = range.line1, range.line2
  else
    s = vim.api.nvim_win_get_cursor(0)[1]
    e = s
  end

  lines = lines or vim.api.nvim_buf_get_lines(bufnr, s - 1, e, false)
  return {
    bufnr = bufnr,
    path = vim.api.nvim_buf_get_name(bufnr),
    filetype = vim.bo[bufnr].filetype,
    start_row = s,
    end_row = e,
    lines = lines,
  }
end

---@param sel codewhy.Selection
function M.diagnostics(sel)
  local out = {}
  for _, d in ipairs(vim.diagnostic.get(sel.bufnr)) do
    local row = d.lnum + 1
    local end_row = (d.end_lnum or d.lnum) + 1
    if end_row >= sel.start_row and row <= sel.end_row then
      table.insert(out, {
        severity = vim.diagnostic.severity[d.severity] or "INFO",
        line = row,
        col = d.col + 1,
        message = d.message,
        source = d.source,
        code = d.code,
      })
    end
  end
  table.sort(out, function(a, b)
    return a.line < b.line
  end)
  return out
end

---@param sel codewhy.Selection
function M.surrounding(sel, n)
  local total = vim.api.nvim_buf_line_count(sel.bufnr)
  local function chunk(from, to)
    if to < from then
      return nil
    end
    return { start_row = from, lines = vim.api.nvim_buf_get_lines(sel.bufnr, from - 1, to, false) }
  end
  return {
    before = chunk(math.max(1, sel.start_row - n), sel.start_row - 1),
    after = chunk(sel.end_row + 1, math.min(total, sel.end_row + n)),
  }
end

-- Identifier positions inside the selection: tree-sitter if available, else a regex.
local function symbols_in_selection(sel, max)
  local seen, out = {}, {}
  local function add(name, row, col)
    if not seen[name] and #out < max then
      seen[name] = true
      table.insert(out, { name = name, row = row, col = col })
    end
  end

  local ok, parser = pcall(vim.treesitter.get_parser, sel.bufnr)
  if ok and parser then
    local tree = parser:parse()[1]
    local srow, erow = sel.start_row - 1, sel.end_row - 1
    local function walk(node)
      local r1, _, r2, _ = node:range()
      if r2 < srow or r1 > erow or #out >= max then
        return
      end
      if node:named_child_count() == 0 and node:type():find("identifier") and r1 >= srow then
        local _, c1 = node:start()
        add(vim.treesitter.get_node_text(node, sel.bufnr), r1, c1)
        return
      end
      for child in node:iter_children() do
        if child:named() then
          walk(child)
        end
      end
    end
    if tree then
      walk(tree:root())
      if #out > 0 then
        return out
      end
    end
  end

  for i, line in ipairs(sel.lines) do
    local row = sel.start_row - 2 + i
    -- for a charwise selection the first line is a fragment; fall back to whole line lookup
    local full = vim.api.nvim_buf_get_lines(sel.bufnr, row, row + 1, false)[1] or line
    for col, name in full:gmatch("()([%a_][%w_]*)") do
      if #name > 1 then
        add(name, row, col - 1)
      end
    end
  end
  return out
end

-- File contents for snippet extraction, cached per gather.
local function file_lines(cache, path)
  if cache[path] then
    return cache[path].lines
  end
  local lines
  local b = vim.fn.bufnr(path)
  if b > 0 and vim.api.nvim_buf_is_loaded(b) then
    lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  else
    local f = io.open(path, "r")
    if not f then
      return nil
    end
    lines = vim.split(f:read("*a"), "\n", { plain = true })
    f:close()
  end
  cache[path] = { lines = lines }
  return lines
end

local function file_tree(cache, path)
  local entry = cache[path]
  if not entry then
    return nil
  end
  if entry.tree == nil then
    entry.tree = false
    local ft = vim.filetype.match({ filename = path })
    local lang = ft and vim.treesitter.language.get_lang(ft)
    if lang then
      local ok, parser = pcall(vim.treesitter.get_string_parser, table.concat(entry.lines, "\n"), lang)
      if ok and parser then
        local ok2, trees = pcall(parser.parse, parser)
        entry.tree = ok2 and trees[1] or false
      end
    end
  end
  return entry.tree or nil
end

-- The enclosing definition (function/class/...) of a position, or a window of lines.
local function definition_snippet(cache, path, row, col, max_lines)
  local lines = file_lines(cache, path)
  if not lines then
    return nil
  end
  local from, to
  local tree = file_tree(cache, path)
  if tree then
    -- climb to the outermost definition-like node that still fits, so we get the
    -- whole function_definition rather than just its function_declarator
    local node = tree:root():named_descendant_for_range(row, col, row, col)
    while node do
      local t = node:type()
      local matched = false
      for _, p in ipairs(DEF_NODE_PATTERNS) do
        if t:find(p) then
          matched = true
          break
        end
      end
      local r1, _, r2, _ = node:range()
      if r2 - r1 + 1 > max_lines then
        -- too big: if nothing fits yet and it starts at the symbol, show its head;
        -- otherwise (e.g. a class around a method) fall back to a window
        if matched and not from and row - r1 <= 2 then
          from, to = r1, r2
        end
        break
      end
      if matched then
        from, to = r1, r2
      end
      node = node:parent()
    end
  end
  if not from then
    from, to = math.max(0, row - 2), row + 15
  end
  to = math.min(to, from + max_lines - 1, #lines - 1)
  return {
    start_row = from + 1,
    lines = vim.list_slice(lines, from + 1, to + 1),
  }
end

--- Whether code from `path` may be sent. Symlinks are resolved first, so a link
--- inside the project can't smuggle in a file from outside it.
---@param opts table config.context
---@param path string absolute
---@param root string absolute, already resolved
function M.allowed(opts, path, root)
  path = vim.uv.fs_realpath(path) or path
  if opts.project_only and path:sub(1, #root + 1) ~= root .. "/" then
    return false
  end
  for _, pat in ipairs(opts.exclude or {}) do
    if path:find(pat, 1, true) then
      return false
    end
  end
  return true
end

local function locations(result)
  if not result then
    return {}
  end
  if result.uri or result.targetUri then
    result = { result }
  end
  local out = {}
  for _, loc in ipairs(result) do
    local uri = loc.targetUri or loc.uri
    local range = loc.targetSelectionRange or loc.targetRange or loc.range
    if uri and range then
      table.insert(out, { path = vim.uri_to_fname(uri), row = range.start.line, col = range.start.character })
    end
  end
  return out
end

-- Send one LSP request per params entry; cb(results) once all answered or after timeout_ms.
-- results[i] is a list of locations for params[i].
local function lsp_batch(bufnr, method, params, timeout_ms, cb)
  local results, pending, done, cancels = {}, #params, false, {}
  local function finish()
    if done then
      return
    end
    done = true
    for _, c in ipairs(cancels) do
      pcall(c)
    end
    cb(results)
  end
  if pending == 0 then
    return finish()
  end
  for i, p in ipairs(params) do
    table.insert(
      cancels,
      vim.lsp.buf_request_all(bufnr, method, p, function(res)
        results[i] = {}
        for _, r in pairs(res or {}) do
          vim.list_extend(results[i], locations(r.result))
        end
        pending = pending - 1
        if pending == 0 then
          vim.schedule(finish)
        end
      end)
    )
  end
  vim.defer_fn(finish, timeout_ms)
end

local function inside_selection(sel, loc)
  return loc.path == sel.path and loc.row + 1 >= sel.start_row and loc.row + 1 <= sel.end_row
end

--- Definitions of the symbols in the selection, then usages of the "main" symbol:
--- of the first few symbols defined in the project, the first one that is used
--- outside the selection (e.g. the selected function's name rather than a local).
local function lsp_context(sel, opts, root, cb)
  local bufnr = sel.bufnr
  if #vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/definition" }) == 0 then
    return cb({}, {})
  end
  local symbols = symbols_in_selection(sel, opts.max_symbols)
  if #symbols == 0 then
    return cb({}, {})
  end

  local uri = vim.uri_from_bufnr(bufnr)
  local function pos_params(sym)
    return { textDocument = { uri = uri }, position = { line = sym.row, character = sym.col } }
  end

  lsp_batch(bufnr, "textDocument/definition", vim.tbl_map(pos_params, symbols), opts.lsp_timeout_ms, function(results)
    local defs, candidates = {}, {}
    for i, sym in ipairs(symbols) do
      local in_project = false
      for _, loc in ipairs(results[i] or {}) do
        loc.symbol = sym.name
        table.insert(defs, loc)
        in_project = in_project or M.allowed(opts, loc.path, root)
      end
      if in_project and #candidates < 3 then
        table.insert(candidates, sym)
      end
    end

    if
      #candidates == 0
      or opts.max_references <= 0
      or #vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/references" }) == 0
    then
      return cb(defs, {})
    end
    local params = vim.tbl_map(function(sym)
      local p = pos_params(sym)
      p.context = { includeDeclaration = false }
      return p
    end, candidates)
    lsp_batch(bufnr, "textDocument/references", params, opts.lsp_timeout_ms, function(ref_results)
      for i, sym in ipairs(candidates) do
        local outside = vim.tbl_filter(function(loc)
          return not inside_selection(sel, loc)
        end, ref_results[i] or {})
        if #outside > 0 then
          for _, loc in ipairs(outside) do
            loc.symbol = sym.name
          end
          return cb(defs, outside)
        end
      end
      cb(defs, {})
    end)
  end)
end

---@param sel codewhy.Selection
---@param opts table config.context
---@param cb fun(ctx: table)
function M.gather(sel, opts, cb)
  local ctx = {
    selection = sel,
    rel_path = rel(sel.path),
    diagnostics = M.diagnostics(sel),
    surrounding = M.surrounding(sel, opts.surrounding_lines),
    definitions = {},
    references = {},
  }

  if not opts.lsp then
    return cb(ctx)
  end

  local root = vim.uv.fs_realpath(vim.fn.getcwd()) or vim.fn.getcwd()
  lsp_context(sel, opts, root, function(def_locs, ref_locs)
    local cache = {}
    local seen = {}
    local budget = opts.max_chars

    for _, loc in ipairs(def_locs) do
      if #ctx.definitions >= opts.max_snippets or budget <= 0 then
        break
      end
      if not inside_selection(sel, loc) and M.allowed(opts, loc.path, root) then
        local snip = definition_snippet(cache, loc.path, loc.row, loc.col, opts.max_snippet_lines)
        local key = snip and (loc.path .. ":" .. snip.start_row)
        if snip and not seen[key] then
          seen[key] = true
          snip.path = rel(loc.path)
          snip.symbol = loc.symbol
          budget = budget - #table.concat(snip.lines, "\n")
          table.insert(ctx.definitions, snip)
        end
      end
    end

    for _, loc in ipairs(ref_locs) do
      if #ctx.references >= opts.max_references or budget <= 0 then
        break
      end
      if not inside_selection(sel, loc) and M.allowed(opts, loc.path, root) then
        local lines = file_lines(cache, loc.path)
        local key = loc.path .. ":" .. loc.row
        if lines and not seen[key] then
          seen[key] = true
          local from = math.max(1, loc.row + 1 - 2)
          local snip = {
            path = rel(loc.path),
            symbol = loc.symbol,
            start_row = from,
            lines = vim.list_slice(lines, from, math.min(#lines, loc.row + 1 + 2)),
          }
          budget = budget - #table.concat(snip.lines, "\n")
          table.insert(ctx.references, snip)
        end
      end
    end

    cb(ctx)
  end)
end

return M
