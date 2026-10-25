-- Test bootstrap: `make test`, or
--   nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua', sequential = true }"
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

-- Keep tests away from the real state dir (persisted model) and config. Set once in the
-- parent process; the per-file child nvims inherit it.
if not vim.env.CODEWHY_TEST then
  vim.env.CODEWHY_TEST = "1"
  for _, kind in ipairs({ "CONFIG", "DATA", "STATE", "CACHE" }) do
    vim.env["XDG_" .. kind .. "_HOME"] = root .. "/.tests/xdg/" .. kind:lower()
  end
end

local plenary = vim.env.PLENARY_DIR or (root .. "/.tests/plenary.nvim")
if vim.fn.isdirectory(plenary) == 0 then
  vim.fn.system({ "git", "clone", "--depth", "1", "https://github.com/nvim-lua/plenary.nvim", plenary })
end

vim.opt.rtp:prepend(plenary)
vim.opt.rtp:prepend(root)
vim.opt.swapfile = false
vim.cmd("runtime plugin/plenary.vim")
