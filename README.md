# duckaichatview.nvim

> **v0.1.0** — first public version.

Chat-style view for **Duck.ai** `.txt` exports inside Neovim.

Duck.ai lets you export a conversation as a plain `.txt`. That file is readable
but noisy: boilerplate headers, prompt counters, model lines, separators and raw
reasoning blocks. This plugin keeps the text intact and draws a clean chat view
on top of it with extmarks, so the file stays plain Markdown and still renders
normally everywhere else.

```
 f007 2026-01-01 12:00                1/4
 What is a monad?

 f013 gpt-5-mini
 ──────────────

 A monad is a monoid in the category of endofunctors...
```

Screenshots:

![[/Assets/Screenshot-1.png]]
![[/Assets/Screenshot-2.png]]


## Features

- Auto-detects Duck.ai exports (first line) and applies the view on open.
- Hides boilerplate and structural lines, keeping their surrounding blanks tidy.
- Adds a header, per-turn counters, dates, model badges and separators.
- Shows multi-line prompts as one block with a rail.
- Reasoning blocks (`<!-- ... -->`): `fold`, `hide` or `show`.
- Optional per-turn folding.
- Outline integration through a small in-process LSP server, so `outline.nvim`
  shows the conversation as the root and its `#` headings as children.
- Picker for your exports via Telescope, with a `vim.ui.select` fallback.
- Commands and buffer-local keymaps included.

## Requirements

- Neovim >= 0.11
- A [Nerd Font](https://www.nerdfonts.com/) for the icons
- [markview.nvim](https://github.com/OXY2DEV/markview.nvim) — **required**
  (the view is built to sit on top of markview's Markdown rendering)

Optional:

- [outline.nvim](https://github.com/hedyhli/outline.nvim) for the symbols outline
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) for the picker
  (falls back to `vim.ui.select` without it)

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "FirthR5/duckaichatview.nvim",
  dependencies = {
    "OXY2DEV/markview.nvim",
    -- optional:
    -- "hedyhli/outline.nvim",
    -- "nvim-telescope/telescope.nvim",
  },
  ft = { "markdown", "text" },
  cmd = {
    "DuckOpen",
    "DuckToggleReasoning",
    "DuckToggleMeta",
    "DuckToggleFold",
    "DuckToggleUI",
  },
  opts = {},
}
```

`setup()` is called by `opts = {}`; the plugin is lazy and loads on Markdown or
text files, or when one of its commands is used.

## Configuration

The module is named `duckai`, so the setup call is `require("duckai").setup()`.
With lazy.nvim `opts = {}` does it for you.

```lua
require("duckai").setup({
  reasoning = "hide",
})
```

Defaults:

```lua
{
  header = true,        -- conversation header (provider + turn count)
  counter = true,       -- per-turn "n/total" counter
  spacer = true,        -- blank line between prompt and answer
  rule = true,          -- separator above each turn
  model_badge = true,   -- model name under the prompt
  meta = true,          -- date next to the user icon
  reasoning = "fold",   -- "fold" | "hide" | "show"
  fold_turns = false,   -- start with every turn folded
  filetype = "markdown",-- filetype applied to detected chats
  notes = vim.env.MD_NOTES or "~/Documents/MD_Notes",
  icons = { ... },
}
```

`notes` is the base directory searched by `:DuckOpen`; exports are looked up in
`notes .. "/ChatBot/duck.ai*.txt"`.

## Commands

| Command | Description |
| --- | --- |
| `:DuckOpen [file]` | Open an export, or pick one from the notes directory |
| `:DuckToggleReasoning` | Cycle reasoning: fold -> hide -> show |
| `:DuckToggleMeta` | Show/hide dates and metadata |
| `:DuckToggleFold` | Toggle per-turn folding |
| `:DuckToggleUI` | Show/hide the chat view (`conceallevel`) |

## Keymaps

Buffer-local, under the `Duck` prefix (`<leader>Xmd` by default; read from
`config.keys.Duck` when present):

| Key | Action |
| --- | --- |
| `<prefix>o` | Open chats |
| `<prefix>r` | Cycle reasoning |
| `<prefix>m` | Toggle metadata |
| `<prefix>f` | Toggle per-turn folding |
| `<prefix>u` | Toggle the chat view |

## How it works

The buffer is never modified. Everything is drawn with `nvim_buf_set_extmark`
(`virt_lines`, `virt_text`, conceal and line highlights) and folds are provided
through `foldexpr`. Because the text stays untouched, saving, searching, diffs
and Markdown rendering all keep working.

## Versioning

Current release: **v0.1.0**, the first public version. While the plugin is in
`0.x`, minor releases may still include breaking changes; the API is expected to
stabilize at `v1.0.0`.

With lazy.nvim you can track or pin releases:

```lua
{ "FirthR5/duckaichatview.nvim", version = "*" },      -- latest tag
{ "FirthR5/duckaichatview.nvim", version = "v0.1.0" }, -- exact tag
{ "FirthR5/duckaichatview.nvim", version = "^0.1" },   -- range
```

Without `version`, lazy.nvim follows the default branch HEAD. See
[CHANGELOG.md](CHANGELOG.md) for the history.

## License

[GPL-3.0](LICENSE)

