-- API key lookup and storage. The key is kept in memory only and never logged.
-- At rest it lives in the system keyring (Secret Service via `secret-tool`),
-- under the attribute `service=<provider>`.
local M = {}

local cache = {}

local function first_line(s)
  return ((s or ""):match("^[^\r\n]*"):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function has_keyring()
  return vim.fn.executable("secret-tool") == 1
end

local function run(cmd, opts, cb)
  local ok, err = pcall(
    vim.system,
    cmd,
    vim.tbl_extend("force", { text = true, timeout = 30000 }, opts or {}),
    function(res)
      vim.schedule(function()
        cb(res)
      end)
    end
  )
  if not ok then
    cb({ code = -1, stdout = "", stderr = tostring(err) })
  end
end

-- Run a lookup command; cb(key|nil, err|nil). Never echoes stdout (it may be the secret).
local function lookup(cmd, label, cb)
  run(cmd, nil, function(res)
    local key = first_line(res.stdout)
    if res.code ~= 0 or key == "" then
      local stderr = first_line(res.stderr)
      return cb(
        nil,
        ("%s returned no key (exit %d)%s"):format(label, res.code, stderr ~= "" and (": " .. stderr) or "")
      )
    end
    cb(key)
  end)
end

local function keyring_cmd(provider)
  return { "secret-tool", "lookup", "service", provider }
end

--- Lookup order: api_key_cmd > $api_key_env > system keyring (service=<provider>).
---@param opts codewhy.Config
---@param cb fun(key: string|nil, err: string|nil)
function M.get_key(opts, cb)
  local provider = opts.provider
  if cache[provider] then
    return cb(cache[provider])
  end
  local function done(key, err)
    if key then
      cache[provider] = key
    end
    cb(key, err)
  end

  local cmd = opts.api_key_cmd
  if cmd then
    return lookup(type(cmd) == "string" and { "sh", "-c", cmd } or cmd, "api_key_cmd", done)
  end
  -- first line only: a stray newline must never end up in the Authorization header
  local env = first_line(opts.api_key_env and vim.env[opts.api_key_env])
  if env ~= "" then
    return done(env)
  end
  if has_keyring() then
    return lookup(keyring_cmd(provider), "keyring", function(key)
      done(key, not key and "no API key saved yet" or nil)
    end)
  end
  done(nil, ("no API key: set $%s or `api_key_cmd` in setup()"):format(opts.api_key_env or "OPENROUTER_API_KEY"))
end

--- Prompt for a key (hidden input) and save it to the system keyring.
---@param provider string
---@param cb? fun(key: string|nil, err: string|nil)
function M.prompt_and_store(provider, cb)
  cb = cb or function() end
  if not has_keyring() then
    return cb(nil, "secret-tool not found; install libsecret, or set $OPENROUTER_API_KEY instead")
  end
  local ok, key = pcall(vim.fn.inputsecret, ("%s API key (saved to system keyring): "):format(provider))
  key = ok and vim.trim(key or "") or ""
  if key == "" then
    return cb(nil, "cancelled")
  end
  -- key goes via stdin, never argv
  run({ "secret-tool", "store", "--label=codewhy: " .. provider, "service", provider }, { stdin = key }, function(res)
    if res.code ~= 0 then
      return cb(nil, "saving to keyring failed: " .. first_line(res.stderr))
    end
    cache[provider] = key
    vim.notify(("[codewhy] %s key saved to system keyring"):format(provider))
    cb(key)
  end)
end

---@param provider string
function M.delete(provider)
  cache[provider] = nil
  if not has_keyring() then
    return
  end
  run({ "secret-tool", "clear", "service", provider }, nil, function(res)
    vim.notify(
      ("[codewhy] %s key %s"):format(provider, res.code == 0 and "removed from keyring" or "could not be removed")
    )
  end)
end

function M.clear()
  cache = {}
end

return M
