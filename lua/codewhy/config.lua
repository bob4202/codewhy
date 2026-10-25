local M = {}

---@class codewhy.Config
M.defaults = {
  -- Provider module under lua/codewhy/providers/
  provider = "openrouter",
  -- Model id. nil = ask with the picker (free models) on first use.
  -- A choice made with :CodeWhy model is remembered across sessions.
  model = nil,

  -- API key lookup, in order:
  --   1. api_key_cmd: list (argv) or string (run via sh -c); first line of stdout is used
  --   2. environment variable api_key_env
  api_key_cmd = nil,
  api_key_env = "OPENROUTER_API_KEY",

  -- Set any to false to disable. Apply in normal and visual mode.
  keymaps = {
    explain = "<leader>ce",
    diagnostic = "<leader>cd",
    ask = "<leader>ca",
  },

  context = {
    lsp = true, -- use LSP definitions/references
    lsp_timeout_ms = 2000,
    max_symbols = 15, -- unique identifiers in the selection to look up
    max_snippets = 8, -- definition snippets to include
    max_snippet_lines = 60,
    max_references = 5, -- usages of the first symbol
    surrounding_lines = 20, -- lines shown above/below the selection
    max_chars = 30000, -- rough cap on total context size
    -- Only include code from inside the project root (cwd); skip paths containing these.
    project_only = true,
    -- Plain substrings, not patterns. The secrets entries are belt and braces: they're
    -- only reached via LSP definitions, but should never be sent anywhere.
    exclude = {
      "/node_modules/",
      "/.venv/",
      "/venv/",
      "/site-packages/",
      "/vendor/",
      "/.git/",
      "/.env",
      ".pem",
      "/id_rsa",
      "/id_ed25519",
      "/.ssh/",
    },
  },

  ui = {
    width = 0.6, -- fraction of editor columns
    height = 0.6, -- fraction of editor lines
    border = "rounded",
    -- Markdown rendering in the answer window:
    --   "auto"    built-in renderer, unless render-markdown.nvim or markview.nvim is loaded
    --   "builtin" always the built-in renderer
    --   false     plain markdown (still syntax highlighted)
    render = "auto",
  },

  providers = {
    openrouter = {
      base_url = "https://openrouter.ai/api/v1",
      temperature = 0.2,
      max_tokens = nil,
      timeout = 180, -- seconds
    },
  },
}

---@type codewhy.Config
M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  opts = opts or {}
  if opts.api_key ~= nil then
    vim.notify(
      "[codewhy] `api_key` is not supported; use `api_key_cmd` (e.g. pass/secret-tool) or $OPENROUTER_API_KEY",
      vim.log.levels.WARN
    )
    opts.api_key = nil
  end
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  -- lists should replace, not merge
  if opts.context and opts.context.exclude then
    M.options.context.exclude = opts.context.exclude
  end
  return M.options
end

-- Persisted (non-secret) state, e.g. the last picked model.
local state_file = vim.fn.stdpath("state") .. "/codewhy.json"

function M.load_state()
  local f = io.open(state_file, "r")
  if not f then
    return {}
  end
  local ok, data = pcall(vim.json.decode, f:read("*a"))
  f:close()
  return ok and type(data) == "table" and data or {}
end

function M.save_state(data)
  vim.fn.mkdir(vim.fn.fnamemodify(state_file, ":h"), "p")
  local f = io.open(state_file, "w")
  if f then
    f:write(vim.json.encode(data))
    f:close()
  end
end

return M
