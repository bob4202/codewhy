-- Provider registry.
--
-- A provider module returns a table implementing:
--
--   stream(req, handlers) -> handle
--     req      = { model, messages, api_key, options }  (options = config.providers[name])
--     handlers = { on_chunk(text), on_reasoning(text)?, on_done(), on_error(msg) }
--     handle   = { cancel() }
--     Handlers may be called from a fast event context; callers schedule UI work.
--
--   list_models(options, cb)
--     cb(models|nil, err|nil), models = { { id, name, free, context_length, prompt_price, completion_price } }
--     Prices are USD per million tokens (numbers) or nil when unknown.
local M = {}

---@param name string
function M.get(name)
  local mod = "codewhy.providers." .. name
  local ok, provider = pcall(require, mod)
  if not ok then
    -- a missing module and a module that fails to load are different problems
    if tostring(provider):find("module '" .. mod .. "' not found", 1, true) then
      error(("[codewhy] unknown provider %q"):format(name), 0)
    end
    error(("[codewhy] provider %q failed to load: %s"):format(name, provider), 0)
  end
  return provider
end

return M
