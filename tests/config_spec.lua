local config = require("codewhy.config")

describe("config", function()
  local notify = vim.notify
  after_each(function()
    vim.notify = notify
    config.setup({})
  end)

  it("uses the defaults when called with nothing", function()
    assert.are.same(config.defaults, config.setup())
  end)

  it("deep-merges user options", function()
    local o = config.setup({ context = { max_chars = 10 }, ui = { border = "single" } })
    assert.are.equal(10, o.context.max_chars)
    assert.are.equal(config.defaults.context.max_snippets, o.context.max_snippets)
    assert.are.equal("single", o.ui.border)
  end)

  it("replaces the exclude list instead of merging it by index", function()
    local o = config.setup({ context = { exclude = { "/build/" } } })
    assert.are.same({ "/build/" }, o.context.exclude)
  end)

  it("does not mutate the defaults", function()
    config.setup({ context = { max_chars = 1 } })
    assert.are.equal(30000, config.defaults.context.max_chars)
  end)

  it("refuses a plaintext api_key and warns", function()
    local warned
    vim.notify = function(msg, level)
      warned = { msg = msg, level = level }
    end
    local o = config.setup({ api_key = "sk-plaintext" })
    assert.is_nil(o.api_key)
    assert.are.equal(vim.log.levels.WARN, warned.level)
    assert.is_nil(warned.msg:find("sk-plaintext", 1, true), "the key must not be echoed")
  end)

  it("excludes common secret files by default", function()
    local ex = table.concat(config.defaults.context.exclude, " ")
    for _, s in ipairs({ "/.env", ".pem", "/.ssh/" }) do
      assert.truthy(ex:find(s, 1, true), s)
    end
  end)

  describe("state", function()
    local file = vim.fn.stdpath("state") .. "/codewhy.json"

    after_each(function()
      os.remove(file)
    end)

    it("round-trips", function()
      config.save_state({ model = "a/b:free" })
      assert.are.same({ model = "a/b:free" }, config.load_state())
    end)

    it("returns an empty table when missing or corrupt", function()
      os.remove(file)
      assert.are.same({}, config.load_state())
      vim.fn.mkdir(vim.fn.fnamemodify(file, ":h"), "p")
      local f = assert(io.open(file, "w"))
      f:write("{not json")
      f:close()
      assert.are.same({}, config.load_state())
    end)
  end)
end)
