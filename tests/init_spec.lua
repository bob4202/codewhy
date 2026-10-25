-- End to end: keymap-level entry point -> context -> prompt -> provider -> window,
-- with a fake provider in place of the network.
local codewhy = require("codewhy")
local config = require("codewhy.config")
local secrets = require("codewhy.secrets")

local requests

package.loaded["codewhy.providers.fake"] = {
  stream = function(req, h)
    table.insert(requests, req)
    h.on_reasoning("…")
    h.on_chunk("It adds ")
    h.on_chunk("two numbers.")
    h.on_done()
    return { cancel = function() end }
  end,
  list_models = function(_, cb)
    cb({ { id = "fake/model", free = true } })
  end,
}

local function answer_window()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then
      return w
    end
  end
end

describe("codewhy", function()
  before_each(function()
    requests = {}
    secrets.clear()
    os.remove(vim.fn.stdpath("state") .. "/codewhy.json")
    codewhy.setup({
      provider = "fake",
      model = "fake/model",
      api_key_cmd = { "printf", "sk-fake" },
      keymaps = false,
      context = { lsp = false },
    })
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "local function add(a, b)", "  return a + b", "end" })
    vim.bo[buf].filetype = "lua"
    vim.api.nvim_set_current_buf(buf)
  end)

  after_each(function()
    local w = answer_window()
    if w then
      vim.api.nvim_win_close(w, true)
    end
  end)

  it("explains a range end to end", function()
    codewhy.explain({ line1 = 1, line2 = 3 })
    assert.is_true(vim.wait(3000, function()
      local w = answer_window()
      return w and vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)[1] == "It adds two numbers."
    end))

    local req = requests[1]
    assert.are.equal("fake/model", req.model)
    assert.are.equal("sk-fake", req.api_key)
    assert.truthy(req.messages[2].content:find("2    return a + b", 1, true))
    assert.are.equal(config.options.providers.fake, req.options)
  end)

  it("passes the question through for ask", function()
    codewhy.ask({ line1 = 2, line2 = 2 }, "is this safe?")
    assert.is_true(vim.wait(3000, function()
      return #requests == 1
    end))
    assert.truthy(requests[1].messages[2].content:find("## Question\nis this safe?", 1, true))
  end)

  it("prefers the model picked with :CodeWhy model over setup()", function()
    config.save_state({ model = "picked/model" })
    assert.are.equal("picked/model", codewhy.current_model())
  end)

  it("registers the configured keymaps", function()
    codewhy.setup({ keymaps = { explain = "<leader>zz", diagnostic = false, ask = false } })
    assert.are.equal("codewhy: explain code", vim.fn.maparg("<leader>zz", "n", false, true).desc)
    assert.are.equal("", vim.fn.maparg("<leader>cd", "n"))
  end)
end)
