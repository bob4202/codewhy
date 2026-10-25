local secrets = require("codewhy.secrets")

local ENV = "CODEWHY_TEST_KEY"

-- Synchronous wrapper around the async lookup.
local function get(opts)
  local done, key, err = false, nil, nil
  secrets.get_key(vim.tbl_extend("force", { provider = "test", api_key_env = ENV }, opts or {}), function(k, e)
    done, key, err = true, k, e
  end)
  assert.is_true(vim.wait(5000, function()
    return done
  end))
  return key, err
end

describe("secrets.get_key", function()
  before_each(function()
    secrets.clear()
    vim.env[ENV] = nil
  end)

  it("uses the first line of an argv api_key_cmd", function()
    assert.are.equal("sk-test-123", (get({ api_key_cmd = { "printf", "sk-test-123\nsecond line" } })))
  end)

  it("runs a string api_key_cmd through sh and trims it", function()
    assert.are.equal("sk-abc", (get({ api_key_cmd = "echo '  sk-abc  '" })))
  end)

  it("reports a failing command without echoing its stdout", function()
    local key, err = get({ api_key_cmd = { "sh", "-c", "echo sk-should-not-leak; echo oops >&2; exit 3" } })
    assert.is_nil(key)
    assert.truthy(err:find("exit 3", 1, true))
    assert.truthy(err:find("oops", 1, true))
    assert.is_nil(err:find("sk-should-not-leak", 1, true))
  end)

  it("prefers api_key_cmd over the environment", function()
    vim.env[ENV] = "from-env"
    assert.are.equal("from-cmd", (get({ api_key_cmd = { "printf", "from-cmd" } })))
  end)

  it("reads the environment variable", function()
    vim.env[ENV] = "sk-env"
    assert.are.equal("sk-env", (get()))
  end)

  it("strips anything after a newline in the env var (no header injection)", function()
    vim.env[ENV] = "sk-env\r\nX-Evil: 1"
    assert.are.equal("sk-env", (get()))
  end)

  it("caches the key per provider until cleared", function()
    vim.env[ENV] = "first"
    assert.are.equal("first", (get()))
    vim.env[ENV] = "second"
    assert.are.equal("first", (get()))
    secrets.clear()
    assert.are.equal("second", (get()))
  end)
end)
