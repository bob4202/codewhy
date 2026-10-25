-- The provider shells out to curl via vim.system; these tests swap in a fake that
-- records the call and replays canned output, so nothing touches the network.
local openrouter = require("codewhy.providers.openrouter")

local real_system = vim.system
local calls

---@param script { stdout?: string[], code?: integer, stderr?: string, manual?: boolean }
local function fake_curl(script)
  vim.system = function(cmd, opts, on_exit)
    local call = { cmd = cmd, opts = opts, on_exit = on_exit, killed = false }
    for i, a in ipairs(cmd) do
      if a == "--data-binary" then
        call.tmp = cmd[i + 1]:sub(2)
        local f = assert(io.open(call.tmp, "r"))
        call.body = vim.json.decode(f:read("*a"))
        f:close()
      end
    end
    function call.finish(code, stderr)
      on_exit({ code = code or 0, stdout = "", stderr = stderr or "" })
    end
    table.insert(calls, call)
    if not script.manual then
      vim.schedule(function()
        for _, chunk in ipairs(script.stdout or {}) do
          opts.stdout(nil, chunk)
        end
        call.finish(script.code, script.stderr)
      end)
    end
    return {
      kill = function()
        call.killed = true
      end,
    }
  end
end

local function sse(obj)
  return "data: " .. vim.json.encode(obj) .. "\n\n"
end

local function delta(fields)
  return sse({ choices = { { delta = fields } } })
end

-- Run a request against the fake and collect what the handlers saw.
local function run(script)
  fake_curl(script)
  local got = { chunks = {}, reasoning = {} }
  local handle = openrouter.stream({
    model = "test/model",
    messages = { { role = "user", content = "hi" } },
    api_key = "sk-or-SECRET",
    options = { base_url = "https://example.invalid/api/v1", temperature = 0.2, timeout = 5 },
  }, {
    on_chunk = function(t)
      table.insert(got.chunks, t)
    end,
    on_reasoning = function(t)
      table.insert(got.reasoning, t)
    end,
    on_done = function()
      got.done = true
    end,
    on_error = function(msg)
      got.error = msg
    end,
  })
  if not script.manual then
    assert.is_true(vim.wait(2000, function()
      return got.done or got.error ~= nil
    end))
  end
  return got, handle
end

describe("openrouter.stream", function()
  before_each(function()
    calls = {}
  end)
  after_each(function()
    vim.system = real_system
  end)

  it("streams content deltas in order, then finishes", function()
    local got = run({
      stdout = {
        ": OPENROUTER PROCESSING\n\n",
        delta({ content = "Hel" }),
        delta({ content = "lo" }),
        "data: [DONE]\n\n",
      },
    })
    assert.are.same({ "Hel", "lo" }, got.chunks)
    assert.is_true(got.done)
    assert.is_nil(got.error)
  end)

  it("routes reasoning tokens separately", function()
    local got = run({ stdout = { delta({ reasoning = "hmm" }), delta({ content = "ok" }) } })
    assert.are.same({ "hmm" }, got.reasoning)
    assert.are.same({ "ok" }, got.chunks)
  end)

  it("handles SSE events split across reads", function()
    local event = delta({ content = "split" })
    local mid = math.floor(#event / 2)
    local got = run({ stdout = { event:sub(1, mid), event:sub(mid + 1) } })
    assert.are.same({ "split" }, got.chunks)
  end)

  it("sends the API key on stdin, never in argv", function()
    run({ stdout = {} })
    local call = calls[1]
    for _, arg in ipairs(call.cmd) do
      assert.is_nil(arg:find("SECRET", 1, true), "key leaked into argv: " .. arg)
    end
    assert.are.equal("Authorization: Bearer sk-or-SECRET\n", call.opts.stdin)
    assert.truthy(vim.tbl_contains(call.cmd, "@-"))
  end)

  it("keeps the API key out of the request body file", function()
    run({ stdout = {} })
    assert.is_nil(vim.json.encode(calls[1].body):find("SECRET", 1, true))
  end)

  it("posts the expected body and removes the temp file afterwards", function()
    run({ stdout = {} })
    local call = calls[1]
    assert.are.equal("test/model", call.body.model)
    assert.is_true(call.body.stream)
    assert.are.equal(0.2, call.body.temperature)
    assert.are.same({ { role = "user", content = "hi" } }, call.body.messages)
    assert.truthy(vim.tbl_contains(call.cmd, "https://example.invalid/api/v1/chat/completions"))
    assert.is_nil(vim.uv.fs_stat(call.tmp), "temp file should be deleted")
  end)

  it("reports an error object sent mid-stream, with upstream details", function()
    local got = run({
      stdout = {
        delta({ content = "partial" }),
        sse({ error = { message = "Provider returned error", code = 429, metadata = { raw = "rate limited" } } }),
      },
    })
    assert.is_nil(got.done)
    assert.are.equal("Provider returned error: rate limited (429)", got.error)
  end)

  it("reports a JSON error body from a failed request", function()
    local got = run({ stdout = { '{"error":{"message":"No auth credentials found","code":401}}' }, code = 22 })
    assert.are.equal("No auth credentials found (401)", got.error)
  end)

  it("falls back to curl's stderr", function()
    local got = run({ code = 6, stderr = "curl: (6) Could not resolve host\n" })
    assert.are.equal("curl: (6) Could not resolve host", got.error)
  end)

  it("cancel kills curl and silences later callbacks", function()
    local got, handle = run({ manual = true })
    handle.cancel()
    assert.is_true(calls[1].killed)
    calls[1].finish(143)
    vim.wait(50)
    assert.is_nil(got.done)
    assert.is_nil(got.error)
  end)
end)

describe("openrouter.list_models", function()
  after_each(function()
    vim.system = real_system
  end)

  local function list(stdout, code)
    vim.system = function(_, _, on_exit)
      on_exit({ code = code or 0, stdout = stdout, stderr = "" })
    end
    local models, err
    openrouter.list_models({ base_url = "https://example.invalid/api/v1" }, function(m, e)
      models, err = m, e
    end)
    return models, err
  end

  it("parses models, prices per million and free flags", function()
    local models = list(vim.json.encode({
      data = {
        { id = "a/free:free", context_length = 8000, pricing = { prompt = "0", completion = "0" } },
        { id = "b/paid", name = "Paid", pricing = { prompt = "0.000001", completion = "0.000002" } },
        { id = "openrouter/auto", pricing = { prompt = "-1", completion = "-1" } },
      },
    }))
    assert.are.equal(3, #models)
    assert.is_true(models[1].free)
    assert.are.equal(8000, models[1].context_length)
    assert.is_false(models[2].free)
    assert.are.equal("Paid", models[2].name)
    assert.are.near(1, models[2].prompt_price, 1e-9)
    assert.are.near(2, models[2].completion_price, 1e-9)
    assert.is_nil(models[3].prompt_price, "dynamic pricing is unknown, not negative")
  end)

  it("reports an unexpected response", function()
    local models, err = list('{"nope":true}')
    assert.is_nil(models)
    assert.are.equal("unexpected response from /models", err)
  end)
end)
