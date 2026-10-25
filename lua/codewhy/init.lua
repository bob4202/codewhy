local config = require("codewhy.config")
local context = require("codewhy.context")
local prompt = require("codewhy.prompt")
local providers = require("codewhy.providers")
local secrets = require("codewhy.secrets")
local session = require("codewhy.session")
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

-- Chat state -------------------------------------------------------------------

---@type codewhy.Session|nil
local current
local busy = false
---@type codewhy.Selection|nil code attached to the next message from the composer
local attached
local ui_ready = false

local function save()
  local h = config.options.history
  if current and h.enabled then
    session.save(current)
    session.prune(h.max_sessions)
  end
end

local function refresh_title()
  local model = M.current_model()
  ui.set_title("codewhy · " .. (model and model:match("[^/]+$") or "no model"))
end

--- The current chat, resuming the most recent saved one on first use.
---@param resume? boolean
local function current_session(resume)
  if not current then
    local h = config.options.history
    current = resume and h.enabled and session.list()[1] or session.new()
    ui.load(current.turns)
    refresh_title()
  end
  return current
end

local function rel(path)
  return vim.fn.fnamemodify(path, ":~:.")
end

local function title_of(text)
  text = vim.trim((text or ""):gsub("%s+", " "))
  return #text > 40 and (text:sub(1, 39) .. "…") or text
end

