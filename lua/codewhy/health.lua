local M = {}

function M.check()
  local health = vim.health
  local config = require("codewhy.config")
  local o = config.options

  health.start("codewhy")

  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim " .. tostring(vim.version()))
  else
    health.error("Neovim 0.10+ is required")
  end

  if vim.fn.executable("curl") == 1 then
    -- --fail-with-body (used to surface API errors) needs curl 7.76+
    local out = vim.system({ "curl", "--version" }, { text = true }):wait().stdout or ""
    local version = out:match("^curl (%d+%.%d+%.?%d*)")
    if version and vim.version.lt(version, "7.76.0") then
      health.error(("curl %s is too old, 7.76+ is required"):format(version))
    else
      health.ok("curl " .. (version or "found"))
    end
  else
    health.error("curl not found in $PATH")
  end

  local model = require("codewhy").current_model()
  if model then
    health.ok(("provider: %s, model: %s"):format(o.provider, model))
  else
    health.warn("no model chosen yet", { "Run :CodeWhy model (or :CodeWhy model free)" })
  end

  local source = o.api_key_cmd and "api_key_cmd"
    or (o.api_key_env and (vim.env[o.api_key_env] or "") ~= "" and ("$" .. o.api_key_env))
    or (vim.fn.executable("secret-tool") == 1 and "system keyring")
    or "nowhere (no api_key_cmd, env var, or secret-tool)"
  local secrets = require("codewhy.secrets")
  secrets.clear()
  local done, key, err = false, nil, nil
  secrets.get_key(o, function(k, e)
    done, key, err = true, k, e
  end)
  vim.wait(10000, function()
    return done
  end)
  if key then
    -- never print any part of the key
    health.ok(("API key found via %s (%d chars)"):format(source, #key))
  else
    health.error(("no API key (%s): %s"):format(source, err or "timed out"), {
      "Run :CodeWhy key to save it to the system keyring",
      "Or export " .. (o.api_key_env or "OPENROUTER_API_KEY"),
    })
  end

  local clients = vim.lsp.get_clients({ bufnr = 0 })
  if #clients > 0 then
    health.ok("LSP attached to current buffer: " .. table.concat(
      vim.tbl_map(function(c)
        return c.name
      end, clients),
      ", "
    ))
  else
    health.info("no LSP client on the current buffer (context will be the selection + nearby lines only)")
  end
end

return M
