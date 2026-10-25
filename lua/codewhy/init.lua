local config = require("codewhy.config")
local context = require("codewhy.context")
local prompt = require("codewhy.prompt")
local providers = require("codewhy.providers")
local secrets = require("codewhy.secrets")
local ui = require("codewhy.ui")

local M = {}

local function notify(msg, level)
  vim.notify("[codewhy] " .. msg, level or vim.log.levels.INFO)
end

--- The active model: last picked (persisted) > setup() > nil.
function M.current_model()
  return config.load_state().model or config.options.model
end

local function format_price(p)
  if p == nil then
    return "?"
  end
  if p == 0 then
    return "0"
  end
  return p < 1 and ("%.2f"):format(p) or ("%.1f"):format(p)
end

--- Pick a model from the provider's live list.
---@param opts? { free_only?: boolean, on_choice?: fun(id: string) }
function M.pick_model(opts)
  opts = opts or {}
  local o = config.options
  local ok, provider = pcall(providers.get, o.provider)
  if not ok then
    return notify(tostring(provider), vim.log.levels.ERROR)
  end
  notify("fetching models…")
  provider.list_models(
    o.providers[o.provider],
    vim.schedule_wrap(function(models, err)
      if not models then
        return notify("could not list models: " .. tostring(err), vim.log.levels.ERROR)
      end
      if opts.free_only then
        models = vim.tbl_filter(function(m)
          return m.free
        end, models)
      end
      table.sort(models, function(a, b)
        if a.free ~= b.free then
          return a.free
        end
        return a.id < b.id
      end)
      local current = M.current_model()
      vim.ui.select(models, {
        prompt = opts.free_only and "codewhy model (free)" or "codewhy model",
        format_item = function(m)
          local price = m.free and "free"
            or ("$%s/$%s per M"):format(format_price(m.prompt_price), format_price(m.completion_price))
          local ctx = m.context_length and ("%dk"):format(math.floor(m.context_length / 1000)) or "?"
          return ("%s%s  [%s · %s ctx]"):format(m.id == current and "● " or "", m.id, price, ctx)
        end,
      }, function(choice)
        if not choice then
          return
        end
        local state = config.load_state()
        state.model = choice.id
        config.save_state(state)
        notify("model: " .. choice.id)
        if opts.on_choice then
          opts.on_choice(choice.id)
        end
      end)
    end)
  )
end

local TITLES = { explain = "explain", diagnostic = "diagnostic", ask = "ask" }

---@param action "explain"|"diagnostic"|"ask"
---@param sel codewhy.Selection
---@param question? string
local function run(action, sel, question)
  local o = config.options
  local model = M.current_model()
  if not model then
    notify("no model set, pick one (free models shown)")
    return M.pick_model({
      free_only = true,
      on_choice = function()
        run(action, sel, question)
      end,
    })
  end

  secrets.get_key(o, function(key, key_err)
    if not key then
      -- no custom lookup configured: offer to save one to the keyring right now
      if not o.api_key_cmd then
        return secrets.prompt_and_store(o.provider, function(k, err)
          if k then
            run(action, sel, question)
          elseif err ~= "cancelled" then
            notify(err, vim.log.levels.ERROR)
          end
        end)
      end
      return notify(key_err, vim.log.levels.ERROR)
    end

    if action == "diagnostic" and #context.diagnostics(sel) == 0 then
      notify("no diagnostics here; looking for likely bugs instead", vim.log.levels.WARN)
    end
    local win = ui.open(o.ui, ("codewhy · %s · %s"):format(TITLES[action], model))
    win:loading("gathering context…")

    context.gather(sel, o.context, function(ctx)
      if not win:valid() then
        return
      end
      local n = #ctx.definitions + #ctx.references
      win:loading(("waiting for %s… (%d related snippet%s)"):format(model, n, n == 1 and "" or "s"))

      local messages = prompt.build(action, ctx, question)
      win.prompt = prompt.render(messages)

      local ok, provider = pcall(providers.get, o.provider)
      if not ok then
        return win:error(tostring(provider))
      end

      local started = false
      local handle = provider.stream({
        model = model,
        messages = messages,
        api_key = key,
        options = o.providers[o.provider],
      }, {
        on_reasoning = vim.schedule_wrap(function()
          if not started then
            win:loading("thinking…")
          end
        end),
        on_chunk = vim.schedule_wrap(function(text)
          started = true
          win:append(text)
          win:loading("writing…")
        end),
        on_done = vim.schedule_wrap(function()
          win.on_close = nil
          if started then
            win:status(("✓ %.1fs · y yank · p prompt"):format(win:elapsed()))
          else
            win:error("the model returned an empty response")
          end
        end),
        on_error = vim.schedule_wrap(function(msg)
          win.on_close = nil
          win:error(msg)
        end),
      })
      win.on_close = handle.cancel
    end)
  end)
end

---@param range? { line1: integer, line2: integer }
function M.explain(range)
  run("explain", context.get_selection(range))
end

---@param range? { line1: integer, line2: integer }
function M.explain_diagnostic(range)
  run("diagnostic", context.get_selection(range))
end

---@param range? { line1: integer, line2: integer }
---@param question? string
function M.ask(range, question)
  local sel = context.get_selection(range) -- capture before the input prompt leaves visual mode
  if question and question ~= "" then
    return run("ask", sel, question)
  end
  vim.ui.input({ prompt = "Ask codewhy: " }, function(q)
    if q and vim.trim(q) ~= "" then
      run("ask", sel, q)
    end
  end)
end

--- :CodeWhy key [delete]
function M.key(sub)
  local provider = config.options.provider
  if sub == "delete" then
    return secrets.delete(provider)
  end
  if config.options.api_key_cmd then
    notify("note: api_key_cmd is set in setup(), it takes precedence over the keyring", vim.log.levels.WARN)
  end
  secrets.prompt_and_store(provider, function(_, err)
    if err and err ~= "cancelled" then
      notify(err, vim.log.levels.ERROR)
    end
  end)
end

function M.setup(opts)
  local o = config.setup(opts)
  local maps = {
    explain = { M.explain, "codewhy: explain code" },
    diagnostic = { M.explain_diagnostic, "codewhy: explain diagnostic" },
    ask = { M.ask, "codewhy: ask about code" },
  }
  for name, lhs in pairs(o.keymaps or {}) do
    if lhs and maps[name] then
      local fn, desc = maps[name][1], maps[name][2]
      vim.keymap.set({ "n", "x" }, lhs, function()
        fn()
      end, { desc = desc })
    end
  end
end

return M
