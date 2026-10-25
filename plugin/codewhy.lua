if vim.g.loaded_codewhy then
  return
end
vim.g.loaded_codewhy = true

local subcommands = {
  explain = function(range)
    require("codewhy").explain(range)
  end,
  diagnostic = function(range)
    require("codewhy").explain_diagnostic(range)
  end,
  ask = function(range, args)
    require("codewhy").ask(range, table.concat(args, " "))
  end,
  key = function(_, args)
    require("codewhy").key(args[1])
  end,
  model = function(_, args)
    require("codewhy").pick_model({ free_only = args[1] == "free" })
  end,
}

vim.api.nvim_create_user_command("CodeWhy", function(cmd)
  local name = cmd.fargs[1] or "explain"
  local fn = subcommands[name]
  if not fn then
    return vim.notify("[codewhy] unknown subcommand: " .. name, vim.log.levels.ERROR)
  end
  local range = cmd.range > 0 and { line1 = cmd.line1, line2 = cmd.line2 } or nil
  fn(range, vim.list_slice(cmd.fargs, 2))
end, {
  nargs = "*",
  range = true,
  desc = "codewhy: explain code with an LLM",
  complete = function(arglead, line)
    local args = vim.split(line, "%s+", { trimempty = true })
    if #args > 2 or (#args == 2 and arglead == "") then
      return ({ model = { "free" }, key = { "delete" } })[args[2]] or {}
    end
    return vim.tbl_filter(function(s)
      return s:find(arglead, 1, true) == 1
    end, vim.tbl_keys(subcommands))
  end,
})
