# codewhy.nvim

[![CI](https://github.com/bob4202/codewhy.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/bob4202/codewhy.nvim/actions/workflows/ci.yml)
![Neovim 0.10+](https://img.shields.io/badge/Neovim-0.10%2B-57A143?logo=neovim&logoColor=white)

Highlight code, press a key, and get an explanation from an LLM, grounded in the
relevant parts of *your* codebase. codewhy asks your language server for the
definitions of the symbols you selected and the places they're used, adds any
diagnostics on those lines, and streams the answer into a floating window.

Currently supports [OpenRouter](https://openrouter.ai) (free and paid models).
Providers are pluggable (see [Adding a provider](#adding-a-provider)).

## Features

- **Context from your code**: LSP definitions, usages, and diagnostics, not just the selected lines
- **Rendered like a notes app**: headings, bullets, checkboxes, shaded code blocks with language labels, and re-aligned tables, built on treesitter with no dependencies (or use render-markdown.nvim / markview.nvim if you have them)
- **Streams the answer** into a float, with a spinner, `y` to yank, and `<C-c>` to stop
- **Shows what was sent**: press `p` to see the exact prompt sent to the model
- **Key handling**: stored in the system keyring or a password manager, never on disk, never in `ps`
- **Live model picker** with prices and context sizes, free models first
- **No dependencies** beyond `curl`, and tested on Neovim 0.10, stable, and nightly

## Requirements

- Neovim 0.10+
- `curl` 7.76+
- An [OpenRouter API key](https://openrouter.ai/keys)
- Optional: an LSP server for the language (better context) and tree-sitter parsers

## Install

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "bob4202/codewhy.nvim",
  opts = {},
}
```

Select some code and press `<leader>ce`. On first use you'll pick a model and,
if no key is configured, paste your API key; it's saved to the system keyring.
`:checkhealth codewhy` checks everything is set up.

## Usage

| Keymap (n / x) | Command | What it does |
|---|---|---|
| `<leader>ce` | `:CodeWhy explain` | Explain the selection (or current line) |
| `<leader>cd` | `:CodeWhy diagnostic` | Explain the error/warning on these lines and how to fix it |
| `<leader>ca` | `:CodeWhy ask [question]` | Ask your own question about the selection |
| | `:CodeWhy model [free]` | Pick a model from OpenRouter's live list |
| | `:CodeWhy key [delete]` | Save the API key to the system keyring (or remove it) |

Commands take a range: `:'<,'>CodeWhy explain`, `:10,40CodeWhy ask why is this slow?`

In the answer window:

| Key | Action |
|---|---|
| `q` / `<Esc>` | Close (and stop) |
| `<C-c>` | Stop streaming, keep the window |
| `y` | Yank the answer |
| `p` | Show exactly what was sent to the model |

The picked model is remembered across sessions (`stdpath("state")/codewhy.json`).
Full docs: `:help codewhy`.

## API key

The key is never written to disk by codewhy, never logged, and is passed to
`curl` through stdin rather than on the command line, so it doesn't show up in
`ps`. Lookup order:

1. `api_key_cmd`, for a password manager. The first line of its stdout is used:
   ```lua
   api_key_cmd = { "pass", "show", "openrouter" }
   api_key_cmd = { "op", "read", "op://Private/OpenRouter/credential" }
   api_key_cmd = "gpg -dq ~/.secrets/openrouter.gpg"   -- strings run via sh -c
   ```
2. `$OPENROUTER_API_KEY`
3. The system keyring (`secret-tool`, service `openrouter`), which `:CodeWhy key` writes to

A plain `api_key = "sk-…"` in your config is deliberately not supported.

## Configuration

<details>
<summary>Defaults</summary>

```lua
require("codewhy").setup({
  provider = "openrouter",
  model = nil,                -- nil: pick on first use; :CodeWhy model overrides
  api_key_cmd = nil,
  api_key_env = "OPENROUTER_API_KEY",
  keymaps = {                 -- set any to false to disable
    explain = "<leader>ce",
    diagnostic = "<leader>cd",
    ask = "<leader>ca",
  },
  context = {
    lsp = true,
    lsp_timeout_ms = 2000,
    max_symbols = 15,         -- identifiers in the selection to look up
    max_snippets = 8,         -- definition snippets sent
    max_snippet_lines = 60,
    max_references = 5,       -- usages sent
    surrounding_lines = 20,
    max_chars = 30000,
    project_only = true,      -- only send code from inside cwd
    exclude = {               -- path substrings that are never sent
      "/node_modules/", "/.venv/", "/venv/", "/site-packages/", "/vendor/", "/.git/",
      "/.env", ".pem", "/id_rsa", "/id_ed25519", "/.ssh/",
    },
  },
  ui = {
    width = 0.6,
    height = 0.6,
    border = "rounded",
    render = "auto",          -- "auto" | "builtin" | false; auto defers to render-markdown.nvim / markview.nvim
  },
  providers = {
    openrouter = {
      base_url = "https://openrouter.ai/api/v1",
      temperature = 0.2,
      max_tokens = nil,
      timeout = 180,
    },
  },
})
```

</details>

## What gets sent

Only: the selected lines, `surrounding_lines` above/below, diagnostics on the
selection, the enclosing definitions (function/class/struct…) of symbols used in
the selection, and a few lines around usages of the main symbol.

With `project_only = true`, nothing outside your working directory is sent.
Symlinks are resolved first, so a link inside the project can't pull in a file
from elsewhere. Press `p` in the answer window to see the exact prompt.

## How it works

```
selection ─► context.lua ──► prompt.lua ──► providers/openrouter.lua ──► ui.lua
             │ tree-sitter      markdown       curl (SSE stream)         float,
             │ identifiers      with line      key on stdin,             spinner,
             │ LSP definition   numbers        body in a 0700            streamed
             │ + references                    temp file                 append
             └ diagnostics
```

| Module | Role |
|---|---|
| `context.lua` | Finds identifiers (tree-sitter, regex fallback), batches LSP `definition`/`references` requests with a timeout, extracts the enclosing definition of each result, applies the project/exclude filter |
| `prompt.lua` | Builds the system + user messages |
| `sse.lua` | Incremental Server-Sent Events parser |
| `render.lua` | Markdown reading view: extmarks over the treesitter parse, colors blended from your colorscheme |
| `providers/` | Pluggable backends behind a small `stream`/`list_models` interface |
| `secrets.lua` | Key lookup (command → env → keyring), cached in memory |
| `ui.lua` | Streaming float window (throttled re-render, spinner, yank, prompt view) |

## Adding a provider

Create `lua/codewhy/providers/<name>.lua` implementing `stream(req, handlers)`
and `list_models(options, cb)`. The interface is documented in
[`lua/codewhy/providers/init.lua`](lua/codewhy/providers/init.lua).

## Development

```sh
make test     # plenary.nvim test suite, headless (clones plenary into .tests/ on first run)
make lint     # stylua --check
make format   # stylua
```

Tests run in isolated XDG directories and never touch your real state or the
network. The provider tests replace `vim.system` with a fake curl, which also
lets them check that the API key only ever goes over stdin.
