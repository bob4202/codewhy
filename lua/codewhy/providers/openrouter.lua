local sse = require("codewhy.sse")

local M = {}

local function decode(s)
  local ok, obj = pcall(vim.json.decode, s, { luanil = { object = true, array = true } })
  return ok and obj or nil
end

local function error_message(obj)
  if type(obj) ~= "table" or not obj.error then
    return nil
  end
  local e = obj.error
  if type(e) == "string" then
    return e
  end
  local msg = e.message or vim.inspect(e)
  -- OpenRouter wraps upstream provider errors in metadata.raw
  if type(e.metadata) == "table" and type(e.metadata.raw) == "string" then
    msg = msg .. ": " .. e.metadata.raw
  end
  if e.code then
    msg = ("%s (%s)"):format(msg, e.code)
  end
  return msg
end

function M.stream(req, h)
  local opts = req.options or {}
  local body = {
    model = req.model,
    messages = req.messages,
    stream = true,
    temperature = opts.temperature,
    max_tokens = opts.max_tokens,
  }

  -- Body goes through a temp file in Neovim's private (0700) tempdir so large
  -- prompts don't hit argv limits. The key goes through stdin so it never
  -- appears in the process list.
  local tmp = vim.fn.tempname()
  local f, open_err = io.open(tmp, "w")
  if not f then
    h.on_error("could not write the request body: " .. tostring(open_err))
    return { cancel = function() end }
  end
  f:write(vim.json.encode(body))
  f:close()

  local cmd = {
    "curl",
    "-sS",
    "-N",
    "--fail-with-body",
    "--max-time",
    tostring(opts.timeout or 180),
    "-X",
    "POST",
    opts.base_url .. "/chat/completions",
    "-H",
    "@-",
    "-H",
    "Content-Type: application/json",
    "-H",
    "X-Title: codewhy.nvim",
    "--data-binary",
    "@" .. tmp,
  }

  local cancelled, finished = false, false
  local other = {} -- non-SSE output, e.g. a JSON error body
  local stream_error

  local function finish(fn, ...)
    if finished or cancelled then
      return
    end
    finished = true
    fn(...)
  end

  local parser = sse.new(function(data)
    if data == "[DONE]" then
      return
    end
    local obj = decode(data)
    if not obj then
      return
    end
    local err = error_message(obj)
    if err then
      stream_error = err
      return
    end
    local choice = obj.choices and obj.choices[1]
    local delta = choice and choice.delta
    if type(delta) ~= "table" then
      return
    end
    if type(delta.reasoning) == "string" and delta.reasoning ~= "" and h.on_reasoning then
      h.on_reasoning(delta.reasoning)
    end
    if type(delta.content) == "string" and delta.content ~= "" then
      h.on_chunk(delta.content)
    end
  end, function(line)
    table.insert(other, line)
  end)

  local ok, proc = pcall(vim.system, cmd, {
    stdin = "Authorization: Bearer " .. req.api_key .. "\n",
    stdout = function(_, data)
      if data and not cancelled then
        parser.feed(data)
      end
    end,
    text = true,
  }, function(res)
    os.remove(tmp)
    parser.flush()
    if stream_error then
      return finish(h.on_error, stream_error)
    end
    if res.code ~= 0 then
      local msg = error_message(decode(table.concat(other, "\n")))
        or (res.stderr ~= "" and vim.trim(res.stderr))
        or ("curl exited with code " .. res.code)
      return finish(h.on_error, msg)
    end
    finish(h.on_done)
  end)

  if not ok then
    os.remove(tmp)
    h.on_error("failed to start curl: " .. tostring(proc))
    return { cancel = function() end }
  end

  return {
    cancel = function()
      if not finished and not cancelled then
        cancelled = true
        pcall(proc.kill, proc, 15)
      end
    end,
  }
end

local function per_million(price)
  local n = tonumber(price)
  if not n or n < 0 then
    return nil -- OpenRouter uses -1 for dynamic pricing (e.g. openrouter/auto)
  end
  return n * 1e6
end

function M.list_models(opts, cb)
  local cmd = { "curl", "-sS", "--fail-with-body", "--max-time", "30", opts.base_url .. "/models" }
  vim.system(cmd, { text = true }, function(res)
    if res.code ~= 0 then
      return cb(nil, error_message(decode(res.stdout)) or vim.trim(res.stderr or "request failed"))
    end
    local obj = decode(res.stdout)
    if not obj or type(obj.data) ~= "table" then
      return cb(nil, "unexpected response from /models")
    end
    local models = {}
    for _, m in ipairs(obj.data) do
      local p = m.pricing or {}
      local pp, cp = per_million(p.prompt), per_million(p.completion)
      table.insert(models, {
        id = m.id,
        name = m.name or m.id,
        context_length = m.context_length,
        prompt_price = pp,
        completion_price = cp,
        free = (m.id or ""):match(":free$") ~= nil or (pp == 0 and cp == 0),
      })
    end
    cb(models)
  end)
end

return M
