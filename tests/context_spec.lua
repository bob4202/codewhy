local context = require("codewhy.context")

local function buffer(lines, name)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_name(buf, name or (vim.fn.getcwd() .. "/fixture_" .. buf .. ".lua"))
  vim.bo[buf].filetype = "lua"
  vim.api.nvim_set_current_buf(buf)
  return buf
end

local LINES = {}
for i = 1, 30 do
  LINES[i] = "local v" .. i .. " = " .. i
end

describe("context.get_selection", function()
  it("uses a command range", function()
    buffer(LINES)
    local sel = context.get_selection({ line1 = 3, line2 = 5 })
    assert.are.equal(3, sel.start_row)
    assert.are.equal(5, sel.end_row)
    assert.are.same({ LINES[3], LINES[4], LINES[5] }, sel.lines)
    assert.are.equal("lua", sel.filetype)
  end)

  it("falls back to the cursor line", function()
    buffer(LINES)
    vim.api.nvim_win_set_cursor(0, { 7, 0 })
    local sel = context.get_selection()
    assert.are.equal(7, sel.start_row)
    assert.are.same({ LINES[7] }, sel.lines)
  end)
end)

describe("context.diagnostics", function()
  it("keeps only diagnostics touching the selection, sorted by line", function()
    local buf = buffer(LINES)
    local ns = vim.api.nvim_create_namespace("codewhy_test")
    vim.diagnostic.set(ns, buf, {
      { lnum = 9, col = 0, message = "later", severity = vim.diagnostic.severity.WARN },
      { lnum = 1, col = 0, message = "outside", severity = vim.diagnostic.severity.ERROR },
      { lnum = 4, col = 2, message = "first", severity = vim.diagnostic.severity.ERROR, source = "lua_ls" },
      { lnum = 2, end_lnum = 4, col = 0, message = "spans in", severity = vim.diagnostic.severity.HINT },
    })
    local d = context.diagnostics({ bufnr = buf, start_row = 5, end_row = 10 })
    assert.are.same(
      { "spans in", "first", "later" },
      vim.tbl_map(function(x)
        return x.message
      end, d)
    )
    assert.are.equal("ERROR", d[2].severity)
    assert.are.equal(5, d[2].line)
    assert.are.equal(3, d[2].col)
    assert.are.equal("lua_ls", d[2].source)
  end)
end)

describe("context.surrounding", function()
  it("returns lines above and below", function()
    local buf = buffer(LINES)
    local s = context.surrounding({ bufnr = buf, start_row = 10, end_row = 11 }, 2)
    assert.are.same({ start_row = 8, lines = { LINES[8], LINES[9] } }, s.before)
    assert.are.same({ start_row = 12, lines = { LINES[12], LINES[13] } }, s.after)
  end)

  it("clamps at the buffer edges", function()
    local buf = buffer(LINES)
    local s = context.surrounding({ bufnr = buf, start_row = 1, end_row = 30 }, 5)
    assert.is_nil(s.before)
    assert.is_nil(s.after)
  end)
end)

describe("context.allowed", function()
  local root = "/home/u/proj"
  local opts = { project_only = true, exclude = { "/node_modules/", "/.env" } }

  it("allows files inside the project", function()
    assert.is_true(context.allowed(opts, root .. "/src/a.lua", root))
  end)

  it("rejects files outside the project", function()
    assert.is_false(context.allowed(opts, "/usr/share/nvim/runtime/lua/vim/lsp.lua", root))
  end)

  it("is not fooled by a sibling directory sharing the prefix", function()
    assert.is_false(context.allowed(opts, "/home/u/proj-secrets/key.lua", root))
  end)

  it("rejects excluded paths even inside the project", function()
    assert.is_false(context.allowed(opts, root .. "/node_modules/x/index.js", root))
    assert.is_false(context.allowed(opts, root .. "/.env.local", root))
  end)

  it("allows outside files when project_only is off", function()
    assert.is_true(context.allowed({ project_only = false, exclude = {} }, "/elsewhere/a.lua", root))
  end)

  it("resolves symlinks that point outside the project", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. "/proj", "p")
    vim.fn.mkdir(dir .. "/outside", "p")
    vim.fn.writefile({ "secret" }, dir .. "/outside/creds.lua")
    vim.uv.fs_symlink(dir .. "/outside/creds.lua", dir .. "/proj/creds.lua")
    local real_root = vim.uv.fs_realpath(dir .. "/proj")
    assert.is_false(context.allowed({ project_only = true, exclude = {} }, dir .. "/proj/creds.lua", real_root))
    vim.fn.delete(dir, "rf")
  end)
end)

describe("context.gather", function()
  it("collects selection context without LSP", function()
    local buf = buffer(LINES)
    local sel = context.get_selection({ line1 = 10, line2 = 10 })
    local ctx
    context.gather(sel, { lsp = false, surrounding_lines = 1 }, function(c)
      ctx = c
    end)
    assert.are.equal(sel, ctx.selection)
    assert.are.equal(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":~:."), ctx.rel_path)
    assert.are.same({ LINES[9] }, ctx.surrounding.before.lines)
    assert.are.same({}, ctx.definitions)
    assert.are.same({}, ctx.references)
  end)

  it("skips LSP lookups when no client is attached", function()
    buffer(LINES)
    local sel = context.get_selection({ line1 = 1, line2 = 1 })
    local ctx
    context.gather(sel, vim.tbl_extend("force", require("codewhy.config").defaults.context, { lsp = true }), function(c)
      ctx = c
    end)
    assert.is_true(vim.wait(1000, function()
      return ctx ~= nil
    end))
    assert.are.same({}, ctx.definitions)
  end)
end)
