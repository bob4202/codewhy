local providers = require("codewhy.providers")

describe("providers.get", function()
  after_each(function()
    package.preload["codewhy.providers.broken"] = nil
    package.loaded["codewhy.providers.broken"] = nil
  end)

  it("loads a provider", function()
    local p = providers.get("openrouter")
    assert.are.equal("function", type(p.stream))
    assert.are.equal("function", type(p.list_models))
  end)

  it("reports an unknown provider", function()
    local ok, err = pcall(providers.get, "nope")
    assert.is_false(ok)
    assert.are.equal('[codewhy] unknown provider "nope"', err)
  end)

  it("surfaces the real error when a provider fails to load", function()
    package.preload["codewhy.providers.broken"] = function()
      error("boom")
    end
    local ok, err = pcall(providers.get, "broken")
    assert.is_false(ok)
    assert.truthy(err:find('provider "broken" failed to load', 1, true))
    assert.truthy(err:find("boom", 1, true))
  end)
end)