--- Ask the model. With a selection, gathers context for it first; without one
--- it's a follow-up in the current chat.
---@param action "explain"|"diagnostic"|"ask"|"followup"
---@param sel? codewhy.Selection
---@param question? string
local function run(action, sel, question)
  local o = config.options
  M._ensure_ui()
  if busy then
    ui.open(false)
    return notify("still answering, <C-c> in the panel stops it", vim.log.levels.WARN)
  end
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
    if busy then
      return
    end

    local s = current_session(false)
    local label = sel and ("%s · %s:%d-%d"):format(action, rel(sel.path), sel.start_row, sel.end_row) or "you"
    s.title = s.title or title_of(question or label)
    refresh_title()
    ui.open(o.ui.layout == "float" or o.ui.panel.focus)

    busy = true
    local turn = ui.begin_turn(label, question)
    ---@type codewhy.Turn
    local record = { label = label, question = question, answer = "", sent = 0 }
    local finished = false

    -- Every way a turn ends comes through here exactly once.
    local function finish(err)
      if finished then
        return
      end
      finished = true
      busy = false
      turn:finish()
      record.answer = turn:text()
      record.error = err
      if record.sent > 0 then
        if record.answer ~= "" then
          table.insert(s.messages, { role = "assistant", content = record.answer })
        else
          table.remove(s.messages) -- no answer: don't leave a dangling question in the history
        end
      end
      table.insert(s.turns, record)
      if s == current then
        save()
      end
      if not ui.is_open() then
        notify(err and ("failed: " .. err) or "answer ready, toggle the panel to read it")
      end
    end

    turn.on_cancel = function()
      finish(nil)
    end

    local function send(user_msg)
      if finished then
        return -- stopped while gathering context
      end
      local ok, provider = pcall(providers.get, o.provider)
      if not ok then
        turn:error(tostring(provider))
        return finish(tostring(provider))
      end
      table.insert(s.messages, user_msg)
      record.sent = #s.messages
      record.width = ui.text_width() -- the model formats for the panel it will appear in

      local messages = { { role = "system", content = prompt.system(record.width) } }
      vim.list_extend(messages, session.trim(s.messages, o.history.max_chars))

      local started = false
      local handle = provider.stream({
        model = model,
        messages = messages,
        api_key = key,
        options = o.providers[o.provider],
      }, {
        on_reasoning = vim.schedule_wrap(function()
          if not started then
            turn:loading("thinking…")
          end
        end),
        on_chunk = vim.schedule_wrap(function(text)
          started = true
          turn:append(text)
          turn:loading("writing…")
        end),
        on_done = vim.schedule_wrap(function()
          if finished then
            return
          end
          if started then
            turn:status(("✓ %.1fs"):format(turn:elapsed()))
            finish(nil)
          else
            turn:error("the model returned an empty response")
            finish("the model returned an empty response")
          end
        end),
        on_error = vim.schedule_wrap(function(msg)
          if finished then
            return
          end
          turn:error(msg)
          finish(msg)
        end),
      })
      turn.on_cancel = function()
        handle.cancel()
        finish(nil)
      end
    end

    if not sel then
      turn:loading("waiting for " .. model .. "…")
      return send({ role = "user", content = question })
    end

    if action == "diagnostic" and #context.diagnostics(sel) == 0 then
      notify("no diagnostics here; looking for likely bugs instead", vim.log.levels.WARN)
    end
    turn:loading("gathering context…")
    context.gather(sel, o.context, function(ctx)
      local n = #ctx.definitions + #ctx.references
      turn:loading(("waiting for %s… (%d related snippet%s)"):format(model, n, n == 1 and "" or "s"))
      send(prompt.build(action, ctx, question)[2])
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
  local sel = context.get_selection(range) -- capture before focus leaves visual mode
  if question and question ~= "" then
    return run("ask", sel, question)
  end
  -- attach the code to the composer; the question is typed there
  M._ensure_ui()
  attached = sel
  ui.attach(("%s:%d-%d"):format(vim.fn.fnamemodify(sel.path, ":t"), sel.start_row, sel.end_row))
  ui.focus_input()
end

--- Continue the current chat: with a question, send it; without, focus the composer.
---@param question? string
function M.followup(question)
  M._ensure_ui()
  current_session(true)
  if question and question ~= "" then
    return run("followup", nil, question)
  end
  ui.focus_input()
end

--- Composer submit. Returns false (keep the text) when it can't be sent yet.
local function send(text)
  if busy then
    notify("still answering, <C-c> stops it", vim.log.levels.WARN)
    return false
  end
  local sel = attached
  attached = nil
  ui.attach(nil)
  if sel then
    run("ask", sel, text)
  else
    run("followup", nil, text)
  end
  return true
end

local function detach()
  if attached then
    attached = nil
    ui.attach(nil)
  end
end

function M.toggle()
  M._ensure_ui()
  current_session(true)
  ui.toggle()
end

local function refuse_if_busy()
  if busy then
    notify("still answering, <C-c> in the panel stops it", vim.log.levels.WARN)
  end
  return busy
end

--- Start a fresh chat. The previous one stays in the history.
function M.new_chat()
  M._ensure_ui()
  if refuse_if_busy() then
    return
  end
  save()
  current = session.new()
  detach()
  ui.load({})
  refresh_title()
  ui.open(config.options.ui.layout == "float")
end

local function confirm(msg)
  return vim.fn.confirm(msg, "&Delete\n&Cancel", 2) == 1
end

-- Remove a chat from disk; if it's the open one, the panel starts fresh.
local function forget(id)
  session.delete(id)
  if current and current.id == id then
    current = session.new()
    ui.load({})
    refresh_title()
  end
end

--- Delete the chat that's open in the panel.
function M.delete_chat()
  M._ensure_ui()
  if refuse_if_busy() then
    return
  end
  if not current or #current.turns == 0 then
    return notify("nothing to delete")
  end
  if confirm(("Delete chat %q?"):format(current.title or "untitled")) then
    forget(current.id)
    notify("chat deleted")
  end
end

local function pick(prompt_text, on_choice)
  local list = session.list()
  if #list == 0 then
    return notify("no saved chats")
  end
  local now = os.time()
  vim.ui.select(list, {
    prompt = prompt_text,
    format_item = function(s)
      local mark = current and s.id == current.id and "● " or ""
      return ("%s%s  ·  %d turn%s  ·  %s"):format(
        mark,
        s.title or s.id,
        #s.turns,
        #s.turns == 1 and "" or "s",
        session.age(s.updated, now)
      )
    end,
  }, function(choice)
    if choice then
      on_choice(choice)
    end
  end)
end

--- :CodeWhy history          pick a saved chat and open it
--- :CodeWhy history delete   pick a saved chat and delete it
--- :CodeWhy history clear    delete every saved chat
---@param sub? "delete"|"clear"
function M.history(sub)
  M._ensure_ui()
  if refuse_if_busy() then
    return
  end
  if not config.options.history.enabled then
    return notify("history is disabled (history.enabled = false)", vim.log.levels.WARN)
  end

  if sub == "clear" then
    local list = session.list()
    if #list == 0 then
      return notify("no saved chats")
    end
    if confirm(("Delete all %d saved chat%s?"):format(#list, #list == 1 and "" or "s")) then
      for _, s in ipairs(list) do
        forget(s.id)
      end
      notify("history cleared")
    end
  elseif sub == "delete" then
    pick("delete which chat?", function(choice)
      if confirm(("Delete chat %q?"):format(choice.title or choice.id)) then
        forget(choice.id)
        notify("chat deleted")
      end
    end)
  elseif sub == nil or sub == "" then
    pick("codewhy chats", function(choice)
      save()
      current = choice
      detach()
      ui.load(current.turns)
      refresh_title()
      ui.open(true)
    end)
  else
    notify("unknown history action: " .. sub .. " (use delete or clear)", vim.log.levels.ERROR)
  end
end

function M.stop()
  if not ui.stop() then
    notify("nothing to stop")
  end
end

local function last_turn()
  return current and current.turns[#current.turns]
end

function M.yank()
  local t = last_turn()
  ui.yank(t and t.answer)
end

--- Show exactly what was sent for the last turn.
function M.show_prompt()
  local t = last_turn()
  if not t or t.sent == 0 then
    return notify("nothing has been sent in this chat yet", vim.log.levels.WARN)
  end
  local messages = { { role = "system", content = prompt.system(t.width) } }
  vim.list_extend(messages, session.trim(vim.list_slice(current.messages, 1, t.sent), config.options.history.max_chars))
  ui.show_text("sent to the model", prompt.render(messages))
end

function M._ensure_ui()
  if ui_ready then
    return
  end
  ui_ready = true
  ui.setup(config.options.ui, {
    send = send,
    detach = detach,
    hide = ui.hide,
    stop = M.stop,
    new = M.new_chat,
    history = function()
      M.history()
    end,
    delete = M.delete_chat,
    yank = M.yank,
    prompt = M.show_prompt,
  })
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
  ui_ready = false
  M._ensure_ui()
  -- name = { fn, desc, modes }
  local maps = {
    explain = { M.explain, "explain code", { "n", "x" } },
    diagnostic = { M.explain_diagnostic, "explain diagnostic", { "n", "x" } },
    ask = { M.ask, "ask about code", { "n", "x" } },
    toggle = { M.toggle, "toggle chat panel", { "n" } },
    new = { M.new_chat, "new chat", { "n" } },
    history = { M.history, "chat history", { "n" } },
  }
  for name, lhs in pairs(o.keymaps or {}) do
    if lhs and maps[name] then
      local fn, desc, modes = unpack(maps[name])
      vim.keymap.set(modes, lhs, function()
        fn()
      end, { desc = "codewhy: " .. desc })
    end
  end
end

-- For tests.
function M._reset()
  current, busy, attached = nil, false, nil
  ui.attach(nil)
end

return M
