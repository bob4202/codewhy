local M = {}

local SYSTEM = [[You are codewhy, a senior engineer embedded in the user's editor.
You explain code and errors clearly and concisely, in Markdown.
- Ground every claim in the code provided; if something is not shown, say so instead of guessing.
- Refer to code by file and line when useful.
- Prefer short paragraphs and bullet points; use fenced code blocks with a language tag for code.
- Do not repeat the user's code back unless you are changing it.]]

local TASKS = {
  explain = "Explain what the selected code does, how it works, and anything non-obvious "
    .. "(side effects, edge cases, how it uses the related definitions).",
  diagnostic = "Explain the diagnostic(s) listed below in plain language: what they mean, the root cause "
    .. "in this code, and how to fix it. Show the corrected code.",
}

local function fence(lang, start_row, lines)
  local out = { "```" .. (lang or "") }
  local width = #tostring(start_row + #lines - 1)
  for i, l in ipairs(lines) do
    table.insert(out, ("%" .. width .. "d  %s"):format(start_row + i - 1, l))
  end
  table.insert(out, "```")
  return table.concat(out, "\n")
end

local function lang_of(path)
  return vim.filetype.match({ filename = path }) or ""
end

---@param action "explain"|"diagnostic"|"ask"
---@param ctx table from context.gather
---@param question? string for action "ask"
function M.build(action, ctx, question)
  local sel = ctx.selection
  local ft = sel.filetype
  local parts = {}

  local function add(s)
    table.insert(parts, s)
  end

  if action == "ask" then
    add("## Question\n" .. question)
  else
    add("## Task\n" .. TASKS[action])
  end

  add(
    ("## Selected code — %s, lines %d-%d (line numbers are not part of the code)"):format(
      ctx.rel_path,
      sel.start_row,
      sel.end_row
    )
  )
  add(fence(ft, sel.start_row, sel.lines))

  if #ctx.diagnostics > 0 then
    local d = { "## Diagnostics in the selection" }
    for _, x in ipairs(ctx.diagnostics) do
      local src = x.source and (" [" .. x.source .. (x.code and (" " .. tostring(x.code)) or "") .. "]") or ""
      table.insert(d, ("- %s at line %d, col %d%s: %s"):format(x.severity, x.line, x.col, src, x.message))
    end
    add(table.concat(d, "\n"))
  elseif action == "diagnostic" then
    add("## Diagnostics\nNo diagnostics were reported on these lines. Look for likely bugs instead.")
  end

  local s = ctx.surrounding
  if s.before or s.after then
    add("## Surrounding code in " .. ctx.rel_path)
    if s.before then
      add("Before the selection:\n" .. fence(ft, s.before.start_row, s.before.lines))
    end
    if s.after then
      add("After the selection:\n" .. fence(ft, s.after.start_row, s.after.lines))
    end
  end

  if #ctx.definitions > 0 then
    add("## Definitions of symbols used in the selection")
    for _, d in ipairs(ctx.definitions) do
      add(("`%s` — %s:%d\n%s"):format(d.symbol, d.path, d.start_row, fence(lang_of(d.path), d.start_row, d.lines)))
    end
  end

  if #ctx.references > 0 then
    add(("## Where `%s` is used elsewhere"):format(ctx.references[1].symbol))
    for _, r in ipairs(ctx.references) do
      add(("%s:%d\n%s"):format(r.path, r.start_row, fence(lang_of(r.path), r.start_row, r.lines)))
    end
  end

  return {
    { role = "system", content = SYSTEM },
    { role = "user", content = table.concat(parts, "\n\n") },
  }
end

--- The messages as one readable document, for showing the user what was sent.
---@param messages { role: string, content: string }[]
function M.render(messages)
  local out = {}
  for _, m in ipairs(messages) do
    table.insert(out, ("# %s\n\n%s"):format(m.role, m.content))
  end
  return table.concat(out, "\n\n")
end

return M
